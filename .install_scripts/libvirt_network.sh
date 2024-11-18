#!/bin/bash

echo
echo "#######################"
echo "### LIBVIRT NETWORK ###"
echo "#######################"
echo

# Function to check if a network exists
check_network_existence() {
    local network="$1"
    virsh net-uuid "$network" >/dev/null 2>&1
}

# Function to create a new libvirt network configuration file
create_network_config() {
    local network_octet="$1"
    local config_file="/tmp/new-net.xml"

    cat <<EOF > "$config_file"
<network>
  <name>ocp-${network_octet}</name>
  <bridge name="ocp-${network_octet}"/>
  <forward/>
  <ip address="192.168.${network_octet}.1" netmask="255.255.255.0">
    <dhcp>
      <range start="192.168.${network_octet}.2" end="192.168.${network_octet}.254"/>
    </dhcp>
  </ip>
</network>
EOF
}

# Function to create and start a new libvirt network
create_network() {
    local network_octet="$1"

    echo -n "====> Creating new libvirt network ocp-${network_octet}: "
    create_network_config "$network_octet"

    virsh net-define /tmp/new-net.xml >/dev/null 2>&1 || err "Failed to define network ocp-${network_octet}"
    virsh net-autostart "ocp-${network_octet}" >/dev/null 2>&1 || err "Failed to set autostart for ocp-${network_octet}"
    virsh net-start "ocp-${network_octet}" >/dev/null 2>&1 || err "Failed to start network ocp-${network_octet}"
    systemctl restart virtnetworkd >/dev/null 2>&1 || err "Failed to restart virtnetworkd"
    ok "ocp-${network_octet} created"
}

# Check if VIR_NET or VIR_NET_OCT is set and handle accordingly
echo -n "====> Checking libvirt network: "
if [[ -n "$VIR_NET_OCT" ]]; then
    if check_network_existence "ocp-${VIR_NET_OCT}"; then
        export VIR_NET="ocp-${VIR_NET_OCT}"
        ok "Re-using existing network ocp-${VIR_NET_OCT}"
        unset VIR_NET_OCT
    else
        ok "Will create network ocp-${VIR_NET_OCT} (192.168.${VIR_NET_OCT}.0/24)"
    fi
elif [[ -n "$VIR_NET" ]]; then
    check_network_existence "$VIR_NET" || err "Network ${VIR_NET} does not exist"
    ok "Using existing network $VIR_NET"
else
    err "Neither VIR_NET nor VIR_NET_OCT is set. Exiting."
fi

# Create the network if VIR_NET_OCT is set (network does not already exist)
if [[ -n "$VIR_NET_OCT" ]]; then
    create_network "$VIR_NET_OCT"
    export VIR_NET="ocp-${VIR_NET_OCT}"
fi

echo -n "====> Starting/Enabling libvirt network $VIR_NET for autostart: "
virsh net-start "${VIR_NET}" >/dev/null 2>&1 || true
virsh net-autostart "${VIR_NET}" >/dev/null 2>&1 || true
ok

# Retrieve the bridge name and gateway IP for the network
echo -n "====> Retrieving network bridge and gateway IP -- "
LIBVIRT_BRIDGE=$(virsh net-info "${VIR_NET}" | awk '/^Bridge:/ {print $2}')
LIBVIRT_GWIP=$(ip -f inet addr show "${LIBVIRT_BRIDGE}" | awk '/inet / {print $2}' | cut -d '/' -f1)
[ -n "${LIBVIRT_GWIP}" ] || err "Network - Unable to retrieve $VIR_NET GatewayIP! Ensure network is started and reachable..."
ok "Bridge: ${LIBVIRT_BRIDGE}, Gateway IP: ${LIBVIRT_GWIP}"
