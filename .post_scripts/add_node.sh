#!/bin/bash
# https://github.com/kxr/ocp4_setup_upi_kvm
set -e

# Help function
show_help() {
    echo
    echo "Usage: ${0} [OPTIONS]"
    echo
    cat << EOF | column -L -t -s '|' -N OPTION,DESCRIPTION -W DESCRIPTION
--name NAME            | The node name without the domain.
                       | For example: If you specify storage-1, and your cluster name is "ocp4" and base domain is "local", the new node would be "storage-1.ocp4.local"
                       | <REQUIRED>

-c, --cpu N            | Number of CPUs to be attached to this node's VM.
                       | Default: 2

-m, --memory SIZE      | Amount of Memory to be attached to this node's VM. Size in MB.
                       | Default: 4096

-a, --add-disk SIZE    | Add additional disks to this node. Size in GB.
                       | This option can be specified multiple times. Disks are added in order, e.g. "--add-disk 10 --add-disk 100"
                       | Default: <not set>

-v, --vm-dir           | Location to store the VM Disks.
                       | Default: Cluster VM disk location.

-N, --libvirt-oct OCTET| Specify a subnet octet to create a new libvirt network (192.168.{OCTET}.0).
                       | Default: <not set>

-n, --libvirt-network  | Use an existing libvirt network.
                       | Default: Cluster libvirt network.
EOF
}

# Error handler
err() {
    echo; echo -e "\e[97m\e[101m[ERROR]\e[0m ${1}"; shift; echo
    while [[ $# -gt 0 ]]; do echo "    $1"; shift; done
    echo; exit 1
}

# Success message handler
ok() {
    test -z "$1" && echo "ok" || echo "$1"
}

# Load environment
SDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
source "${SDIR}/env" || err "${SDIR}/env not found."

# Process Arguments
CPU=2  # Default CPU
MEM=4096  # Default Memory
ADD_DISK=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --name)
            NODE="$2"
            shift 2
            ;;
        -c|--cpu)
            [[ "$2" =~ ^[0-9]+$ && "$2" -gt 0 ]] || err "Invalid value $2 for --cpu"
            CPU="$2"
            shift 2
            ;;
        -m|--memory)
            [[ "$2" =~ ^[0-9]+$ && "$2" -gt 0 ]] || err "Invalid value $2 for --memory"
            MEM="$2"
            shift 2
            ;;
        -a|--add-disk)
            [[ "$2" =~ ^[0-9]+$ && "$2" -gt 0 ]] || err "Invalid disk size. Enter size in GB"
            ADD_DISK="${ADD_DISK} --disk ${VM_DIR}/${CLUSTER_NAME}-${NODE}-${2}GB-$(shuf -zer -n 5 {a..z} | tr -d '\0').qcow2,size=${2}"
            shift 2
            ;;
        -N|--libvirt-oct)
            VIR_NET_OCT="$2"
            [[ "$VIR_NET_OCT" -gt 0 && "$VIR_NET_OCT" -lt 255 ]] || err "Invalid subnet octet $VIR_NET_OCT"
            shift 2
            ;;
        -n|--libvirt-network)
            VIR_NET="$2"
            shift 2
            ;;
        -v|--vm-dir)
            VM_DIR="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            err "Invalid argument $1"
    esac
done

test -z "$NODE" && err "Please specify the node name using --name <node-name>" \
                       "see --help for more details"
test -z "$CPU" && CPU="2"
test -z "$MEM" && MEM="4096"

# Checking if we are root
test "$(whoami)" = "root" || err "Not running as root"

for drv in qemu interface network nodedev nwfilter secret storage; do
    echo -n "====> Checking if virt${drv}d is running or enabled: "
        systemctl -q is-active virt${drv}d || systemctl -q is-enabled virt${drv}d || err "virt${drv}d is not running nor enabled"
    ok
done

echo -n "====> Checking libvirt network: "
if [ -n "$VIR_NET_OCT" ]; then
    virsh net-uuid "ocp-${VIR_NET_OCT}" &> /dev/null
    if [ $? -eq 0 ]; then
        VIR_NET="ocp-${VIR_NET_OCT}"
        ok "Reusing ocp-${VIR_NET_OCT}"
    else
        ok "Creating new network ocp-${VIR_NET_OCT} (192.168.${VIR_NET_OCT}.0/24)"
    fi
elif [ -n "$VIR_NET" ]; then
    virsh net-uuid "${VIR_NET}" &> /dev/null || err "${VIR_NET} doesn't exist"
    ok "Using existing network $VIR_NET"
else
    err "Unhandled situation. Exiting."
fi

# Create libvirt network if necessary
if [ -n "$VIR_NET_OCT" ]; then
    echo -n "====> Creating libvirt network ocp-${VIR_NET_OCT}: "
    cp /usr/share/libvirt/networks/default.xml /tmp/new-net.xml || err "Network creation failed"
    sed -i "s/default/ocp-${VIR_NET_OCT}/; s/virbr0/ocp-${VIR_NET_OCT}/; s/122/${VIR_NET_OCT}/g" /tmp/new-net.xml
    virsh net-define /tmp/new-net.xml >/dev/null 2>&1 || err "virsh net-define failed"
    virsh net-autostart ocp-${VIR_NET_OCT} >/dev/null 2>&1 || err "virsh net-autostart failed"
    virsh net-start ocp-${VIR_NET_OCT} >/dev/null 2>&1 || err "virsh net-start failed"
    systemctl restart libvirtd >/dev/null 2>&1 || err "systemctl restart libvirtd failed"
    echo "ocp-${VIR_NET_OCT} created"
    VIR_NET="ocp-${VIR_NET_OCT}"
fi


cd ${SETUP_DIR}

if [ -n "$RHCOS_LIVE" ]; then
    RHCOS_I_ARG="coreos.live.rootfs_url"
else
    RHCOS_I_ARG="coreos.inst.image_url"
fi

echo -n "====> Creating ${NODE} VM: "
virt-install \
    --name ${CLUSTER_NAME}-${NODE} \
    --disk "${VM_DIR}/${CLUSTER_NAME}-${NODE}.qcow2,size=50" ${ADD_DISK} \
    --ram ${MEM} \
    --cpu host \
    --vcpus ${CPU} \
    --os-variant rhel9.0 \
    --network network=${VIR_NET},model=virtio \
    --noreboot \
    --noautoconsole \
    --location rhcos-install/ \
    --extra-args "nomodeset rd.neednet=1 coreos.inst=yes coreos.inst.install_dev=vda ${RHCOS_I_ARG}=http://${LBIP}:${WS_PORT}/${IMAGE} coreos.inst.ignition_url=http://${LBIP}:${WS_PORT}/worker.ign" > /dev/null || err "Creating ${NODE} VM failed"
ok

# Wait for installation completion
echo "====> Waiting for RHCOS installation to finish: "
while virsh list --name | grep -q "${CLUSTER_NAME}-${NODE}"; do
    sleep 15
    echo "  --> VMs with pending installation: ${CLUSTER_NAME}-${NODE}"
done

echo -n "====> Starting ${NODE} VM: "
virsh start ${CLUSTER_NAME}-${NODE} > /dev/null || err "virsh start ${CLUSTER_NAME}-worker-${i} failed"
ok


echo -n "====> Waiting for ${NODE} to obtain IP address: "
while true; do
    sleep 5
    IP=$(virsh domifaddr "${CLUSTER_NAME}-${NODE}" | grep ipv4 | head -n1 | awk '{print $4}' | cut -d'/' -f1 2>/dev/null)
    test "$?" -eq "0" -a -n "$IP"  && { echo "$IP"; break; }
done



MAC=$(virsh domifaddr "${CLUSTER_NAME}-${NODE}" | grep ipv4 | head -n1 | awk '{print $2}')
echo -n "  ==> Adding DHCP reservation: "
virsh net-update ${VIR_NET} add-last ip-dhcp-host --xml "<host mac='$MAC' ip='$IP'/>" --live --config > /dev/null || \
err "Adding DHCP reservation failed"; ok

echo -n "  ==> Adding /etc/hosts entry: "
echo "$IP ${NODE}.${CLUSTER_NAME}.${BASE_DOM}" >> /etc/hosts || err "failed"; ok

for drv in qemu interface network nodedev nwfilter secret storage; do
    echo -n "====> Restarting virt${drv}d: "
    systemctl restart virt${drv}d || err "systemctl restart virt${drv}d failed"
    ok
done
echo -n "====> Restarting dnsmasq: "
systemctl $DNS_CMD $DNS_SVC || err "systemctl $DNS_CMD $DNS_SVC failed"
ok

echo -n "====> Approving ${NODE} CSRs (2 CSR per node, press ctrl+c once approved)..."; echo
while true; do
  for x in $(oc get csr | grep Pending | awk '{print $1}'); do
      oc adm certificate approve "${x}";
  done;
  sleep 5;
done
echo "====> ${NODE} added to ${CLUSTER} cluster successfully!"
