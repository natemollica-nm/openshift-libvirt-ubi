#!/bin/bash
# OpenShift UPI Node Addition Script
# https://github.com/kxr/ocp4_setup_upi_kvm

# Utility functions
err() { echo -e "\n\e[97m\e[101m[ERROR]\e[0m ${1}\n" >&2; exit 1; }
ok() { echo -e "${1:-ok}"; }
# Function to prompt user before continuing if confirmation is needed
check_if_we_can_continue() {
    if [[ "${YES}" != "yes" ]]; then
        echo
        for msg in "$@"; do
            echo "[NOTE] $msg"
        done
        read -rp "Press [Enter] to continue, [Ctrl]+C to abort: "
    fi
}

# Ensure the script is run as root
[[ "$(whoami)" != "root" ]] && exec sudo "$0" "$@"

set -e

# Help function
show_help() {
    echo
    echo "Usage: ${0} [OPTIONS]"
    echo
    cat << EOF | column -L -t -s '|' -N OPTION,DESCRIPTION -W DESCRIPTION
--name NAME            | Node name without the domain (e.g., "storage-1" results in "storage-1.ocp4.local" if cluster is "ocp4" and base domain is "local"). <REQUIRED>
-h, --help             | Show this help message and exit.
EOF
}

# Load environment
SDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
source "${SDIR}/env" || err "Environment file ${SDIR}/env not found."

# Default values
NODE=""

# Process Arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --name) NODE="$2"; shift 2 ;;
        -h|--help) show_help; exit 0 ;;
        *) err "Unknown argument: $1";;
    esac
done

# Validate required arguments
[[ -z "$NODE" ]] && err "Node name is required. Use --name <node-name>."

# Check if libvirt services are running/enabled
check_libvirt_services() {
    local service
    for service in qemu interface network nodedev nwfilter secret storage; do
        echo -n "====> Checking if virt${service}d is running or enabled: "
        systemctl -q is-active virt${service}d || systemctl -q is-enabled virt${service}d || err "virt${service}d is not running or enabled"
        ok
    done
}

# Function to remove a VM and its DHCP reservation
remove_vm() {
    local vm="$1"
    check_if_we_can_continue "Deleting VM $vm"

    local mac dhcp_lease
    mac=$(virsh domiflist "$vm" | awk '/network/ {print $5}')
    dhcp_lease=$(virsh net-dumpxml "${VIR_NET}" | grep '<host ' | grep "$mac" | sed 's/^[ ]*//')

    echo -n "XXXX> Deleting DHCP reservation for VM $vm: "
    virsh net-update "${VIR_NET}" delete ip-dhcp-host --xml "$dhcp_lease" --live --config >/dev/null 2>&1 || \
        echo -n "Failed to delete DHCP reservation (ignoring) ... "
    ok

    echo -n "XXXX> Deleting VM $vm: "
    virsh destroy "$vm" &>/dev/null || echo -n "Failed to stop VM (ignoring) ... "
    virsh undefine "$vm" --remove-all-storage &>/dev/null || echo -n "Failed to delete VM (ignoring) ... "
    ok
}

# Function to remove the libvirt network
remove_network() {
    local network="$1"
    local uuid
    uuid=$(virsh net-uuid "$network" 2> /dev/null || true)

    if [[ -n "$uuid" ]]; then
        check_if_we_can_continue "Deleting libvirt network $network"

        echo -n "XXXX> Deleting libvirt network $network: "
        virsh net-destroy "$network" >/dev/null 2>&1 || echo -n "Failed to destroy network (ignoring) ... "
        virsh net-undefine "$network" >/dev/null 2>&1 || echo -n "Failed to undefine network (ignoring) ... "
        ok
    fi
}

# Function to comment out cluster-related entries in /etc/hosts
remove_hosts_entries() {
    local entry="$1"
    local hosts_file="/etc/hosts"

    if [[ -z "$entry" ]]; then
        echo "Usage: remove_hosts_entries <entry>"
        return 1
    fi

    if [[ ! -f "$hosts_file" ]]; then
        echo "Error: $hosts_file not found!"
        return 1
    fi

    if grep -q "${entry}" "$hosts_file"; then
        check_if_we_can_continue "Removing entries in $hosts_file for $entry"

        echo -n "====> Removing entries in $hosts_file for $entry: "
        # Use sed to delete lines containing the entry
        sed -i "/${entry}/d" "$hosts_file" || { echo "Failed to remove entries (ignoring) ... "; return 1; }

        echo "Done"
    else
        echo "====> No matching entries found for $entry in $hosts_file."
    fi
}

remove_vm_entry() {
    local vm_name="$1"
    local hosts_file="/etc/hosts.${CLUSTER_NAME}"

    if [[ -z "$vm_name" ]]; then
        echo "Usage: remove_vm_entry <vm_name>"
        return 1
    fi

    if [[ ! -f "$hosts_file" ]]; then
        err "Error: $hosts_file not found!"
    fi

    echo -n "====> Removing entry for VM: ${vm_name} from ${hosts_file}: "
    # Use sed to delete the line containing the VM name
    sudo sed -i.bak "/\b${vm_name}\b/d" "$hosts_file"

    # Check if the operation was successful
    if grep -q "\b${vm_name}\b" "$hosts_file"; then
        err "Failed to remove entry for ${vm_name}"
    else
        ok
    fi
}

# Restart services to apply the changes
restart_services() {
    local service
    echo -n "====> Restarting virtnetworkd daemon: "
    systemctl restart virtnetworkd || err "Failed to restart virt${service}d"; ok
    echo -n "====> Restarting DNS service $DNS_SVC: "
    systemctl "$DNS_CMD" "$DNS_SVC" || err "Failed to reload DNS service $DNS_SVC"; ok
}

# Main execution
check_libvirt_services
remove_vm "${CLUSTER_NAME}-${NODE}"
# Remove the specified libvirt network if set
[[ -n "$VIR_NET_OCT" ]] && remove_network "ocp-${VIR_NET_OCT}"
# Comment out /etc/hosts entries for the cluster
remove_hosts_entries "${NODE}.${CLUSTER_NAME}.${BASE_DOM}$"
remove_vm_entry "${CLUSTER_NAME}.${NODE}.${BASE_DOM}"
restart_services

echo -n "====> Flusing ARP cache for stale VM entries: "
ip neigh flush all >/dev/null 2>&1 || true ; ok

echo "====> ${NODE} successfully deleted from ${CLUSTER_NAME}.${BASE_DOM} cluster!"
