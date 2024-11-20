#!/bin/bash
# OpenShift UPI Node Addition Script
# https://github.com/kxr/ocp4_setup_upi_kvm

# Utility functions
err() { echo -e "\n\e[97m\e[101m[ERROR]\e[0m ${1}\n" >&2; exit 1; }
ok() { echo -e "${1:-ok}"; }

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

# Load environment
SDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
source "${SDIR}/env" || err "Environment file ${SDIR}/env not found."

if [ -z "$RHCOS_LIVE" ]; then
    RHCOS_I_ARG="coreos.live.rootfs_url"
else
    RHCOS_I_ARG="coreos.inst.image_url"
fi

# Default values
CPU=2
MEM=4096
ADD_DISK=""
NODE=""
declare -A ip_addresses

# Process Arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --name) NODE="$2"; shift 2 ;;
        -c|--cpu) [[ "$2" =~ ^[0-9]+$ ]] && CPU="$2" || err "Invalid CPU count: $2"; shift 2 ;;
        -m|--memory) [[ "$2" =~ ^[0-9]+$ ]] && MEM="$2" || err "Invalid memory size: $2"; shift 2 ;;
        -a|--add-disk) [[ "$2" =~ ^[0-9]+$ ]] && ADD_DISK+=" --disk ${VM_DIR}/${CLUSTER_NAME}-${NODE}-${2}GB-$(shuf -zer -n5 {a..z} | tr -d '\0').qcow2,size=${2},serial=${CLUSTER_NAME}-${NODE}-disk-$(printf "%09d" $((RANDOM % 1000000000)))" || err "Invalid disk size: $2"; shift 2 ;;
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
    local service
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
            systemctl restart virtnetworkd || err "Failed to restart libvirtd"
            VIR_NET="ocp-${VIR_NET_OCT}"
        fi
    elif [[ -n "$VIR_NET" ]]; then
        virsh net-uuid "$VIR_NET" &> /dev/null || err "Network $VIR_NET does not exist"
        ok "Using existing network $VIR_NET"
    else
        err "No network specified. Use --libvirt-oct or --libvirt-network"
    fi
}

# Function to create a VM with given parameters
create_vm() {
    local vm_name="$1"
    local memory="$2"
    local vcpus="$3"
    local disk="$4"
    local add_disk="$5"
    local ignition_url="$6"

    # Generate a 9-digit random serial ID
    local serial_id
    serial_id=$(printf "%09d" $((RANDOM % 1000000000)))

    local ignition_args="nomodeset rd.neednet=1 coreos.inst=yes coreos.inst.install_dev=vda ${RHCOS_I_ARG}=http://${LBIP}:${WS_PORT}/${IMAGE} coreos.inst.ignition_url=${ignition_url}"
    # virt-install --os-variant list | grep rhel
    # https://access.redhat.com/articles/6907891
    echo -n "====> Creating ${vm_name} VM: "
    virt-install \
        --name "${vm_name}" \
        --noreboot \
        --cpu host \
        --noautoconsole \
        --ram "${memory}" \
        --vcpus "${vcpus}" \
        --os-variant rhel9.2 \
        --disk "${disk},size=50,serial=${vm_name}-disk-${serial_id}" ${add_disk} \
        --location rhcos-install/ \
        --network network="${VIR_NET}",model=virtio \
        --extra-args "${ignition_args}" \
        >/dev/null || err "Failed to create VM: ${vm_name} | Network: ${VIR_NET} | Kernel Args: ${ignition_args}"
    ok
}

# Function for DHCP reservation and updating /etc/hosts
add_dhcp_and_dns_entry() {
    local vm_name="$1"
    local mac="$2"
    local ip="$3"
    local dns_name="$4"

    echo -n "====> Adding DHCP reservation for ${vm_name}: "
    virsh net-update "${VIR_NET}" add-last ip-dhcp-host --xml "<host mac='$mac' ip='$ip'/>" --live --config > /dev/null || \
        err "Failed to add DHCP reservation for ${vm_name}"
    ok

    echo -n "====> Adding ${vm_name} entry to /etc/hosts.${CLUSTER_NAME}: "
    echo "$ip $dns_name.${CLUSTER_NAME}.${BASE_DOM}" >> "/etc/hosts.${CLUSTER_NAME}" || err "Failed to add hosts entry"
    ok

    echo -n "  ==> Adding /etc/hosts entry: "
    echo "$ip ${NODE}.${CLUSTER_NAME}.${BASE_DOM}" >> /etc/hosts || err "failed"; ok
}

# Function to start VM, get IP, and reserve DHCP
start_vm_with_dhcp() {
    local vm_name="$1"
    local dns_name="$2"

    if virsh domstate "$vm_name" | grep -q "running"; then
        echo "====> Verified ${vm_name} is already running."
    else
        echo -n "====> Starting ${vm_name} VM: "
        virsh start "$vm_name" > /dev/null || err "Failed to start VM: ${vm_name}"
        ok
    fi

    echo -n "====> Waiting for ${vm_name} to obtain IP address: "
    while true; do
        sleep 5
        local ip
        ip=$(virsh domifaddr "${vm_name}" | grep ipv4 | head -n1 | awk '{print $4}' | cut -d'/' -f1 2> /dev/null)
        if [[ -n "$ip" ]]; then
            echo "$ip"
            ip_addresses["$vm_name"]="$ip"
            break
        fi
    done

    local mac
    mac=$(virsh domifaddr "${vm_name}" | grep ipv4 | head -n1 | awk '{print $2}')
    add_dhcp_and_dns_entry "$vm_name" "$mac" "${ip_addresses[$vm_name]}" "$dns_name"
}

# Restart services to apply the changes
restart_services() {
    local service
    echo -n "====> Restarting libvirt modular daemons: "
    for service in qemu interface network nodedev nwfilter secret storage log; do
        systemctl restart "virt${service}d" || err "Failed to restart virt${service}d"
    done; ok
    echo -n "====> Restarting DNS service $DNS_SVC: "
    systemctl "$DNS_CMD" "$DNS_SVC" || err "Failed to reload DNS service $DNS_SVC"; ok
}

# Function to verify DNS resolution for a VM
verify_dns_resolution() {
    local vm_name="$1"
    local expected_ip="$2"
    local fqdn="${vm_name}.${CLUSTER_NAME}.${BASE_DOM}"

    echo -n "====> Verifying DNS resolution for ${fqdn} (ExpectedIP: ${expected_ip}): "
    local resolved_ip
    while true; do
        sleep 5
        resolved_ip=$(nslookup "$fqdn" | grep -A1 "Name:" | grep "Address" | awk '{print $2}' 2> /dev/null)

        if [[ "$resolved_ip" == "$expected_ip" ]]; then
            ok
            break
        elif [[ -n "$resolved_ip" ]] && [[ "$resolved_ip" != "$expected_ip" ]]; then
            err " Invalid address resolution for ${vm_name} *==> $resolved_ip"
            break
        else
            echo -n "."
        fi
    done
}

# Approve CSRs automatically
approve_csrs() {
    echo "====> Approving CSRs (2 CSR per node)..."; echo
    while true; do
        # Get the list of pending CSRs
        local pending_csrs
        pending_csrs=$(oc get csr | grep Pending | awk '{print $1}')

        # If no pending CSRs remain, exit the loop
        if [[ -z "${pending_csrs}" ]]; then
            echo "====> All CSRs have been approved."
            break
        fi

        # Approve each pending CSR
        local csr
        for csr in ${pending_csrs}; do
            echo "Approving CSR: ${csr}"
            oc adm certificate approve "${csr}"
        done

        # Wait a few seconds before checking again
        sleep 5
    done
}


# Main execution
check_libvirt_services
setup_libvirt_network
create_vm \
    "${CLUSTER_NAME}-${NODE}" \
    "${MEM}" \
    "${CPU}" \
    "${VM_DIR}/${CLUSTER_NAME}-${NODE}.qcow2" \
    "${ADD_DISK}" \
    "http://${LBIP}:${WS_PORT}/worker.ign"

echo "====> Waiting for RHCOS Installation to finish: "
while rvms=$(virsh list --name | grep "${CLUSTER_NAME}-${NODE}" 2> /dev/null); do
    sleep 15
    echo "  *==> VMs with pending installation: $(echo "$rvms" | tr '\n' ' ')"
done
start_vm_with_dhcp "${CLUSTER_NAME}-${NODE}" "${NODE}"
restart_services
verify_dns_resolution "${NODE}" "${ip_addresses[${CLUSTER_NAME}-${NODE}]}"
approve_csrs
echo "====> ${NODE} successfully added to ${CLUSTER_NAME} cluster!"
