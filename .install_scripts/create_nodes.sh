#!/bin/bash

echo 
echo "############################################"
echo "#### CREATE BOOTSTRAPING RHCOS/OCP NODES ###"
echo "############################################"
echo 

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
    virt-install --name "$vm_name" \
        --disk "$disk,size=50" \
        --ram "$memory" \
        --cpu host \
        --vcpus "$vcpus" \
        --os-variant rhel9.0 \
        --network network="${VIR_NET}",model=virtio \
        --noreboot \
        --noautoconsole \
        --location rhcos-install/ \
        --extra-args "nomodeset rd.neednet=1 coreos.inst=yes coreos.inst.install_dev=vda ${RHCOS_I_ARG}=http://${LBIP}:${WS_PORT}/${IMAGE} coreos.inst.ignition_url=${ignition_url}" > /dev/null || err "Failed to create VM: ${vm_name}"
    ok
}

# Create Bootstrap VM
create_vm "${CLUSTER_NAME}-bootstrap" "$BTS_MEM" "$BTS_CPU" "${VM_DIR}/${CLUSTER_NAME}-bootstrap.qcow2" "http://${LBIP}:${WS_PORT}/bootstrap.ign"

# Create Master VMs
for i in $(seq 1 "${N_MAST}"); do
    create_vm "${CLUSTER_NAME}-master-${i}" "$MAS_MEM" "$MAS_CPU" "${VM_DIR}/${CLUSTER_NAME}-master-${i}.qcow2" "http://${LBIP}:${WS_PORT}/master.ign"
done

# Create Worker VMs
for i in $(seq 1 "${N_WORK}"); do
    create_vm "${CLUSTER_NAME}-worker-${i}" "$WOR_MEM" "$WOR_CPU" "${VM_DIR}/${CLUSTER_NAME}-worker-${i}.qcow2" "http://${LBIP}:${WS_PORT}/worker.ign"
done

# Function to wait for VM installations to complete
wait_for_installation() {
    echo "====> Waiting for RHCOS installation to finish: "
    local rvms
    while rvms=$(virsh list --name --state-running | grep "${CLUSTER_NAME}-master-\|${CLUSTER_NAME}-worker-\|${CLUSTER_NAME}-bootstrap" 2> /dev/null); do
        sleep 15
        echo "  --> VMs with pending installation: $(echo "$rvms" | tr '\n' ' ')"
    done
}

# Function to start a VM
start_vm() {
    local vm_name="$1"
    echo -n "====> Starting ${vm_name} VM: "
    virsh start "$vm_name" > /dev/null || err "Failed to start VM: ${vm_name}"
    ok
}

# Function to set up DHCP reservation for a VM
setup_dhcp_reservation() {
    local vm_name="$1"
    local ip_var="$2"

    echo -n "====> Waiting for ${vm_name} to obtain IP address: "
    local IP
    local MAC
    while true; do
        sleep 5
        IP=$(virsh domifaddr "${vm_name}" | grep ipv4 | head -n1 | awk '{print $4}' | cut -d'/' -f1 2> /dev/null)
        [[ -n "${IP}" ]] && { echo "${IP}"; break; }
    done
    MAC=$(virsh domifaddr "$vm_name" | grep ipv4 | head -n1 | awk '{print $2}')
    eval "${ip_var}='${IP}'"

    echo -n "  ==> Adding DHCP reservation for ${vm_name}: "
    virsh net-update "${VIR_NET}" add-last ip-dhcp-host --xml "<host mac='$MAC' ip='$IP'/>" --live --config > /dev/null || \
        err "Failed to add DHCP reservation for ${vm_name}"
    ok
}

# Start and configure DHCP for Bootstrap, Masters, and Workers
start_vm "${CLUSTER_NAME}-bootstrap"
setup_dhcp_reservation "${CLUSTER_NAME}-bootstrap" BSIP

for i in $(seq 1 "${N_MAST}"); do
    start_vm "${CLUSTER_NAME}-master-${i}"
    setup_dhcp_reservation "${CLUSTER_NAME}-master-${i}" "MASTER_IP_${i}"
    echo -n "  ==> Adding SRV record in dnsmasq for Master-${i}: "
    echo "srv-host=_etcd-server-ssl._tcp.${CLUSTER_NAME}.${BASE_DOM},etcd-$((i-1)).${CLUSTER_NAME}.${BASE_DOM},2380,0,10" >> "${DNS_DIR}/${CLUSTER_NAME}.conf" || \
        err "Failed to add SRV record for Master-${i}"
    ok
done

for i in $(seq 1 "${N_WORK}"); do
    start_vm "${CLUSTER_NAME}-worker-${i}"
    setup_dhcp_reservation "${CLUSTER_NAME}-worker-${i}" "WORKER_IP_${i}"
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

# Configure HAProxy on Load Balancer
configure_haproxy() {
    echo -n "====> Configuring HAProxy on Load Balancer VM: "
    ssh -i sshkey "lb.${CLUSTER_NAME}.${BASE_DOM}" <<EOF
        semanage port -a -t http_port_t -p tcp 6443 || true
        semanage port -a -t http_port_t -p tcp 22623 || true
        systemctl start haproxy || err "Failed to start haproxy"
        systemctl -q enable haproxy
        systemctl -q is-active haproxy || err "HAProxy is not active"
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
