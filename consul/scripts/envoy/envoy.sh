#!/usr/bin/env bash

export CONTEXT=dc1

export SERVICE
export SERVICE_NS

export OUTPUT_DIR=envoy
export CLEAR_DUMP_DIR=0

export ALL=0
export LOGS=0
export STATS=0
export CONFIG=0
export CLUSTERS=0
export LISTENERS=0
export RESET_COUNTERS=0

export EXT=json
export FORMAT=json
export LOG_LEVEL=trace

eval "$(cat scripts/logging.sh)"
eval "$(cat scripts/formatting.env)"

# Define the banner function
banner() {
  echo -e "\n${LIGHT_CYAN}${BOLD}Consul K8s on AWS OpenShift | Envoy Sidecar Dumper${RESET}${LIGHT_CYAN}${RESET}"
  echo -e "${DIM}::Envoy Admin API Config Helper Script::${RESET}\n"
  echo -e "  ${DIM}Service: ${RED}'$SERVICE'${RESET} ${DIM}| NS: ${RED}'$SERVICE_NS'${RESET} ${DIM}| Cluster: ${RED}'${CONTEXT}'${RESET}"
}
## Define usage script
usage() {
  echo -e "
  Usage: ${CYAN}$(basename "$0")${RESET} ${MAGENTA}[parameters]${RESET} ${INTENSE_YELLOW}[capture_options]${RESET} ${BLUE}[options]${RESET}

  ${MAGENTA}Parameters:${RESET} ${RED}(Required)${RESET}
    --context:             ${DIM}Kubernetes service cluster context${RESET}
    --service,        -s:  ${DIM}Kubernetes service deployment name where dataplane sidecar is running${RESET}
    --namespace, -ns, -n:  ${DIM}Kubernetes service namespace of service deployment${RESET}

  ${INTENSE_YELLOW}Capture Options:${RESET}
    --all, -a:             ${DIM}Collect Envoy logs, configuration, clusters, and listeners${RESET}
    --logs:                ${DIM}Collect Envoy logs at specified logging level (--log-level)${RESET}
    --stats:               ${DIM}Collect Envoy stats${RESET}
    --config:              ${DIM}Collect Envoy configuration and EDS configuration${RESET}
    --clusters:            ${DIM}Collect Envoy clusters and EDS clusters${RESET}
    --listeners:           ${DIM}Collect Envoy listeners${RESET}

  ${BLUE}Options:${RESET}
    --help:                ${DIM}Show this menu${RESET}
    --format:              ${DIM}Configure output format (Options: ${LIGHT_BLUE}text${RESET}${DIM}/${LIGHT_BLUE}json${RESET}${DIM}) for cluster and listener output${RESET}   (Default: $FORMAT)
    --out-dir:             ${DIM}Output filepath for Envoy configuration/logging dumps${RESET}                          (Default: $OUTPUT_DIR/)
    --log-level:           ${DIM}Set Envoy logging level (Options: ${LIGHT_BLUE}trace${RESET}${DIM}|${LIGHT_BLUE}debug${RESET}${DIM}|${LIGHT_BLUE}info${RESET}${DIM}|${LIGHT_BLUE}warning${RESET}${DIM}|${LIGHT_BLUE}error${RESET}${DIM}|${LIGHT_BLUE}critical${RESET}${DIM}|${LIGHT_BLUE}off${RESET}${DIM})${RESET} (Default: $LOG_LEVEL)
    --reset-counters,  -r: ${DIM}Reset Envoy sidecar outlier detection backoff counters${RESET}
    --reset-dump-dir, -rd: ${DIM}Reset Envoy dump directory (delete contents)${RESET}
"
  exit "$1"
}

clear_dump_directory() {
  local dump path

  for dump in \
      clusters \
      config_dumps \
      listeners \
      logs \
      stats \
      tcpdump \
      ; do
      path="$OUTPUT_DIR"/"$dump"
      info "envoy-dump: Deleting contents for $path"
      rm -rf "${path:?}"/* >/dev/null 2>&1 || {
          err "envoy-dump: Failed to delete contents of $path!"
          return 1
      }
  done
}

configure_dump_directory() {
  local dump
  local path
  
  [ "$CONTEXT" = "$CLUSTER2_CONTEXT" ] && CONTEXT=dc2
  for dump in \
      clusters/"$CONTEXT" \
      config_dumps/"$CONTEXT" \
      listeners/"$CONTEXT" \
      logs/"$CONTEXT" \
      stats/"$CONTEXT" \
      tcpdump/"$CONTEXT" \
      ; do

    test -d "$OUTPUT_DIR" || {
        info "envoy-dump: Creating Envoy dump directory $OUTPUT_DIR"
        mkdir -p "$OUTPUT_DIR" >/dev/null 2>&1 || {
            err "envoy-dump: Error creating $OUTPUT_DIR root directory!"
            return 1
        }
    }

    path="$OUTPUT_DIR"/"$dump"
    test -d "$path" || {
        info "envoy-dump: Creating Envoy dump directory $path"
        mkdir -p "$path" >/dev/null 2>&1 || {
            err "envoy-dump: Error creating $path directory!"
            return 1
        }
    }
  done
  [ "$CONTEXT" = dc2 ] && CONTEXT="$CLUSTER2_CONTEXT"
  return 0
}

set_log_level() {
    local service="$1"
    local namespace="$2"
    local context="$3"
    local pod selector_key

    info "envoy-dump: Configuring Envoy log-level for $service sidecar proxy to '$LOG_LEVEL'"
    selector_key=app
    [[ "$service" =~ .*-gateway.* ]] && selector_key=component
    # Iterate over each pod matching the service deployment
    for pod in $(openshift/oc get pods --namespace "$namespace" --context "$context" --selector="$selector_key=$service" -o jsonpath='{.items[*].metadata.name}'); do
        openshift/oc exec -it --namespace "$namespace" --context "$context" "pod/$pod" -c "${service#consul-}" -- curl -s -XPOST "$ADMIN_API"/"$LOG_LEVEL_ENDPOINT" 1>/dev/null || {
            return 1
        }
    done
}


reset_outlier_detection() {
    local service="$1"
    local namespace="$2"
    local context="$3"
    local pod selector_key

    info "envoy-dump: Resetting host ejection outlier detection counters for $namespace/$service sidecar proxy"
    selector_key=app
    [[ "$service" =~ .*-gateway.* ]] && selector_key=component
    # Iterate over each pod matching the service deployment
    for pod in $(openshift/oc get pods --namespace "$namespace" --context "$context" --selector="$selector_key=$service" -o jsonpath='{.items[*].metadata.name}'); do
        openshift/oc exec -it --namespace "$namespace" --context "$context" "pod/$pod" -c "${service#consul-}" -- curl -s -XPOST "$ADMIN_API"/"$OUTLIER_COUNTER_RESET_ENDPOINT" 1>/dev/null || {
            return 1
        }
    done
}


envoy_config_dump() {
    local service="$1"
    local namespace="$2"
    local context="$3"
    local config_dump pod selector_key datacenter

    info "envoy-dump: Retrieving Envoy configuration dump (EDS) for $service sidecar proxy"
    selector_key=app
    [[ "$service" =~ .*-gateway.* ]] && selector_key=component
    datacenter=dc1
    [ "$CONTEXT" = "$CLUSTER2_CONTEXT" ] && datacenter=dc2
    # Iterate over each pod matching the service deployment
    for pod in $(openshift/oc get pods --namespace "$namespace" --context "$context" --selector="$selector_key=$service" -o jsonpath='{.items[*].metadata.name}'); do
        config_dump="$(openshift/oc exec -it --namespace "$namespace" --context "$context" "pod/$pod" -c "${service#consul-}" -- curl -s "$ADMIN_API"/"$CONFIG_DUMP_ENDPOINT")"
        echo "$config_dump" | jq . >"$OUTPUT_DIR"/config_dumps/"$datacenter"/"$pod"-sidecar.json
    done
}


envoy_clusters_dump() {
    local service="$1"
    local namespace="$2"
    local context="$3"
    local cluster_dump pod selector_key datacenter

    info "envoy-dump: Retrieving Envoy clusters dump for $service sidecar proxy"
    selector_key=app
    [[ "$service" =~ .*-gateway.* ]] && selector_key=component
    datacenter=dc1
    [ "$CONTEXT" = "$CLUSTER2_CONTEXT" ] && datacenter=dc2
    # Iterate over each pod matching the service deployment
    for pod in $(openshift/oc get pods --namespace "$namespace" --context "$context" --selector="$selector_key=$service" -o jsonpath='{.items[*].metadata.name}'); do
        cluster_dump="$(openshift/oc exec -it --namespace "$namespace" --context "$context" "pod/$pod" -c "${service#consul-}" -- curl -s "$ADMIN_API"/"$CLUSTER_ENDPOINT")"
        [ "$FORMAT" = json ] && \
            echo "$cluster_dump" | jq . >"$OUTPUT_DIR"/clusters/"$datacenter"/"$pod"-clusters."$EXT" && \
            continue
        echo "$cluster_dump" >"$OUTPUT_DIR"/clusters/"$datacenter"/"$pod"-clusters."$EXT"
    done
}


envoy_listeners_dump() {
    local service="$1"
    local namespace="$2"
    local context="$3"
    local listener_dump pod selector_key datacenter

    info "envoy-dump: Retrieving Envoy clusters dump for $service sidecar proxy"
    selector_key=app
    [[ "$service" =~ .*-gateway.* ]] && selector_key=component
    datacenter=dc1
    [ "$CONTEXT" = "$CLUSTER2_CONTEXT" ] && datacenter=dc2
    # Iterate over each pod matching the service deployment
    for pod in $(openshift/oc get pods --namespace "$namespace" --context "$context" --selector="$selector_key=$service" -o jsonpath='{.items[*].metadata.name}'); do
        listener_dump="$(openshift/oc exec -it --namespace "$namespace" --context "$context" "pod/$pod" -c "${service#consul-}" -- curl -s "$ADMIN_API"/"$LISTENER_ENDPOINT")"
        [ "$FORMAT" = json ] && \
            echo "$listener_dump" | jq . >"$OUTPUT_DIR"/listeners/"$datacenter"/"$pod"-listeners."$EXT" && \
            continue
        echo "$listener_dump" >"$OUTPUT_DIR"/listeners/"$datacenter"/"$pod"-listeners."$EXT"
    done
}


envoy_log_dump() {
    local service="$1"
    local namespace="$2"
    local context="$3"
    local log_dump pod selector_key datacenter

    info "envoy-dump: Retrieving Envoy log dump for $service sidecar proxy"
    selector_key=app
    [[ "$service" =~ .*-gateway.* ]] && selector_key=component
    datacenter=dc1
    [ "$CONTEXT" = "$CLUSTER2_CONTEXT" ] && datacenter=dc2
    # Iterate over each pod matching the service deployment
    for pod in $(openshift/oc get pods --namespace "$namespace" --context "$context" --selector="$selector_key=$service" -o jsonpath='{.items[*].metadata.name}'); do
        local container=consul-dataplane
        [[ "$service" = *gateway* ]] && container="${service#consul-}"

        log_dump="$(openshift/oc logs --namespace "$namespace" --context "$context" "pod/$pod" -c "$container")"
        echo "$log_dump" >"$OUTPUT_DIR"/logs/"$datacenter"/"$pod"-sidecar.log
    done
}


envoy_stats_dump() {
    local service="$1"
    local namespace="$2"
    local context="$3"
    local stats_dump pod selector_key datacenter

    info "envoy-dump: Retrieving Envoy log dump for $service sidecar proxy"
    selector_key=app
    [[ "$service" =~ .*-gateway.* ]] && selector_key=component
    datacenter=dc1
    [ "$CONTEXT" = "$CLUSTER2_CONTEXT" ] && datacenter=dc2
    # Iterate over each pod matching the service deployment
    for pod in $(openshift/oc get pods --namespace "$namespace" --context "$context" --selector="$selector_key=$service" -o jsonpath='{.items[*].metadata.name}'); do
        stats_dump="$(openshift/oc exec -it --namespace "$namespace" --context "$context" "pod/$pod" -c "${service#consul-}" -- curl -s "$ADMIN_API"/"$STATS_ENDPOINT")"
        [ "$FORMAT" = json ] && \
            echo "$stats_dump" | jq . >"$OUTPUT_DIR"/stats/"$datacenter"/"$pod"-sidecar."$EXT" && \
            continue
        echo "$stats_dump" >"$OUTPUT_DIR"/stats/"$datacenter"/"$pod"-sidecar."$EXT"
    done
}


# //////////////////////// Parameter Handling \\\\\\\\\\\\\\\\\\\\\\\\\\\\ #
# //////////////////////////////////////////////////////////////////////// #
while [ "$#" -gt 0 ]; do
    case "${1%=*}" in  # This extracts the key part before any '=' character
      -s|--service)
          SERVICE=$(extract_value "$1" "$2")
          [[ "$1" == *"="* ]] || shift  # Only shift if it wasn't an '=' included parameter
          shift
          ;;
      -ns|-n|--namespace)
          SERVICE_NS=$(extract_value "$1" "$2")
          [[ "$1" == *"="* ]] || shift
          shift
          ;;
      -a|--all)
          ALL=1
          shift
          ;;
      -l|--logs)
          LOGS=1
          shift
          ;;
      --stats)
          STATS=1
          shift
          ;;
      --config)
          CONFIG=1
          shift
          ;;
      --clusters)
          CLUSTERS=1
          shift
          ;;
      --listeners)
          LISTENERS=1
          shift
          ;;
      -r|--reset-counters)
          RESET_COUNTERS=1
          shift
          ;;
      -rd|--reset-dump-dir)
          CLEAR_DUMP_DIR=1
          shift
          ;;
      --context)
          CONTEXT=$(extract_value "$1" "$2")
          [[ "$1" == *"="* ]] || shift
          [[ "$CONTEXT" =~ dc1|dc2 ]] || {
            err "envoy-dump: '--context' must be one of 'dc1' or 'dc2'"
            exit
          }
          shift
          ;;
      --format)
          FORMAT=$(extract_value "$1" "$2")
          [[ "$1" == *"="* ]] || shift
          [[ "$FORMAT" =~ txt|text|json ]] || {
            err "envoy-dump: '--format' must be one of 'text', 'txt', or 'json'"
            exit
          }
          shift
          ;;
      --out-dir)
          OUTPUT_DIR=$(extract_value "$1" "$2")
          configure_dump_directory || {
            err "envoy-dump: Failed to create Envoy dump directories at $OUTPUT_DIR!"
            exit
          }
          [[ "$1" == *"="* ]] || shift
          shift
          ;;
      --log-level)
          LOG_LEVEL=$(extract_value "$1" "$2")
          [[ "$LOG_LEVEL" =~ trace|debug|info|warning|error|critical|off ]] || {
            err "envoy-dump: '--log-level' must be one of 'trace', 'debug', 'info', 'warning', 'error', 'critical', or 'off'"
            exit
          }
          [[ "$1" == *"="* ]] || shift
          shift
          ;;
      -h|-\?|--help)
          banner
          usage 0
          ;;
      *)
          warn "Unknown parameter: $1"
          usage 1
          ;;
    esac
done

# ////////////////// Envoy API Endpoint Configs \\\\\\\\\\\\\\\\\\\\\ #
# /////////////////////////////////////////////////////////////////// #
[ "$FORMAT" = txt ] && FORMAT=text
[ "$FORMAT" = json ] || EXT=txt # Set dump extension according to FORMAT
[ "$CONTEXT" = dc2 ] && CONTEXT="$CLUSTER2_CONTEXT"
export ADMIN_API='0:19000'
export STATS_ENDPOINT="stats?format=$FORMAT"
export CLUSTER_ENDPOINT="clusters?format=$FORMAT"
export LISTENER_ENDPOINT="listeners?format=$FORMAT"
export LOG_LEVEL_ENDPOINT="logging?level=$LOG_LEVEL"
export CONFIG_DUMP_ENDPOINT='config_dump?include_eds'
export OUTLIER_COUNTER_RESET_ENDPOINT='reset_counters'
# ///////////////////////////// Main \\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\ #
# ///////////////////////////////////////////////////////////////////// #
banner
info "envoy-dump: Starting Envoy config dumper script execution"
if [[ "$CLEAR_DUMP_DIR" == "1" ]]; then
    clear_dump_directory || {
        err "envoy-dump: Failed to reset Envoy dump directories at $OUTPUT_DIR!"
        exit
    }
    info "envoy-dump: Done!"
    exit
fi
configure_dump_directory || {
    err "envoy-dump: Failed to create Envoy dump directories at $OUTPUT_DIR!"
    exit
}

main() {

    if [ "$LOGS" = 0 ] && [ "$STATS" = 0 ] && [ "$CONFIG" = 0 ] && [ "$CLUSTERS" = 0 ] && [ "$LISTENERS" = 0 ] && [ "$RESET_COUNTERS" = 0 ]; then
        ALL=1
    fi
    if [[ "$ALL" == "1" ]]; then
        LOGS=1
        STATS=1
        CONFIG=1
        CLUSTERS=1
        LISTENERS=1
        info "envoy-dump: Executing all actions for $SERVICE in $SERVICE_NS namespace (Log Level: $LOG_LEVEL|Format: $FORMAT)."
    fi

    if [[ "$RESET_COUNTERS" == "1" ]]; then
        info "envoy-dump: Resetting outlier detection counters for $SERVICE in $SERVICE_NS namespace."
        reset_outlier_detection "$SERVICE" "$SERVICE_NS" "$CONTEXT" || {
            err "envoy-dump: Failed to reset Envoy outlier detection stats counters dump!"
            exit
        }
        info "envoy-dump: Envoy outlier detection reset successfully!"
        exit
    fi

    if [[ "$LOGS" == "1" ]]; then
        info "envoy-dump: Configuring log level for $SERVICE in $SERVICE_NS (Log Level: $LOG_LEVEL)."
        set_log_level "$SERVICE" "$SERVICE_NS" "$CONTEXT" || {
            err "envoy-dump: Failed to set Envoy logging-level!"
            exit
        }
        info "envoy-dump: Dumping logs for $SERVICE in $SERVICE_NS namespace (Log Level: $LOG_LEVEL)."
        envoy_log_dump "$SERVICE" "$SERVICE_NS" "$CONTEXT" || {
            err "envoy-dump: Failed to retrieve Envoy log dump!"
            exit
        }
    fi

    if [[ "$STATS" == "1" ]]; then
        info "envoy-dump: Dumping stats for $SERVICE in $SERVICE_NS namespace (Format: $FORMAT)."
        envoy_stats_dump "$SERVICE" "$SERVICE_NS" "$CONTEXT" || {
            err "envoy-dump: Failed to retrieve Envoy stats dump!"
            exit
        }
    fi

    if [[ "$CONFIG" == "1" ]]; then
        info "envoy-dump: Dumping Envoy config for $SERVICE in $SERVICE_NS namespace."
        envoy_config_dump "$SERVICE" "$SERVICE_NS" "$CONTEXT" || {
            err "envoy-dump: Failed to retrieve Envoy config dump!"
            exit
        }
    fi

    if [[ "$CLUSTERS" == "1" ]]; then
        info "envoy-dump: Dumping clusters for $SERVICE in $SERVICE_NS namespace (Format: $FORMAT)."
        envoy_clusters_dump "$SERVICE" "$SERVICE_NS" "$CONTEXT" || {
            err "envoy-dump: Failed to retrieve Envoy clusters dump!"
            exit
        }
    fi

    if [[ "$LISTENERS" == "1" ]]; then
        info "envoy-dump: Dumping listeners for $SERVICE in $SERVICE_NS namespace (Format: $FORMAT)."
        envoy_listeners_dump "$SERVICE" "$SERVICE_NS" "$CONTEXT" || {
            err "envoy-dump: Failed to retrieve Envoy listeners dump!"
            exit
        }
    fi
}
main
info "envoy-dump: Dump collection completed successfully. Review files *==> $OUTPUT_DIR/clusters|listeners|config_dumps|logs"
