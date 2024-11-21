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
export SELECTED_INTERFACE
export NSENTER_PARAMS
export TCPDUMP
export COMMAND

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
    --context        ${DIM}Specify the kubeconfig context to use. Default is 'dc1'.${RESET}
    --tcp-dump, -t:  ${DIM}Run oc debug tcp dump on pod interface${RESET}
    --command,  -c:  ${DIM}Run oc debug pod command for pods${RESET}

  ${BLUE}Options:${RESET}
    --help:           ${DIM}Show this menu${RESET}
"
  exit "$1"
}

# Confirm user's selection
# Usage: confirm "Are you sure?" && echo "User confirmed."
confirm() {
    local prompt="${1:-Are you sure?}"  # Default prompt message if none provided
    local response

    while true; do
        prompt "$prompt [y/n]: "
        read -r response </dev/stdin
        case "$response" in
            [yY][eE][sS]|[yY]) return 0 ;;  # User confirmed
            [nN][oO]|[nN]) return 1 ;;      # User denied
            *) echo "Please respond with yes or no." ;;  # Invalid response
        esac
    done
}

# Select OpenShift node
select_node() {
    local nodes node_choice

    info "Fetching OpenShift nodes..."
    nodes=$(oc --context "${CONTEXT}" get nodes -o name | sed 's/node\///')
    echo ""
    echo "Select a node for debugging:"
    select node_choice in $nodes; do
        if [ -n "$node_choice" ]; then
            if confirm "You've selected node $node_choice. Are you sure?"; then
              SELECTED_NODE="$node_choice"
              info "Proceeding with selected node: $SELECTED_NODE"; echo
              return 0
            else
              warn "Invalid selection or confirmation. Please select a node for debugging."
            fi
        fi
    done
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


# Function to list non-default namespaces and select one
select_namespace() {
    local namespaces namespace_choice

    info "Fetching OpenShift $SELECTED_NODE namespaces..."
    namespaces=$(oc --context "${CONTEXT}" get namespaces -o json | jq -r '.items[].metadata | select(.name | test("^(?!openshift|kube-).+")) | .name')
    if [ -z "$namespaces" ]; then
        err "No non-default namespaces found."
        return 1
    fi

    echo "Select a namespace:"
    select namespace_choice in $namespaces; do
        if [ -n "$namespace_choice" ]; then
            SELECTED_NAMESPACE="$namespace_choice"
            if confirm "Selected namespace: $SELECTED_NAMESPACE. Are you sure?"; then
              info "Continuing with namespace $SELECTED_NAMESPACE"
              return 0
            else
              warn "Entry rejected. Please select namespace for debugging."
            fi
        else
          warn "Invalid selection. Please try again"
        fi
    done
}

# Function to list pods in the selected namespace that are scheduled on the selected node and select one
select_pod() {
    local pods pod_choice running_pods
    if ! select_namespace; then
        return 1
    fi

    info "Fetching pods running in namespace $SELECTED_NAMESPACE on node $SELECTED_NODE ..."
    pods=$(oc --context "${CONTEXT}" get pods -n "$SELECTED_NAMESPACE" --field-selector=status.phase=Running -o json | jq -r --arg NODE "${SELECTED_NODE}" '.items[] | select(.spec.nodeName==$NODE) | .metadata.name')

    if [ -z "$pods" ]; then
        running_pods=$(oc get pods -n "$SELECTED_NAMESPACE" --field-selector=status.phase=Running -o json | jq -r '.items[] | {Pod: .metadata.name, Node: .spec.nodeName}')
        err "No running pods found in namespace $SELECTED_NAMESPACE on node $SELECTED_NODE"
        print_msg \
            "Pods running in $SELECTED_NAMESPACE namespace:" \
            "$(echo "$running_pods" | jq -r .)"
        return 1
    fi

    echo "Select a pod to debug:"
    select pod_choice in $pods; do
        if [ -n "$pod_choice" ]; then
            SELECTED_POD="$pod_choice"
            if confirm "Selected pod: $SELECTED_POD"; then
              info "Continuing with pod $SELECTED_POD"
              return 0
            else
              warn "Entry rejected. Please select a pod."
            fi
        else
            warn "Invalid selection. Please try again."
        fi
    done
}

# Function to set nsenter parameters for accessing a pod's network namespace
set_nsenter_params() {
    local pod_crictl_id pod_crictl_namespace

    if ! select_pod; then
        return 1
    fi

    info "Retrieving $SELECTED_POD pod crictl ID"
    pod_crictl_id="$(oc --context "${CONTEXT}" exec -n "$DEBUG_NAMESPACE" "$DEBUG_POD" -- chroot /host crictl pods --namespace "$SELECTED_NAMESPACE" --name "$SELECTED_POD" -q)"
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

# Select a network interface from the debug pod
select_interface() {
    local selected_interface interfaces interface_list selection
    local selection_made i
    local tcpdump_list ip_a_list

    info "Fetching network interfaces from the debug pod..."
    # Get the list of network interfaces
    # Attempt to list interfaces using tcpdump, then fallback to ip a if necessary
    tcpdump_list="$(oc --context "${CONTEXT}" exec -n "$DEBUG_NAMESPACE" "$DEBUG_POD" -- nsenter "$NSENTER_PARAMS" -- tcpdump --list-interfaces 2>/dev/null)"
    ip_a_list="$(oc --context "${CONTEXT}" exec -n "$DEBUG_NAMESPACE" "$DEBUG_POD" -- nsenter "$NSENTER_PARAMS" -- chroot /host ip a 2>/dev/null)"

    if [ -n "$tcpdump_list" ]; then
        interface_list="$tcpdump_list"
    elif [ -n "$ip_a_list" ]; then
        interface_list="$ip_a_list"
    else
        err "Failed to retrieve network interface list."
        return 1
    fi

    # Parse interface names depending on the source of interface_list
    if [ "$interface_list" = "$tcpdump_list" ]; then
        info "Using 'tcpdump -D' interface list for nic selection"
        # Parse tcpdump output (assuming format "1. eth0" etc.)
        mapfile -t interfaces <<< "$(echo "$interface_list" | awk -F' ' '{print $1}' | cut -d'.' -f2)"
    else
        info "Using 'ip a' interface list for nic selection"
        # Parse ip a output (assuming format "1: eth0: <INFO>" etc.)
        mapfile -t interfaces <<< "$(echo "$interface_list" | awk -F': ' '$0 ~ /^[0-9]+: /{print $2}')"
    fi

    # Check if interfaces were successfully parsed
    if [ "${#interfaces[@]}" -eq 0 ]; then
        err "Failed to retrieve network interface list, cancelling dump..."
        return 1
    fi
    selection_made=false
    while [ "$selection_made" != true ]; do
        # Display interfaces for selection
        info "Available Network Interfaces:"
        for i in "${!interfaces[@]}"; do
            echo "$((i+1))) ${interfaces[$i]}"
        done

        # Prompt user for selection
        prompt "Select an interface by number: "
        read -r selection </dev/stdin

        # Validate selection
        if ! [[ "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -gt "${#interfaces[@]}" ]; then
            warn "Invalid selection. Please select a number from the list."
            continue
        fi

        selected_interface="$(echo "${interfaces[$selection-1]}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | cut -d'@' -f1)"
        # Confirm selection
        if confirm "You selected $selected_interface. Continue?"; then
            selection_made=true
        else
            warn "Entry rejected. Please select an interface for tcpdump debugging."
            continue
        fi
    done
    # Further processing based on the selected interface
    info "Proceeding with interface: $selected_interface"
    SELECTED_INTERFACE="$selected_interface"
}

# Run tcpdump
run_tcpdump() {
    local TCPDUMP_FILE
    local duration copy_answer tcpdump_copypath selection_made
    local tcpdump_duration_set full_save_filepath tcpdump_extra_args

    # shellcheck disable=SC1001
    TCPDUMP_FILE="${SELECTED_POD}"_"$(date +\%d_%m_%Y-%H_%M_%S-%Z)".pcap
  
    tcpdump_duration_set=false
    while [ "$tcpdump_duration_set" != true ]; do
      prompt "Enter the duration for tcpdump (in seconds): "
      read -r duration </dev/stdin
      
      if confirm "You've entered $duration seconds for tcpdump capture. Is this correct?"; then
        info "Continuing with $duration tcpdump capture"
        tcpdump_duration_set=true
      else
        warn "Entry rejected. Please enter desired tcpdump duration."
      fi
    done

    if confirm "Would you like to add extra tcpdump args? (e.g., 'not port 22 and port 25')"; then
        prompt "Enter the extra tcpdump arguments: "
        read -r tcpdump_extra_args </dev/stdin
        if confirm "You've entered additional tcpdump arguments: '$tcpdump_extra_args'. Is this correct?"; then
            info "Continuing with additional tcpdump arguments: $tcpdump_extra_args"
        else
            info "Entry rejected. Skipping additional tcpdump arguments."
        fi
    fi

    info "Running tcpdump on interface $SELECTED_INTERFACE for $duration seconds. Please wait ..."
    # Run tcpdump in the background
    # timeout: Utility for running commands for specified duration. Useful here for cancelling the tcpdump run.
    # nsenter: Utility for running commands in the context of different namespaces. Required for CoreOS Rhel running the
    #          underlying containers and managing kernel level namespaces in OpenShift.
    # tcpdump: Utility for inspecting network packets
    #   -nn:   Tells tcpdump to
    #            1. Not resolve hostnames
    #            2. Not resolve port names
    #          Why: To help speed up the capture process by avoiding DNS and service name lookups
    #    -i:   (--interface) Specifies the NIC tcpdump should listen on. (i.e., eth0, ensp05, etc.)
    #    -s:   Capture length for jumbo frames (OpenShift need jumbo frames for VXLAN) up to 9216 bytes
    #    -w:   Specifies that tcpdump should write the packets to file rather than printing them out to stdout.
    oc --context "${CONTEXT}" exec "$DEBUG_POD" -n "$DEBUG_NAMESPACE" -- timeout "$duration" nsenter "$NSENTER_PARAMS" -- tcpdump -nn -vvv --interface="${SELECTED_INTERFACE}" -s 9216 -w /host/var/tmp/"$TCPDUMP_FILE" "${tcpdump_extra_args}" &
    wait $!

    # Option to copy the dump file to the local machine
    prompt "Would you like to copy the tcpdump capture file to your local machine? [Y/n]: "
    read -r copy_answer </dev/stdin
    if [[ ! "$copy_answer" =~ ^[Nn]$ ]]; then
        selection_made=false
        while [ "$selection_made" != true ]; do
            prompt "Enter local filepath save location: "
            read -r tcpdump_copypath </dev/stdin
            # Confirm selection
            if confirm "You have entered: '$(readlink -f "$tcpdump_copypath")'. Is this correct? (yes/no)"; then
                selection_made=true
                info "Copying tcpdump file to $tcpdump_copypath/$TCPDUMP_FILE"
            else
                warn "Entry rejected. Please enter filepath again."
            fi
        done
        full_save_filepath="$(readlink -f "$tcpdump_copypath")"
        oc --context "${CONTEXT}" cp "$DEBUG_NAMESPACE/$DEBUG_POD:/host/var/tmp/$TCPDUMP_FILE" "$full_save_filepath/$TCPDUMP_FILE" >/dev/null 2>&1 || {
            err "Failed to copy $DEBUG_NAMESPACE/$DEBUG_POD:/host/var/tmp/$TCPDUMP_FILE ./$TCPDUMP_FILE"
            return 1
        }
        info "Dump file copied to ./$TCPDUMP_FILE"
        return 0
    fi
}

run_debug_cmd() {
    local CMD DONE

    DONE=false
    while [ "$DONE" != true ]; do
        prompt "Enter command to run: "
        read -r CMD </dev/stdin
        [[ "$CMD" = *iptables* ]] && CMD="/usr/sbin/${CMD}"
        print_msg "oc-debug: Running oc debug command" \
            "nsenter $NSENTER_PARAMS -- chroot /host $CMD"
        oc exec "$DEBUG_POD" -n "$DEBUG_NAMESPACE" -- /bin/bash -c "nsenter $NSENTER_PARAMS -- chroot /host $CMD" || {
            err "oc-debug: Failed running command '$CMD'!"
            return 1
        }
        if confirm "oc-debug: Run another command?"; then
            info "Maintaining debug pod online..."
        else
            info "Exiting debug session..."
            DONE=true
        fi
    done
}

while [ "$#" -gt 0 ]; do
    case "${1%=*}" in  # This extracts the key part before any '=' character
      --context)
          CONTEXT="$2"
          shift
          ;;
      --tcp-dump|-t)
          TCPDUMP=true
          COMMAND=false
          shift
          ;;
      --command|-c)
          COMMAND=true
          TCPDUMP=false
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
done

# Main function
main() {
    clear
    delete_existing_debug_pods || {
        err "Failed to run initial pod cleanup"
        return 1
    }
    clear
    select_node || {
        err "Failed to select OpenShift node for debugging"
        return 1
    }
    clear
    select_or_create_debug_pod || {
        err "Failed to select/create debug pod for OpenShift node"
        return 1
    }
    clear
    set_nsenter_params || {
        err "Failed to set nsenter parameters for tcpdump"
        return 1
    }
    clear
    if [ "$COMMAND" = true ]; then
        run_debug_cmd || {
            err "Failed running oc debug pod command"
            return 1
        }
    fi
    if [ "$TCPDUMP" = true ]; then
        select_interface || {
            err "Failed to select debug pod tcpdump interface"
            return 1
        }
        clear
        run_tcpdump || {
            err "Failed to run tcpdump on debug pod"
            return 1
        }
    fi
    info "Successfully completed tcpdump capture on $SELECTED_NODE for $SELECTED_POD!"
}
banner
# Run the main function
main || {
    err "oc-debug: Failed!"
    exit
}
