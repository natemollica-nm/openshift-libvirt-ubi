#!/bin/bash

echo 
echo "############################################"
echo "#### CREATE BOOTSTRAPPING RHCOS/OCP NODES ###"
echo "############################################"
echo 

declare -A ip_addresses

if [ -n "$RHCOS_LIVE" ]; then
    RHCOS_I_ARG="coreos.live.rootfs_url"
else
    RHCOS_I_ARG="coreos.inst.image_url"
fi

# Function to create a VM with given parameters
create_vm() {
    local vm_name="$1"
    local memory="$2"
    local vcpus="$3"
    local disk="$4"
    local ignition_url="$5"

    local ignition_args="nomodeset rd.neednet=1 coreos.inst=yes coreos.inst.install_dev=vda ${RHCOS_I_ARG}=http://${LBIP}:${WS_PORT}/${IMAGE} coreos.inst.ignition_url=${ignition_url}"
    # virt-install --os-variant list | grep rhel
    echo -n "====> Creating ${vm_name} VM: "
    virt-install \
        --name "${vm_name}" \
        --noreboot \
        --cpu host \
        --noautoconsole \
        --ram "${memory}" \
        --vcpus "${vcpus}" \
        --os-variant rhel9.2 \
        --disk "${disk},size=50" \
        --location rhcos-install/ \
        --network network="${VIR_NET}",model=virtio \
        --extra-args "${ignition_args}" \
        >/dev/null || err "Failed to create VM: ${vm_name}"
    ok
    echo "    *==>        VM: ${vm_name}"
    echo "    *==> ExtraArgs: ${ignition_args}"
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


# Create and start Bootstrap VM
create_vm "${CLUSTER_NAME}-bootstrap" "${BTS_MEM}" "${BTS_CPU}" "${VM_DIR}/${CLUSTER_NAME}-bootstrap.qcow2" "http://${LBIP}:${WS_PORT}/bootstrap.ign"
# Create and start Master VMs
for i in $(seq 1 "${N_MAST}"); do
    vm_name="${CLUSTER_NAME}-master-${i}"
    create_vm "$vm_name" "${MAS_MEM}" "${MAS_CPU}" "${VM_DIR}/${vm_name}.qcow2" "http://${LBIP}:${WS_PORT}/master.ign"
done
# Create and start Worker VMs
for i in $(seq 1 "${N_WORK}"); do
    vm_name="${CLUSTER_NAME}-worker-${i}"
    create_vm "$vm_name" "${WOR_MEM}" "${WOR_CPU}" "${VM_DIR}/${vm_name}.qcow2" "http://${LBIP}:${WS_PORT}/worker.ign"
done

# Wait for RHCOS Installation to complete
echo "====> Waiting for RHCOS Installation to finish: "
while rvms=$(virsh list --name | grep "${CLUSTER_NAME}-master-\|${CLUSTER_NAME}-worker-\|${CLUSTER_NAME}-bootstrap" 2>/dev/null); do
    sleep 15
    echo "  *==> VMs with pending installation: $(echo "$rvms" | tr '\n' ' ')"
done

# Create and start Bootstrap VM
start_vm_with_dhcp "${CLUSTER_NAME}-bootstrap" "bootstrap"

# Create and start Master VMs
for i in $(seq 1 "${N_MAST}"); do
    vm_name="${CLUSTER_NAME}-master-${i}"
    start_vm_with_dhcp "$vm_name" "master-${i}"

    # Adding SRV record in dnsmasq for etcd if it's a master node
    echo -n "  ==> Adding SRV record in dnsmasq for Master-${i}: "
    echo "srv-host=_etcd-server-ssl._tcp.${CLUSTER_NAME}.${BASE_DOM},etcd-$((i-1)).${CLUSTER_NAME}.${BASE_DOM},2380,0,10" >> "${DNS_DIR}/${CLUSTER_NAME}.conf" || err "Failed to add SRV record for Master-${i}"
    ok
done

# Create and start Worker VMs
for i in $(seq 1 "${N_WORK}"); do
    vm_name="${CLUSTER_NAME}-worker-${i}"
    start_vm_with_dhcp "$vm_name" "worker-${i}"
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
    for service in qemu interface network nodedev nwfilter secret storage log; do
        echo -n "====> Restarting virt${service}d daemon: "
        systemctl restart "virt${service}d" || err "Failed to restart virt${service}d"
        ok
    done
    echo -n "====> Restarting DNS service $DNS_SVC: "
    systemctl "$DNS_CMD" "$DNS_SVC" || err "Failed to reload DNS service $DNS_SVC"
    ok
}

restart_services

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
            echo " *==> $resolved_ip"
            break
        elif [[ -n "$resolved_ip" ]] && [[ "$resolved_ip" != "$expected_ip" ]]; then
            echo " *==> $resolved_ip (INVALID!)"
            break
        else
            echo -n "."
        fi
    done
}

# Verify DNS resolution for each VM
verify_dns_resolution "bootstrap" "${ip_addresses[${CLUSTER_NAME}-bootstrap]}"
for i in $(seq 1 "${N_MAST}"); do
    verify_dns_resolution "master-${i}" "${ip_addresses[${CLUSTER_NAME}-master-${i}]}"
done
for i in $(seq 1 "${N_WORK}"); do
    verify_dns_resolution "worker-${i}" "${ip_addresses[${CLUSTER_NAME}-worker-${i}]}"
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
