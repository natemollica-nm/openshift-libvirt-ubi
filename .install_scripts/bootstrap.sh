#!/bin/bash

echo 
echo "################################"
echo "#### OPENSHIFT BOOTSTRAPPING ###"
echo "################################"
echo 

# Backup and set kubeconfig
initialize_kubeconfig() {
    cp install_dir/auth/kubeconfig install_dir/auth/kubeconfig.orig
    export KUBECONFIG="install_dir/auth/kubeconfig"
}

# Wait for Kubernetes API and other components to become available on the bootstrap node
monitor_bootstrap_progress() {
    echo "====> Waiting for Bootstrapping to finish: "
    echo "(Monitoring activity on bootstrap.${CLUSTER_NAME}.${BASE_DOM})"

    local s_api="Down"
    local btk_started=0
    local no_output_counter=0
    local output_flag

    declare -a a_dones=()
    declare -a a_conts=()
    declare -a a_images=()
    declare -a a_nodes=()

    while true; do
        output_flag=0

        # Check if Kubernetes API is up
        if [[ "$s_api" == "Down" ]]; then
            if ./oc get --raw / &> /dev/null; then
                echo "  ==> Kubernetes API is Up"
                s_api="Up"
                output_flag=1
            fi
        else
            # Check for new nodes
            nodes=($(./oc get nodes 2> /dev/null | grep -v "^NAME" | awk '{print $1 "_" $2}')) || true
            for n in "${nodes[@]}"; do
                if [[ ! " ${a_nodes[*]} " =~ " ${n} " ]]; then
                    echo "  --> Node $(echo "$n" | tr '_' ' ')"
                    a_nodes+=("$n")
                    output_flag=1
                fi
            done
        fi

        # Check for new images
        images=($(ssh -i sshkey "core@bootstrap.${CLUSTER_NAME}.${BASE_DOM}" \
            "sudo podman images 2> /dev/null | grep -v '^REPOSITORY' | awk '{print \$1 \"-\" \$3}'")) || true
        for i in "${images[@]}"; do
            if [[ ! " ${a_images[*]} " =~ " ${i} " ]]; then
                echo "  --> Image Downloaded: ${i}"
                a_images+=("$i")
                output_flag=1
            fi
        done

        # Check for completed phases
        dones=($(ssh -i sshkey "core@bootstrap.${CLUSTER_NAME}.${BASE_DOM}" "ls /opt/openshift/*.done 2> /dev/null")) || true
        for d in "${dones[@]}"; do
            if [[ ! " ${a_dones[*]} " =~ " ${d} " ]]; then
                echo "  --> Phase Completed: $(basename "$d" .done)"
                a_dones+=("$d")
                output_flag=1
            fi
        done

        # Check for new containers
        conts=($(ssh -i sshkey "core@bootstrap.${CLUSTER_NAME}.${BASE_DOM}" \
            "sudo crictl ps -a 2> /dev/null | grep -v '^CONTAINER' | rev | awk '{print \$4 \"_\" \$2 \"_\" \$3}' | rev")) || true
        for c in "${conts[@]}"; do
            if [[ ! " ${a_conts[*]} " =~ " ${c} " ]]; then
                echo "  --> Container: $(echo "$c" | tr '_' ' ')"
                a_conts+=("$c")
                output_flag=1
            fi
        done

        # Check bootkube service status
        btk_stat=$(ssh -i sshkey "core@bootstrap.${CLUSTER_NAME}.${BASE_DOM}" "sudo systemctl is-active bootkube.service 2> /dev/null") || true
        if [[ "$btk_stat" == "active" && "$btk_started" -eq 0 ]]; then
            btk_started=1
        fi

        # Handle no output scenario
        if [[ "$output_flag" -eq 0 ]]; then
            no_output_counter=$((no_output_counter + 1))
        else
            no_output_counter=0
        fi

        if [[ "$no_output_counter" -gt 8 ]]; then
            echo "  --> (bootkube.service is ${btk_stat}, Kube API is ${s_api})"
            no_output_counter=0
        fi

        # Exit conditions
        if [[ "$btk_started" -eq 1 && "$btk_stat" == "inactive" && "$s_api" == "Down" ]]; then
            echo '[Warning] Something went wrong. bootkube.service failed to bring up Kube API'
        fi

        if [[ "$btk_stat" == "inactive" && "$s_api" == "Up" ]]; then
            break
        fi

        sleep 15
    done
}

# Wait for bootstrap to complete
wait_for_bootstrap_completion() {
    ./openshift-install --dir=install_dir wait-for bootstrap-complete
}

# Remove the bootstrap VM if specified
remove_bootstrap_vm() {
    echo -n "====> Removing Bootstrap VM: "
    if [[ "$KEEP_BS" == "no" ]]; then
        virsh destroy "${CLUSTER_NAME}-bootstrap" > /dev/null || err "Failed to destroy ${CLUSTER_NAME}-bootstrap"
        virsh undefine "${CLUSTER_NAME}-bootstrap" --remove-all-storage > /dev/null || err "Failed to undefine ${CLUSTER_NAME}-bootstrap"
        ok
    else
        ok "skipping"
    fi
}

# Update HAProxy configuration on the Load Balancer
update_haproxy_config() {
    echo -n "====> Removing Bootstrap from HAProxy: "
    ssh -i sshkey "lb.${CLUSTER_NAME}.${BASE_DOM}" \
        "sed -i '/bootstrap\.${CLUSTER_NAME}\.${BASE_DOM}/d' /etc/haproxy/haproxy.cfg" || err "Failed to update HAProxy configuration"
    ssh -i sshkey "lb.${CLUSTER_NAME}.${BASE_DOM}" "systemctl restart haproxy" || err "Failed to restart HAProxy"; ok
}

# Main execution flow
initialize_kubeconfig
monitor_bootstrap_progress
wait_for_bootstrap_completion
remove_bootstrap_vm
update_haproxy_config
