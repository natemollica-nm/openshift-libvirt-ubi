#!/usr/bin/env bash

eval "$(cat scripts/logging.sh)"
eval "$(cat scripts/formatting.env)"

# Global Variables
export CONTEXT=dc1
export DEBUG_POD
export DEBUG_NAMESPACE
export NODE_IP
export SELECTED_NODE
export INTERFACE=br-ex
export DEBUG_TOOLBOX=false

exit_code=0
trap 'cleanup' EXIT TERM
# Cleanup resources
cleanup() {
    info "oc-debug: Running post script execution cleanup..."
    delete_existing_debug_pods "$SELECTED_NODE"
    info "oc-debug: Done!"
    exit "$exit_code"
}


# Define the banner function
banner() {
  echo -e "\n${LIGHT_CYAN}${BOLD}Consul K8s on AWS OpenShift | OC Node Level Debug${RESET}${LIGHT_CYAN}${RESET}"
  echo -e "${DIM}::OpenShift Node Level Debug Helper Script::${RESET}\n"
}

## Define usage script
usage() {
    echo -e "
      Usage: ${CYAN}$(basename "$0")${RESET} ${MAGENTA}[parameters]${RESET} ${BLUE}[options]${RESET}

      ${MAGENTA}Parameters:${RESET} ${RED}(Required)${RESET}
        --context      ${DIM}Specify the kubeconfig context to use. Default is 'dc1'.${RESET}
        --node, -n     ${DIM}Specify the node to run the tcpdump on.${RESET}

      ${BLUE}Options:${RESET}
        --help:        ${DIM}Show this menu.${RESET}
  "
    exit "$1"
}

# Function to list and delete existing debug pods
delete_existing_debug_pods() {
    local node="$1"
    local pod_info

    info "Searching for existing debug pods on $node"
    # Fetching all pods across all namespaces that match the pattern 'internal-debug', along with their namespaces
    pod_info=$(oc --context "${CONTEXT}" get pods --all-namespaces --no-headers --ignore-not-found --field-selector spec.nodeName="$node" | grep 'internal-debug')

    if [ -z "$pod_info" ]; then
        info "No existing debug pods found on node $node."
        return 0
    else
        local ns
        local p_name
        ns="$(echo "$pod_info" | awk '{print "Namespace: " $1}')"
        p_name="$(echo "$pod_info" | awk '{print "Pod: " $2}')"
        print_msg "Existing debug pods found" \
            "$ns" \
            "$p_name"
    fi

    # Use readarray to store each line of pod_info into an array
    local pod_lines
    readarray -t pod_lines <<<"$pod_info"
    local line
    for line in "${pod_lines[@]}"; do
        local pod_name
        local namespace
        # Extracting namespace and pod name using awk
        namespace=$(awk '{print $1}' <<<"$line")
        pod_name=$(awk '{print $2}' <<<"$line")

        # Prompt for deletion of each individual pod
        local delete_choice
        prompt "Do you want to delete pod $namespace/$pod_name on $node? [Y/n]: "
        read -r delete_choice </dev/stdin
        if [[ "$delete_choice" =~ ^[Yy] ]]; then
            info "Deleting pod $namespace/$pod_name on $node"
            oc --context "${CONTEXT}" --namespace "$namespace" delete pod "$pod_name" >/dev/null 2>&1 || {
                err "Failed to delete $namespace/$pod_name on $node!"
                return 1
            }
        else
            info "Skipping deletion of pod: $pod_name"
        fi
    done
}

# Function to select or create a debug pod for the selected node
create_node_debug_pod() {
    local node="$1"
    local pod_info i

    info "Creating a new debug pod for $node node ..."
    oc --context "${CONTEXT}" debug node/"$node" --as-root=true --preserve-pod=true --quiet=true --tty=false -- /bin/sh -c "while true; do sleep 2; done" &
    info "oc debug command return code: $!"
    sleep 3
    i=0

    pod_info=$(oc --context "${CONTEXT}" get pods --all-namespaces --no-headers --ignore-not-found --field-selector spec.nodeName="$node" -o yaml | yq '.items[] | select(.metadata.name|contains("internal-debug"))' -)
    while [ -z "$pod_info" ]; do
        info "Debug pod still not fully up, sleeping ..."
        pod_info=$(oc --context "${CONTEXT}" get pods --all-namespaces --no-headers --ignore-not-found --field-selector spec.nodeName="$node" -o yaml | yq '.items[] | select(.metadata.name|contains("internal-debug"))' -)
        sleep 2 && i=$((i+1))
        if [[ $i -eq 10 ]]; then
            err "Timed out waiting for pod creation (20s), exiting ..."
            return 1
        fi
    done
    # Extracting namespace and pod name using awk
    DEBUG_NAMESPACE=$(echo "$pod_info" | yq eval '.metadata.namespace' -)
    DEBUG_POD=$(echo "$pod_info" | yq eval '.metadata.name' -)
    export NODE_IP=$(echo "$pod_info" |  yq eval '.status.hostIP' -)
    info "Waiting for $DEBUG_POD to be ready in $DEBUG_NAMESPACE namespace..."
    oc --context "${CONTEXT}" wait -n "$DEBUG_NAMESPACE" pod/"$DEBUG_POD" --for=condition=Ready --timeout=60s
    info "Debug pod $DEBUG_POD created in namespace $DEBUG_NAMESPACE | NodeIP: $NODE_IP"
}

# Run tcpdump for a default 30s duration on the br-ex interface
run_node_tcpdump() {
    local node="$1"
    local TCPDUMP_FILE
    local copy_answer tcpdump_copypath selection_made

    # shellcheck disable=SC1001
    TCPDUMP_FILE="${SELECTED_NODE}"_"$(date +\%d_%m_%Y-%H_%M_%S-%Z)".pcap

    info "Running tcpdump on interface $INTERFACE for 30 seconds. Please wait ..."
    # Execute the tcpdump command inside the toolbox container
    oc --context "${CONTEXT}" exec "$DEBUG_POD" -n "$DEBUG_NAMESPACE" -- timeout 30 tcpdump -nn -vvv --interface="${INTERFACE}" -s 0 -w /host/var/tmp/"$TCPDUMP_FILE" &
    wait $!

    # Option to copy the dump file to the local machine
    [ -z "$NODE_IP" ] && err "Unknown nodeIP! Cannot copy tcpdump to local machine" && return 1
    prompt "Would you like to copy the tcpdump capture file to your local machine? [Y/n]: "
    read -r copy_answer </dev/stdin
    if [[ ! "$copy_answer" =~ ^[Nn]$ ]]; then
        prompt "Enter local filepath save location: "
        read -r tcpdump_copypath </dev/stdin
        scp -i aws-ssh-keys/openshift-key.pem core@"$NODE_IP:/var/tmp/$TCPDUMP_FILE" "$tcpdump_copypath/$TCPDUMP_FILE" >/dev/null 2>&1 || {
            err "Failed to copy $NODE_IP:/var/tmp/$TCPDUMP_FILE *==> $tcpdump_copypath/$TCPDUMP_FILE"
            return 1
        }
        info "Dump file copied *===> $tcpdump_copypath/$TCPDUMP_FILE!"
        return 0
    fi
}

while [ "$#" -gt 0 ]; do
    case "${1%=*}" in
      --context)
          CONTEXT="$2"
          shift
          ;;
      --node|-n)
          SELECTED_NODE="$2"
          shift
          ;;
      -h|-\?|--help)
          banner
          usage 0
          ;;
      *)
          warn "Unknown parameter: $1"
          usage 2
          ;;
    esac
    shift
done

# Main function
main() {
    clear
    if [ -z "$SELECTED_NODE" ]; then
        err "No node specified. Use --node or -n to specify a node."
        exit
    fi
    if ! oc --context "$CONTEXT" get nodes --no-headers --output name | grep -q "$SELECTED_NODE"; then
        err "Node $SELECTED_NODE not found in kube-context $CONTEXT, verify correct context and node name!"
        exit
    fi
    clear
    create_node_debug_pod "$SELECTED_NODE" || {
        err "Failed to create debug pod for node $SELECTED_NODE"
        return 1
    }
    clear
    run_node_tcpdump "$SELECTED_NODE" || {
        err "Failed to run tcpdump on node $SELECTED_NODE"
        return 1
    }
    info "Successfully completed tcpdump capture on $SELECTED_NODE!"
}

banner
main || {
    err "oc-node-debug: Failed!"
    exit
}
