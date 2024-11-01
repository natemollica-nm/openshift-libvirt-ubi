#!/bin/bash

echo 
echo "############################################"
echo "#### CREATE BOOTSTRAPING RHCOS/OCP NODES ###"
echo "############################################"
echo 

# Declare an associative array for storing IP addresses
declare -A ip_addresses

# Set the correct rootfs or image URL argument
RHCOS_I_ARG="coreos.${RHCOS_LIVE:+live.}rootfs_url"
[[ -z "$RHCOS_LIVE" ]] && RHCOS_I_ARG="coreos.inst.image_url"

# Function to create a VM with given parameters
create_vm() {
    local vm_name="$1"
    local memory="$2"
    local vcpus="$3"
    local disk="$4"
    local ignition_url="$5"

    echo -n "====> Creating ${vm_name} VM: "
    virt-install --name "${vm_name}" \
        --disk "${disk},size=50" \
        --ram "${memory}" \
        --cpu host \
        --vcpus "${vcpus}" \
        --os-variant rhel9.0 \
        --network network="${VIR_NET}",model=virtio \
        --noreboot \
        --noautoconsole \
        --location rhcos-install/ \
        --extra-args "nomodeset rd.neednet=1 coreos.inst=yes coreos.inst.install_dev=vda ${RHCOS_I_ARG}=http://${LBIP}:${WS_PORT}/${IMAGE} coreos.inst.ignition_url=${ignition_url}" > /dev/null || err "Failed to create VM: ${vm_name}"
    ok
}

# Function to start VM and obtain IP address, storing it in the associative array
start_vm_with_dhcp() {
    local vm_name="$1"

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
        local IP
        IP=$(virsh domifaddr "${vm_name}" | grep ipv4 | head -n1 | awk '{print $4}' | cut -d'/' -f1 2> /dev/null)
        if [[ -n "$IP" ]]; then
            echo "$IP"
            ip_addresses["$vm_name"]="${IP}"  # Store IP in associative array
            break
        fi
    done
    local MAC
    MAC=$(virsh domifaddr "${vm_name}" | grep ipv4 | head -n1 | awk '{print $2}')

    echo -n "  ==> Adding DHCP reservation for ${vm_name}: "
    virsh net-update "${VIR_NET}" add-last ip-dhcp-host --xml "<host mac='${MAC}' ip='${ip_addresses[$vm_name]}'/>" --live --config > /dev/null || \
        err "Failed to add DHCP reservation for ${vm_name}"
    ok
}

# Create and configure Bootstrap VM
create_vm "${CLUSTER_NAME}-bootstrap" "${BTS_MEM}" "${BTS_CPU}" "${VM_DIR}/${CLUSTER_NAME}-bootstrap.qcow2" "http://${LBIP}:${WS_PORT}/bootstrap.ign"
start_vm_with_dhcp "${CLUSTER_NAME}-bootstrap"

# Create and configure Master VMs
for i in $(seq 1 "${N_MAST}"); do
    create_vm "${CLUSTER_NAME}-master-${i}" "${MAS_MEM}" "${MAS_CPU}" "${VM_DIR}/${CLUSTER_NAME}-master-${i}.qcow2" "http://${LBIP}:${WS_PORT}/master.ign"
    start_vm_with_dhcp "${CLUSTER_NAME}-master-${i}"

    echo -n "  ==> Adding SRV record in dnsmasq for Master-${i}: "
    echo "srv-host=_etcd-server-ssl._tcp.${CLUSTER_NAME}.${BASE_DOM},etcd-$((i-1)).${CLUSTER_NAME}.${BASE_DOM},2380,0,10" >> "${DNS_DIR}/${CLUSTER_NAME}.conf" || \
        err "Failed to add SRV record for Master-${i}"
    ok
done

# Create and configure Worker VMs
for i in $(seq 1 "${N_WORK}"); do
    create_vm "${CLUSTER_NAME}-worker-${i}" "${WOR_MEM}" "${WOR_CPU}" "${VM_DIR}/${CLUSTER_NAME}-worker-${i}.qcow2" "http://${LBIP}:${WS_PORT}/worker.ign"
    start_vm_with_dhcp "${CLUSTER_NAME}-worker-${i}"
done

# Add DNS and hosts entries
update_dns_hosts() {
    echo -n "====> Marking ${CLUSTER_NAME}.${BASE_DOM} as local in dnsmasq: "
    echo "local=/${CLUSTER_NAME}.${BASE_DOM}/" >> "${DNS_DIR}/${CLUSTER_NAME}.conf" || err "Updating dnsmasq configuration failed"
    ok

    echo -n '====> Adding wildcard (*.apps) DNS record in dnsmasq: '
    echo "address=/apps.${CLUSTER_NAME}.${BASE_DOM}/${LBIP}" >> "${DNS_DIR}/${CLUSTER_NAME}.conf" || err "Failed to add wildcard DNS record"
    ok
}

update_dns_hosts

# Restart services to apply the changes
restart_services() {
    local service
    echo -n "====> Restarting libvirt modular daemons and DNS services: "
    for service in qemu interface network nodedev nwfilter secret storage log; do
        systemctl restart "virt${service}d" || err "Failed to restart virt${service}d"
        ok
    done
}

restart_services

# Function to verify DNS resolution for a VM
verify_dns_resolution() {
    local vm_name="$1"
    local expected_ip="$2"
    local fqdn="${vm_name}.${CLUSTER_NAME}.${BASE_DOM}"

    echo -n "====> Verifying DNS resolution for ${fqdn}: "
    while true; do
        sleep 5
        resolved_ip=$(nslookup "$fqdn" | grep -A1 "Name:" | grep "Address" | awk '{print $2}' 2> /dev/null)

        if [[ "$resolved_ip" == "$expected_ip" ]]; then
            echo "Resolved successfully to $resolved_ip"
            break
        else
            echo -n "."
        fi
    done
}

# Verify DNS resolution for each VM
verify_dns_resolution "${CLUSTER_NAME}-bootstrap" "${ip_addresses[${CLUSTER_NAME}-bootstrap]}"
for i in $(seq 1 "${N_MAST}"); do
    verify_dns_resolution "${CLUSTER_NAME}-master-${i}" "${ip_addresses[${CLUSTER_NAME}-master-${i}]}"
done
for i in $(seq 1 "${N_WORK}"); do
    verify_dns_resolution "${CLUSTER_NAME}-worker-${i}" "${ip_addresses[${CLUSTER_NAME}-worker-${i}]}"
done

# Configure HAProxy on Load Balancer
configure_haproxy() {
    echo -n "====> Configuring HAProxy on Load Balancer VM: "
    ssh -t -i sshkey "lb.${CLUSTER_NAME}.${BASE_DOM}" <<'EOF'
        # Add necessary ports to SELinux configuration for HAProxy
        semanage port -a -t http_port_t -p tcp 6443 || true
        semanage port -a -t http_port_t -p tcp 22623 || true

        # Try to start and enable HAProxy, with error handling for any failure
        if ! systemctl start haproxy; then
            echo "Failed to start haproxy" >&2
            exit 1
        fi
        systemctl -q enable haproxy

        # Confirm HAProxy is active, otherwise, print an error
        if ! systemctl -q is-active haproxy; then
            echo "HAProxy is not active" >&2
            exit 1
        fi
EOF
    ok
}

configure_haproxy

# Function to set autostart for VMs
set_vm_autostart() {
    if [[ "$AUTOSTART_VMS" == "yes" ]]; then
        echo -n "====> Setting VMs to autostart: "
        local vm
        for vm in $(virsh list --all --name --no-autostart | grep "^${CLUSTER_NAME}-"); do
            virsh autostart "$vm" &> /dev/null
            echo -n "."
        done
        ok
    fi
}

set_vm_autostart

# Function to wait for SSH access to Bootstrap VM
wait_for_ssh_bootstrap() {
    echo -n "====> Waiting for SSH access on Bootstrap VM: "
    ssh-keygen -R "bootstrap.${CLUSTER_NAME}.${BASE_DOM}" &> /dev/null || true
    ssh-keygen -R "${BSIP}" &> /dev/null || true
    while true; do
        sleep 1
        ssh -i sshkey -o StrictHostKeyChecking=no "core@bootstrap.${CLUSTER_NAME}.${BASE_DOM}" true &> /dev/null && break
    done
    ok
}

wait_for_ssh_bootstrap
