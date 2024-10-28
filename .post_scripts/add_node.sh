#!/bin/bash
# OpenShift UPI Node Addition Script
# https://github.com/kxr/ocp4_setup_upi_kvm

# Force the script to run as root
if [[ "$EUID" -ne 0 ]]; then
  echo "This script must be run as root. Restarting with sudo..."
  exec sudo "$0" "$@"
fi

set -e

# Help function
show_help() {
    echo
    echo "Usage: ${0} [OPTIONS]"
    echo
    cat << EOF | column -L -t -s '|' -N OPTION,DESCRIPTION -W DESCRIPTION
--name NAME            | Node name without the domain (e.g., "storage-1" results in "storage-1.ocp4.local" if cluster is "ocp4" and base domain is "local"). <REQUIRED>
-c, --cpu N            | Number of CPUs for the VM. Default: 2
-m, --memory SIZE      | Memory for the VM in MB. Default: 4096
-a, --add-disk SIZE    | Add additional disk(s) in GB (e.g., "--add-disk 10 --add-disk 100"). Multiple allowed.
-v, --vm-dir           | VM disk storage location. Default: Cluster VM disk location.
-N, --libvirt-oct OCTET| Subnet octet for new libvirt network (192.168.{OCTET}.0). Default: <not set>
-n, --libvirt-network  | Existing libvirt network to use. Default: Cluster libvirt network.
-h, --help             | Show this help message and exit.
EOF
}

# Utility functions
err() { echo -e "\n\e[97m\e[101m[ERROR]\e[0m ${1}\n" >&2; exit 1; }
ok() { echo -e "${1:-ok}"; }

# Load environment
SDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
source "${SDIR}/env" || err "Environment file ${SDIR}/env not found."

# Default values
CPU=2
MEM=4096
ADD_DISK=""
VIR_NET=""
NODE=""

# Process Arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --name) NODE="$2"; shift 2 ;;
        -c|--cpu) [[ "$2" =~ ^[0-9]+$ ]] && CPU="$2" || err "Invalid CPU count: $2"; shift 2 ;;
        -m|--memory) [[ "$2" =~ ^[0-9]+$ ]] && MEM="$2" || err "Invalid memory size: $2"; shift 2 ;;
        -a|--add-disk) [[ "$2" =~ ^[0-9]+$ ]] && ADD_DISK+=" --disk ${VM_DIR}/${CLUSTER_NAME}-${NODE}-${2}GB-$(shuf -zer -n5 {a..z} | tr -d '\0').qcow2,size=${2}" || err "Invalid disk size: $2"; shift 2 ;;
        -N|--libvirt-oct) [[ "$2" -gt 0 && "$2" -lt 255 ]] && VIR_NET_OCT="$2" || err "Invalid subnet octet: $2"; shift 2 ;;
        -n|--libvirt-network) VIR_NET="$2"; shift 2 ;;
        -v|--vm-dir) VM_DIR="$2"; shift 2 ;;
        -h|--help) show_help; exit 0 ;;
        *) err "Unknown argument: $1";;
    esac
done

# Validate required arguments
[[ -z "$NODE" ]] && err "Node name is required. Use --name <node-name>."

# Ensure the script is run as root
[[ "$(whoami)" != "root" ]] && exec sudo "$0" "$@"

# Check if libvirt services are running/enabled
check_libvirt_services() {
    for service in qemu interface network nodedev nwfilter secret storage; do
        echo -n "====> Checking if virt${service}d is running or enabled: "
        systemctl -q is-active virt${service}d || systemctl -q is-enabled virt${service}d || err "virt${service}d is not running or enabled"
        ok
    done
}

# Create or verify libvirt network
setup_libvirt_network() {
    if [[ -n "$VIR_NET_OCT" ]]; then
        if virsh net-uuid "ocp-${VIR_NET_OCT}" &> /dev/null; then
            VIR_NET="ocp-${VIR_NET_OCT}"
            ok "Reusing ocp-${VIR_NET_OCT}"
        else
            echo "Creating new network ocp-${VIR_NET_OCT} (192.168.${VIR_NET_OCT}.0/24)"
            cp /usr/share/libvirt/networks/default.xml /tmp/new-net.xml || err "Failed to copy network template"
            sed -i "s/default/ocp-${VIR_NET_OCT}/; s/virbr0/ocp-${VIR_NET_OCT}/; s/122/${VIR_NET_OCT}/g" /tmp/new-net.xml
            virsh net-define /tmp/new-net.xml || err "Failed to define network"
            virsh net-autostart "ocp-${VIR_NET_OCT}" || err "Failed to set autostart on network"
            virsh net-start "ocp-${VIR_NET_OCT}" || err "Failed to start network"
            systemctl restart libvirtd || err "Failed to restart libvirtd"
            VIR_NET="ocp-${VIR_NET_OCT}"
        fi
    elif [[ -n "$VIR_NET" ]]; then
        virsh net-uuid "$VIR_NET" &> /dev/null || err "Network $VIR_NET does not exist"
        ok "Using existing network $VIR_NET"
    else
        err "No network specified. Use --libvirt-oct or --libvirt-network"
    fi
}

# Install the VM
create_vm() {
    echo -n "====> Creating ${NODE} VM: "
    virt-install \
        --name "${CLUSTER_NAME}-${NODE}" \
        --disk "${VM_DIR}/${CLUSTER_NAME}-${NODE}.qcow2,size=50" ${ADD_DISK} \
        --ram "${MEM}" \
        --cpu host \
        --vcpus "${CPU}" \
        --os-variant rhel9.0 \
        --network network="${VIR_NET}",model=virtio \
        --noreboot \
        --noautoconsole \
        --location rhcos-install/ \
        --extra-args "nomodeset rd.neednet=1 coreos.inst=yes coreos.inst.install_dev=vda ${RHCOS_I_ARG}=http://${LBIP}:${WS_PORT}/${IMAGE} coreos.inst.ignition_url=http://${LBIP}:${WS_PORT}/worker.ign" > /dev/null || err "VM creation failed"
    ok
}

# Approve CSRs automatically
approve_csrs() {
    echo -n "====> Approving ${NODE} CSRs (2 CSR per node, press ctrl+c once approved)..."; echo
    while true; do
        for csr in $(oc get csr | grep Pending | awk '{print $1}'); do
            oc adm certificate approve "${csr}"
        done
        sleep 5
    done
}

# Main execution
check_libvirt_services
setup_libvirt_network
create_vm

echo -n "====> Waiting for ${NODE} VM to obtain IP address: "
while true; do
    sleep 5
    IP=$(virsh domifaddr "${CLUSTER_NAME}-${NODE}" | grep ipv4 | head -n1 | awk '{print $4}' | cut -d'/' -f1 2>/dev/null)
    [[ -n "$IP" ]] && { echo "$IP"; break; }
done

MAC=$(virsh domifaddr "${CLUSTER_NAME}-${NODE}" | grep ipv4 | head -n1 | awk '{print $2}')
echo -n "  ==> Adding DHCP reservation: "
virsh net-update "$VIR_NET" add-last ip-dhcp-host --xml "<host mac='$MAC' ip='$IP'/>" --live --config > /dev/null || err "Failed to add DHCP reservation"
ok

echo -n "  ==> Adding /etc/hosts entry: "
echo "$IP ${NODE}.${CLUSTER_NAME}.${BASE_DOM}" >> /etc/hosts || err "Failed to add /etc/hosts entry"
ok

echo -n "====> Restarting necessary services: "
for service in qemu interface network nodedev nwfilter secret storage; do
    systemctl restart virt${service}d || err "Failed to restart virt${service}d"
done
systemctl "${DNS_CMD}" "${DNS_SVC}" || err "Failed to restart ${DNS_SVC}"
ok

approve_csrs
echo "====> ${NODE} successfully added to ${CLUSTER_NAME} cluster!"
