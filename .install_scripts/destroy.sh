#!/bin/bash

echo
echo "##################"
echo "####  DESTROY  ###"
echo "##################"
echo

# Set the virtual network if VIR_NET_OCT is defined
[[ -n "$VIR_NET_OCT" && -z "$VIR_NET" ]] && VIR_NET="ocp-${VIR_NET_OCT}"

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
    virsh destroy "$vm" >/dev/null 2>&1 || echo -n "Failed to stop VM (ignoring) ... "
    virsh undefine "$vm" --remove-all-storage >/dev/null 2>&1 || echo -n "Failed to delete VM (ignoring) ... "
    ok
}

# Remove all relevant VMs
for vm in $(virsh list --all --name | grep "${CLUSTER_NAME}"); do
    remove_vm "$vm"
done

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

# Remove the specified libvirt network if set
[[ -n "$VIR_NET_OCT" ]] && remove_network "ocp-${VIR_NET_OCT}"

# Function to remove a directory if it exists
remove_directory() {
    local dir="$1"
    if [[ -d "$dir" ]]; then
        check_if_we_can_continue "Removing directory $dir"

        echo -n "XXXX> Deleting directory $dir: "
        rm -rf "$dir" || echo -n "Failed to delete directory (ignoring) ... "
        ok
    fi
}

# Remove setup directory if it exists
remove_directory "$SETUP_DIR"

# Function to comment out cluster-related entries in /etc/hosts
comment_hosts_entries() {
    local entry="$1"
    local hosts_file="/etc/hosts"

    if grep -q "${entry}" "$hosts_file"; then
        check_if_we_can_continue "Commenting entries in $hosts_file for $entry"

        echo -n "XXXX> Commenting entries in $hosts_file for $entry: "
        sed -i "s/\(.*${entry}\)/#\1/" "$hosts_file" || echo -n "Failed to comment entries (ignoring) ... "
        ok
    fi
}

# Comment out /etc/hosts entries for the cluster
comment_hosts_entries "${CLUSTER_NAME}.${BASE_DOM}$"

# Function to remove a file if it exists
remove_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        check_if_we_can_continue "Removing file $file"

        echo -n "XXXX> Removing file $file: "
        rm -f "$file" >/dev/null 2>&1 || echo -n "Failed to remove file (ignoring) ... "
        ok
    fi
}

# Remove cluster-specific DNS and hosts configuration files if they exist
remove_file "${DNS_DIR}/${CLUSTER_NAME}.conf"
remove_file "/etc/hosts.${CLUSTER_NAME}"
