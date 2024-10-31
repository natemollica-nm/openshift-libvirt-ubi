#!/bin/bash

echo
echo "#################################"
echo "### CREATING LOAD BALANCER VM ###"
echo "#################################"
echo

# Function to download and copy the load balancer image
download_and_prepare_lb_image() {
    local lb_img="${LB_IMG_URL##*/}"
    echo -n "====> Downloading ${lb_img} cloud image: "
    download get "$lb_img" "$LB_IMG_URL"

    echo -n "====> Copying ${lb_img} for Load Balancer VM: "
    cp "${CACHE_DIR}/${lb_img}" "${VM_DIR}/${CLUSTER_NAME}-lb.qcow2" || \
        err "Failed to copy '${CACHE_DIR}/${lb_img}' to '${VM_DIR}/${CLUSTER_NAME}-lb.qcow2'"
    ok
}

# Function to customize the VM image
customize_lb_image() {
    echo "====> Setting up Load Balancer VM image: "
    virt-customize -a "${VM_DIR}/${CLUSTER_NAME}-lb.qcow2" \
        --uninstall cloud-init \
        --ssh-inject root:file:${SSH_PUB_KEY_FILE} \
        --install haproxy,bind-utils \
        --copy-in install_dir/bootstrap.ign:/opt/ \
        --copy-in install_dir/master.ign:/opt/ \
        --copy-in install_dir/worker.ign:/opt/ \
        --copy-in "${CACHE_DIR}/${IMAGE}":/opt/ \
        --copy-in tmpws.service:/etc/systemd/system/ \
        --copy-in haproxy.cfg:/etc/haproxy/ \
        --run-command "systemctl daemon-reload" \
        --run-command "systemctl enable tmpws.service" || \
        err "Failed to set up Load Balancer VM image ${VM_DIR}/${CLUSTER_NAME}-lb.qcow2"
}

# Function to create and configure the Load Balancer VM
create_lb_vm() {
    echo -n "====> Creating Load Balancer VM: "
    virt-install --name "${CLUSTER_NAME}-lb" \
        --import \
        --cpu host \
        --vcpus "${LB_CPU}" \
        --memory "${LB_MEM}" \
        --os-variant rhel9.0 \
        --disk "${VM_DIR}/${CLUSTER_NAME}-lb.qcow2" \
        --network network="${VIR_NET}",model=virtio \
        --noreboot \
        --noautoconsole > /dev/null || \
        err "Failed to create Load Balancer VM from ${VM_DIR}/${CLUSTER_NAME}-lb.qcow2"
    ok
}

# Function to start the VM and obtain its IP address
start_lb_vm() {
    echo -n "====> Starting Load Balancer VM: "
    virsh start "${CLUSTER_NAME}-lb" > /dev/null || err "Failed to start Load Balancer VM ${CLUSTER_NAME}-lb"
    ok

    echo -n "====> Waiting for Load Balancer VM to obtain IP address: "
    while true; do
        sleep 5
        LBIP=$(virsh domifaddr "${CLUSTER_NAME}-lb" | grep ipv4 | head -n1 | awk '{print $4}' | cut -d'/' -f1 2> /dev/null)
        if [[ -n "$LBIP" ]]; then
            echo "$LBIP"
            break
        fi
    done
    MAC=$(virsh domifaddr "${CLUSTER_NAME}-lb" | grep ipv4 | head -n1 | awk '{print $2}')
}

# Function to add DHCP reservation for the Load Balancer VM IP
add_dhcp_reservation() {
    echo -n "====> Adding DHCP reservation for LB IP/MAC: "
    virsh net-update "${VIR_NET}" add-last ip-dhcp-host --xml "<host mac='$MAC' ip='$LBIP'/>" --live --config &> /dev/null || \
        err "Failed to add DHCP reservation for $LBIP/$MAC"
    ok
}

# Function to update /etc/hosts with Load Balancer entries
update_hosts_file() {
    echo -n "====> Adding Load Balancer entry in /etc/hosts.${CLUSTER_NAME}: "
    echo "$LBIP lb.${CLUSTER_NAME}.${BASE_DOM} api.${CLUSTER_NAME}.${BASE_DOM} api-int.${CLUSTER_NAME}.${BASE_DOM}" \
        >> "/etc/hosts.${CLUSTER_NAME}" || err "Failed to add entries to /etc/hosts.${CLUSTER_NAME}"
    ok

    systemctl "$DNS_CMD" "$DNS_SVC" || err "Failed to reload DNS service $DNS_SVC"
}

# Function to wait for SSH access to the Load Balancer VM
wait_for_ssh_access() {
    echo -n "====> Waiting for SSH access on Load Balancer VM: "
    ssh-keygen -R "lb.${CLUSTER_NAME}.${BASE_DOM}" &> /dev/null || true
    ssh-keygen -R "${LBIP}" &> /dev/null || true

    while true; do
        sleep 1
        if ssh -i sshkey -o StrictHostKeyChecking=no "lb.${CLUSTER_NAME}.${BASE_DOM}" true &> /dev/null; then
            break
        fi
    done
    ssh -i sshkey "lb.${CLUSTER_NAME}.${BASE_DOM}" true || err "Failed SSH access to lb.${CLUSTER_NAME}.${BASE_DOM}"
    ok
}

# Execute the steps
download_and_prepare_lb_image
customize_lb_image
create_lb_vm
start_lb_vm
add_dhcp_reservation
update_hosts_file
wait_for_ssh_access
