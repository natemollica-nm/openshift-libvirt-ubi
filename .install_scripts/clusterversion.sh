#!/bin/bash

echo 
echo "#################################"
echo "#### OPENSHIFT CLUSTERVERSION ###"
echo "#################################"
echo 

# Variables
ingress_patched=0
imgreg_patched=0
output_delay=0
nodes_total=$((N_MAST + N_WORK))
nodes_ready=0

# Function to patch the image registry
patch_image_registry() {
    echo -n '  --> Patching image registry to use EmptyDir: '
    ./oc patch configs.imageregistry.operator.openshift.io cluster \
        --type merge \
        --patch '{"spec":{"storage":{"emptyDir":{}}}}' &> /dev/null && imgreg_patched=1 || true

    sleep 30
    [[ "$imgreg_patched" -eq 1 ]] && \
        ./oc patch configs.imageregistry.operator.openshift.io cluster \
        --type merge \
        --patch '{"spec":{"managementState": "Managed"}}' &> /dev/null || true
}

# Function to patch the ingress controller
patch_ingress_controller() {
    echo -n '  --> Patching ingress controller to run router pods on master nodes: '
    ./oc patch ingresscontroller default -n openshift-ingress-operator \
        --type merge \
        --patch '{
            "spec":{
                "replicas": '"${N_MAST}"',
                "nodePlacement":{
                    "nodeSelector":{
                        "matchLabels":{
                            "node-role.kubernetes.io/master":""
                        }
                    },
                    "tolerations":[{
                        "effect": "NoSchedule",
                        "operator": "Exists"
                    }]
                }
            }
        }' &> /dev/null && ingress_patched=1 || true
}

# Function to approve pending CSRs
approve_pending_csrs() {
    for csr in $(./oc get csr 2> /dev/null | grep -w 'Pending' | awk '{print $1}'); do
        echo "  --> Approving CSR: $csr"
        ./oc adm certificate approve "$csr" &> /dev/null || true
        output_delay=0
    done
}

# Function to check the readiness of the clusterversion and nodes
monitor_clusterversion() {
    echo "====> Waiting for clusterversion: "

    while true; do
        local cv_prog_msg cv_avail
        cv_prog_msg=$(./oc get clusterversion -o jsonpath='{.items[*].status.conditions[?(.type=="Progressing")].message}' 2> /dev/null) || continue
        cv_avail=$(./oc get clusterversion -o jsonpath='{.items[*].status.conditions[?(.type=="Available")].status}' 2> /dev/null) || continue
        nodes_ready=$(./oc get nodes | grep 'Ready' | wc -l)

        # Patch the image registry if not already patched
        if [[ "$imgreg_patched" -eq 0 ]]; then
            ./oc get configs.imageregistry.operator.openshift.io cluster &> /dev/null && \
                { sleep 30; patch_image_registry; }
        fi

        # Patch the ingress controller if not already patched
        if [[ "$ingress_patched" -eq 0 ]]; then
            ./oc get -n openshift-ingress-operator ingresscontroller default &> /dev/null && \
                { sleep 30; patch_ingress_controller; }
        fi

        # Approve pending CSRs
        approve_pending_csrs

        # Display progress message if output delay is reached
        if [[ "$output_delay" -gt 8 ]]; then
            if [[ "$cv_avail" == "True" ]]; then
                echo "  --> Waiting for all nodes to be ready: $nodes_ready/$nodes_total"
            else
                echo "  --> ${cv_prog_msg:0:70}${cv_prog_msg:71:+...}"
            fi
            output_delay=0
        fi

        # Check if installation is complete
        if [[ "$cv_avail" == "True" && "$nodes_ready" -ge "$nodes_total" ]]; then
            break
        fi

        output_delay=$((output_delay + 1))
        sleep 15
    done
}

# Execute the functions
monitor_clusterversion

# Calculate time taken
export END_TS=$(date +%s)
export TIME_TAKEN="$(( (END_TS - START_TS) / 60 ))"

echo
echo "#######################################################"
echo "#### OPENSHIFT 4 INSTALLATION FINISHED SUCCESSFULLY ###"
echo "#######################################################"
echo "          time taken = $TIME_TAKEN minutes"
echo

# Complete the installation process
./openshift-install --dir=install_dir wait-for install-complete
