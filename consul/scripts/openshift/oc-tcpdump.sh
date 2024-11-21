#!/usr/bin/env bash

eval "$(cat scripts/logging.sh)"
eval "$(cat scripts/formatting.env)"

# Global Variables
export CONTEXT=dc1
export DEBUG_POD
export DEBUG_NAMESPACE
export SELECTED_POD
export SELECTED_NODE
export SELECTED_NAMESPACE
export SELECTED_INTERFACE=eth0
export NSENTER_PARAMS
export COMMAND=false
export PRESELECTED_POD_PREFIX
export PRESELECTED_NAMESPACE

exit_code=0
trap 'cleanup' EXIT TERM
# Cleanup resources
cleanup() {
    info "oc-debug: Running post script execution cleanup..."
    delete_existing_debug_pods
    info "oc-debug: Done!"
    exit "$exit_code"
}

# Define the banner function
banner() {
  echo -e "\n${LIGHT_CYAN}${BOLD}Consul K8s on AWS OpenShift | OC Debug${RESET}${LIGHT_CYAN}${RESET}"
  echo -e "${DIM}::OpenShift Debug Helper Script::${RESET}\n"
}

## Define usage script
usage() {
  echo -e "
  Usage: ${CYAN}$(basename "$0")${RESET} ${MAGENTA}[parameters]${RESET} ${BLUE}[options]${RESET}

  ${MAGENTA}Parameters:${RESET} ${RED}(Required)${RESET}
    --context              ${DIM}Specify the kubeconfig context to use. Default is 'dc1'.${RESET}
    --tcp-dump, -t         ${DIM}Run oc debug tcp dump on pod interface.${RESET}
    --preselected-pod, -p  ${DIM}Specify the pod name prefix to pre-select.${RESET}
    --namespace, -n        ${DIM}Specify the namespace to pre-select.${RESET}

  ${BLUE}Options:${RESET}
    --help:           ${DIM}Show this menu.${RESET}
"
  exit "$1"
}

# Function to list and delete existing debug pods
delete_existing_debug_pods() {
    local pod_info line
    local pod_lines
    local delete_choice namespace
    local pod_name ns p_name

    info "Searching for existing debug pods ..."
    # Fetching all pods across all namespaces that match the pattern 'internal-debug', along with their namespaces
    pod_info=$(oc --context "${CONTEXT}" get pods --all-namespaces --no-headers --ignore-not-found | grep 'internal-debug')

    if [ -z "$pod_info" ]; then
        info "No existing debug pods found."
        return 0
    else

        ns="$(echo "$pod_info" | awk '{print "Namespace: " $1}')"
        p_name="$(echo "$pod_info" | awk '{print "Pod: " $2}')"
        print_msg "Existing debug pods found" \
            "$ns" \
            "$p_name"
    fi

    # Use readarray to store each line of pod_info into an array
    readarray -t pod_lines <<<"$pod_info"

    for line in "${pod_lines[@]}"; do
        # Extracting namespace and pod name using awk
        namespace=$(awk '{print $1}' <<<"$line")
        pod_name=$(awk '{print $2}' <<<"$line")

        # Prompt for deletion of each individual pod
        prompt "Do you want to delete pod $pod_name in namespace $namespace? [Y/n]: "
        read -r delete_choice </dev/stdin
        if [[ "$delete_choice" =~ ^[Yy] ]]; then
            info "Deleting pod: $pod_name in namespace: $namespace"
            oc --context "${CONTEXT}" delete pod "$pod_name" -n "$namespace" >/dev/null 2>&1 || {
                err "Failed to run pod deletion for $pod_name in namespace $namespace"
                return 1
            }
        else
            info "Skipping deletion of pod: $pod_name"
        fi
    done
}
# Function to create a new debug pod
create_new_debug_pod() {
    local pod_info i

    info "Creating a new debug pod for $SELECTED_NODE node ..."
    oc --context "${CONTEXT}" debug node/"$SELECTED_NODE" --as-root=true --preserve-pod=true --quiet=true --tty=false -- /bin/sh -c "while true; do sleep 2; done" &
    info "oc debug command return code: $!"
    sleep 3
    i=0
    pod_info=$(oc --context "${CONTEXT}" get pods --all-namespaces --no-headers --ignore-not-found | grep -E 'internal-debug|openshift-debug' | head -n1)
    while [ -z "$pod_info" ]; do
        info "Debug pod still not fully up, sleeping ..."
        pod_info=$(oc --context "${CONTEXT}" get pods --all-namespaces --no-headers --ignore-not-found | grep -E 'internal-debug|openshift-debug' | head -n1)
        sleep 2 && i=$((i+1))
        if [[ $i -eq 10 ]]; then
            err "Timed out waiting for pod creation (20s), exiting ..."
            return 1
        fi
    done
    # Extracting namespace and pod name using awk
    DEBUG_NAMESPACE=$(echo "$pod_info" | awk '{print $1}')
    DEBUG_POD=$(echo "$pod_info" | awk '{print $2}')

    info "Waiting for $DEBUG_POD to be ready in $DEBUG_NAMESPACE namespace..."
    oc --context "${CONTEXT}" wait -n "$DEBUG_NAMESPACE" pod/"$DEBUG_POD" --for=condition=Ready --timeout=60s
    info "Debug pod $DEBUG_POD created in namespace $DEBUG_NAMESPACE."
}

# Function to select or create a debug pod
select_or_create_debug_pod() {
    local pod_info options opt pods_found
    # Fetching all pods across all namespaces that match the pattern 'internal-debug', along with their namespaces
    info "Searching for existing debug pods ..."
    pod_info=$(oc --context "${CONTEXT}" get pods --all-namespaces --no-headers --ignore-not-found | grep 'internal-debug')

    if [ -z "$pod_info" ]; then
        info "No existing debug pods found. Creating a new debug pod ..."
        create_new_debug_pod
        return
    fi
    info "Found existing debug pods"
    mapfile -t pods_found < <(echo "$pod_info" | awk '{print $1 ":" $2}') # Create array of "namespace:podname"

    PS3="Select a debug pod to reuse or choose to create a new one: "
    options=("${pods_found[@]}" "Create new debug pod")
    select opt in "${options[@]}"; do
        case $opt in
            "Create new debug pod")
                create_new_debug_pod
                break
                ;;
            *)
                DEBUG_NAMESPACE=${opt%:*} # Everything before the last colon
                DEBUG_POD=${opt#*:} # Everything after the first colon
                echo "Reusing pod: $DEBUG_POD in namespace: $DEBUG_NAMESPACE"
                break
                ;;
        esac
    done
}
# Function to select the pod based on the preselected prefix and namespace
preselected_pod() {
    local pod="$1"
    local namespace="$2"
    local selected_pod

    info "Fetching pod with prefix ${pod} in namespace ${namespace} ..."
    selected_pod=$(oc --context "${CONTEXT}" get pods -n "${namespace}" --field-selector=status.phase=Running -o json | jq -r --arg PREFIX "${pod}" '.items[] | select(.metadata.name | startswith($PREFIX)) | .metadata.name')

    if [ -z "$selected_pod" ]; then
        err "No pod found with prefix $pod in namespace $namespace."
        return 1
    fi
    export SELECTED_POD="$selected_pod"
    export PRESELECTED_NAMESPACE="$namespace"
    info "Found pod: $SELECTED_POD"
}

# Function to select the node the pod is running on
find_pod_node() {
    info "Finding node for pod: $SELECTED_POD in namespace $PRESELECTED_NAMESPACE..."
    SELECTED_NODE=$(oc --context "${CONTEXT}" get pod "$SELECTED_POD" -n "$PRESELECTED_NAMESPACE" -o jsonpath='{.spec.nodeName}' | head -n1)

    if [ -z "$SELECTED_NODE" ]; then
        err "No node found for pod $SELECTED_POD."
        return 1
    fi

    info "Pod $SELECTED_POD is running on node: $SELECTED_NODE"
}

# Function to set nsenter parameters for accessing a pod's network namespace
set_nsenter_params() {
    local pod_crictl_id pod_crictl_namespace

    info "Retrieving $SELECTED_POD pod crictl ID"
    pod_crictl_id="$(oc --context "${CONTEXT}" exec -n "$DEBUG_NAMESPACE" "$DEBUG_POD" -- chroot /host crictl pods --namespace "$PRESELECTED_NAMESPACE" --name "$SELECTED_POD" -q)"
    if [ -z "$pod_crictl_id" ]; then
        err "Pod ID could not be found. Make sure you have entered the correct pod name and namespace."
        return 1
    fi

    info "Retrieving $DEBUG_POD pod network namespace host path"
    pod_crictl_namespace="/host/$(oc --context "${CONTEXT}" exec -n "$DEBUG_NAMESPACE" "$DEBUG_POD" -- chroot /host bash -c "crictl inspectp $pod_crictl_id | jq '.info.runtimeSpec.linux.namespaces[] | select(.type==\"network\").path' -r")"
    if [ -z "$pod_crictl_namespace" ]; then
        err "Namespace path could not be determined."
        return 1
    fi

    NSENTER_PARAMS="--net=${pod_crictl_namespace}"
    info "nsenter parameters set: $NSENTER_PARAMS"
}

# Run tcpdump for a default 30s duration
run_tcpdump() {
    local TCPDUMP_FILE
    local copy_answer tcpdump_copypath selection_made

    # shellcheck disable=SC1001
    TCPDUMP_FILE="${SELECTED_POD}"_"$(date +\%d_%m_%Y-%H_%M_%S-%Z)".pcap

    info "Running tcpdump on interface $SELECTED_INTERFACE for 30 seconds. Please wait ..."
    oc --context "${CONTEXT}" exec "$DEBUG_POD" -n "$DEBUG_NAMESPACE" -- timeout 30 nsenter "$NSENTER_PARAMS" -- tcpdump -nn -vvv --interface="${SELECTED_INTERFACE}" -s 9216 -w /host/var/tmp/"$TCPDUMP_FILE" &
    wait $!

    # Option to copy the dump file to the local machine
    prompt "Would you like to copy the tcpdump capture file to your local machine? [Y/n]: "
    read -r copy_answer </dev/stdin
    if [[ ! "$copy_answer" =~ ^[Nn]$ ]]; then
        prompt "Enter local filepath save location: "
        read -r tcpdump_copypath </dev/stdin
        oc --context "${CONTEXT}" cp "$DEBUG_NAMESPACE/$DEBUG_POD:/host/var/tmp/$TCPDUMP_FILE" "$tcpdump_copypath/$TCPDUMP_FILE" >/dev/null 2>&1 || {
            err "Failed to copy $DEBUG_NAMESPACE/$DEBUG_POD:/host/var/tmp/$TCPDUMP_FILE $tcpdump_copypath/$TCPDUMP_FILE"
            return 1
        }
        info "Dump file copied to $tcpdump_copypath/$TCPDUMP_FILE"
        return 0
    fi
}

while [ "$#" -gt 0 ]; do
    case "${1%=*}" in
      --context)
          CONTEXT="$2"
          shift
          ;;
      --preselected-pod|-p)
          PRESELECTED_POD_PREFIX="$2"
          shift
          ;;
      --namespace|-n)
          PRESELECTED_NAMESPACE="$2"
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
    preselected_pod "$PRESELECTED_POD_PREFIX" "$PRESELECTED_NAMESPACE" || {
        err "Failed to find preselected pod"
        return 1
    }
    clear
    find_pod_node || {
        err "Failed to find node for pod"
        return 1
    }
    clear
    select_or_create_debug_pod || {
        err "Failed to select/create debug pod"
        return 1
    }
    clear
    set_nsenter_params || {
        err "Failed to set nsenter parameters"
        return 1
    }
    clear
    run_tcpdump || {
        err "Failed to run tcpdump on debug pod"
        return 1
    }
    info "Successfully completed tcpdump capture on $SELECTED_NODE for $SELECTED_POD!"
}

banner
main || {
    err "oc-debug: Failed!"
    exit
}
