#!/usr/bin/env bash

export CONTEXT=dc1

eval "$(cat scripts/logging.sh)"
eval "$(cat scripts/formatting.env)"

# /////////////////// User Params \\\\\\\\\\\\\\\\\\ #
# ////////////////////////////////////////////////// #
export SERVICE
export STAT_NAME
export STAT_VALUE
export LOG_STRING_MATCH

export LOGS=0
export STATS=0
export CONFIG=0
export CLUSTERS=0
export LISTENERS=0
export NONZERO_STATS=0

export TYPES='.configs[]."@type"'
# /////////////////// Envoy Config Dumps JQ Queries \\\\\\\\\\\\\\\\\\ #
# //////////////////////////////////////////////////////////////////// #
export BOOTSTRAPPED_CLUSTERS_QUERY='.configs[] | select(. != null) | .bootstrap | select(. != null) | .static_resources.clusters'
## Clusters
export STATIC_CLUSTERS_QUERY='.configs[] | select(. != null) | .static_clusters | select(. != null)'
export DYNAMIC_CLUSTERS_QUERY='.configs[] | select(. != null) | .dynamic_active_clusters | select(. != null)'
## Endpoints
export STATIC_ENDPOINTS_QUERY='.configs[] | select(. != null) | .static_endpoint_configs | select(. != null)'
export DYNAMIC_ENDPOINTS_QUERY='.configs[] | select(. != null) | .dynamic_endpoint_configs | select(. != null)'
## Listeners
export PUBLIC_LISTENERS_QUERY='.configs[] | select(. != null) | .dynamic_listeners | select(. != null) | .[] | select(.name|match("public_listener.*|default.*"))'
export PUBLIC_LISTENER_FILTER_CHAINS_QUERY='.configs[] | select(. != null) | .dynamic_listeners | select(. != null) | .[] | select(.name|match("public_listener.*|default.*|http.*|tcp.*")) | .active_state.listener.filter_chains'
export OUTBOUND_LISTENERS_QUERY='.configs[] | select(. != null) | .dynamic_listeners | select(. != null) | .[] | select(.name|match("outbound_listener.*|default.*"))'
export OUTBOUND_LISTENER_FILTER_CHAINS_QUERY='.configs[] | select(. != null) | .dynamic_listeners | select(. != null) | map(select(.name=="outbound_listener:127.0.0.1:15001"))[] | .active_state.listener.filter_chains[]'

export BOOTSTRAPPED_CLUSTERS=0
export STATIC_CLUSTERS=0
export DYNAMIC_CLUSTERS=0
export STATIC_ENDPOINTS=0
export DYNAMIC_ENDPOINTS=0
export PUBLIC_LISTENERS=0
export PUBLIC_LISTENER_FILTER_CHAINS=0
export OUTBOUND_LISTENERS=0
export OUTBOUND_LISTENER_FILTER_CHAINS=0

export CLUSTER_NAME_FILTER
export CLUSTER_IP_ADDR_FILTER
export CLUSTER_IP_PORT_FILTER
export CLUSTER_HEALTH_STATUS

# /////////////////// Envoy Stats JQ Queries \\\\\\\\\\\\\\\\\\ #
# ///////////////////////////////////////////////////////////// #
export NONZERO_STATS_QUERY='.stats[] | select(.value != null and .value != 0 and .value != "")'

# /////////////////// Envoy Common Dump Dir \\\\\\\\\\\\\\\\\\ #
# //////////////////////////////////////////////////////////// #
export ENVOY_DUMP_DIR=envoy

# /////////////////// Envoy Dump Formatting \\\\\\\\\\\\\\\\\\ #
# //////////////////////////////////////////////////////////// #
export EXT=json
export FORMAT=json
export LOG_LEVEL=error
[ "$FORMAT" = text ] && FORMAT=txt
[ "$FORMAT" = json ] || EXT=txt # Set dump extension according to FORMAT

# Define the banner function
banner() {
  echo -e "\n${LIGHT_CYAN}${BOLD}Envoy Configuration and Stats Dump Reader${RESET}${LIGHT_CYAN}${RESET}"
  echo -e "${DIM}::Envoy Dump Parser Script:: Service:${RESET} ${RED}$( [ -n "${SERVICE}" ] && echo -e "${SERVICE}" || echo "-" )${RESET}"
}
## Define usage script
usage() {
  echo -e "
  Usage: ${CYAN}$(basename "$0")${RESET} ${MAGENTA}[subcommand]${RESET} ${INTENSE_YELLOW}[parameters]${RESET} ${BLUE}[options]${RESET}

  ${MAGENTA}Subcommands:${RESET} ${RED}(Required)${RESET}
    logs:                     ${DIM}Parse Envoy logs at specified logging level${RESET}     (Use with '--log-level'; Default: $LOG_LEVEL)
    stats:                    ${DIM}Parse Envoy stats${RESET}                               (0:19000/stats?format=$FORMAT)
    config:                   ${DIM}Parse Envoy configuration and EDS configuration${RESET} (0:19000/config_dump?include_eds)
    clusters:                 ${DIM}Parse Envoy clusters and EDS clusters${RESET}           (0:19000/clusters?format=$FORMAT)
    listeners:                ${DIM}Parse Envoy listeners${RESET}                           (0:19000/listeners?format=$FORMAT)

  ${INTENSE_YELLOW}Parameters:${RESET} ${RED}(Required)${RESET}
    --context:                ${DIM}Kubernetes service cluster context${RESET}
    --service, -s:            ${DIM}Name of service dump configuration to parse.${RESET}

  ${BLUE}Global Options:${RESET}
    --help:                   ${DIM}Show this menu${RESET}
    --format:                 ${DIM}Configure output format (Options: ${LIGHT_BLUE}text${RESET}${DIM}/${LIGHT_BLUE}json${RESET}${DIM}) for cluster and listener output${RESET}   (Default: $FORMAT)
    --dump-dir:               ${DIM}Root Envoy dump directory filepath for Envoy configuration/logging dumps${RESET}       (Default: $ENVOY_DUMP_DIR/)

  ${INTENSE_YELLOW}Envoy Log Options:${RESET}

    ${DIM}Combine these flags with${RESET} ${MAGENTA}logs${RESET} ${DIM}subcommand to filter output results${RESET}

    --log-level:              ${DIM}Set Envoy logging level (Options: ${LIGHT_BLUE}trace${RESET}${DIM}|${LIGHT_BLUE}debug${RESET}${DIM}|${LIGHT_BLUE}info${RESET}${DIM}|${LIGHT_BLUE}warning${RESET}${DIM}|${LIGHT_BLUE}error${RESET}${DIM}|${LIGHT_BLUE}critical${RESET}${DIM}|${LIGHT_BLUE}off${RESET}${DIM})${RESET} (Default: $LOG_LEVEL)
    --log-string:             ${DIM}Parse for additional string to match along with log-level${RESET}

  ${LIGHT_BLUE}Envoy Config Dump Options:${RESET}

    ${DIM}Combine these flags with${RESET} ${MAGENTA}config${RESET} ${DIM}subcommand to reduce output to filter results${RESET}

    --bootstrapped-clusters:  ${DIM}Parse statically bootstrapped clusters.${RESET}
    --eds-clusters:           ${DIM}Parse EDS populated clusters${RESET}
    --static-clusters:        ${DIM}Parse for statically configured clusters${RESET}
    --eds-endpoints:          ${DIM}Parse for dynamically populated EDS endpoints${RESET}
    --static-endpoints:       ${DIM}Parse for statically defined endpoints${RESET}
    --public-listeners:       ${DIM}Parse for configured inbound public listeners${RESET}
    --outbound-listeners:     ${DIM}Parse for configured outbound listeners${RESET}
    --public-filter-chains:   ${DIM}Parse for public inbound listener filter chains${RESET}
    --outbound-filter-chains: ${DIM}Parse for outbound listener filter chains${RESET}

  ${LIGHT_MAGENTA}Envoy Clusters Options:${RESET}

    ${DIM}Combine these flags with${RESET} ${MAGENTA}clusters${RESET} ${DIM}subcommand to filter output results${RESET}

    --cluster-name,            -cn: ${DIM}Parse by cluster name${RESET}
    --cluster-ip-port,      -cport: ${DIM}Parse by cluster ip port number${RESET}
    --cluster-ip-address,     -cip: ${DIM}Parse by cluster ip address${RESET}
    --cluster-eds-health, -chealth: ${DIM}Parse by cluster EDS health${RESET} (Options: ${INTENSE_YELLOW}HEALTHY${RESET}, ${INTENSE_YELLOW}UNHEALTHY${RESET})

  ${LIGHT_GREEN}Envoy Stats Options:${RESET}

    ${DIM}Combine these flags with${RESET} ${MAGENTA}stats${RESET} ${DIM}subcommand to further parse output${RESET}

    --stat-name:              ${DIM}Parse stats based on regex matched name value${RESET} (Optional: Combine with '--non-zero' or '--stat-value')
    --stat-value:             ${DIM}Parse stats based on regex matched value${RESET}
    --non-zero:               ${DIM}Parse stats for all non-zero/non-null based values${RESET}
"
  exit "$1"
}
log_usage() {
  echo -e "
  Description:
      Parse Envoy log capture by log-level and/or string match

  Usage: ${CYAN}$(basename "$0")${RESET} ${MAGENTA}logs${RESET} ${INTENSE_YELLOW}[parameters]${RESET} ${BLUE}[options]${RESET}

  ${INTENSE_YELLOW}Parameters:${RESET} ${RED}(Required)${RESET}
    --service, -s:            ${DIM}Name of service dump configuration to parse.${RESET}

  ${BLUE}Global Options:${RESET}
    --help:                   ${DIM}Show this menu${RESET}
    --format:                 ${DIM}Configure output format (Options: ${LIGHT_BLUE}text${RESET}${DIM}/${LIGHT_BLUE}json${RESET}${DIM}) for cluster and listener output${RESET}   (Default: $FORMAT)
    --dump-dir:               ${DIM}Root Envoy dump directory filepath for Envoy configuration/logging dumps${RESET}       (Default: $ENVOY_DUMP_DIR/)

  ${INTENSE_YELLOW}Envoy Log Options:${RESET}

    ${DIM}Combine these flags with${RESET} ${MAGENTA}logs${RESET} ${DIM}subcommand to filter output results${RESET}

    --log-level:              ${DIM}Set Envoy logging level (Options: ${LIGHT_BLUE}trace${RESET}${DIM}|${LIGHT_BLUE}debug${RESET}${DIM}|${LIGHT_BLUE}info${RESET}${DIM}|${LIGHT_BLUE}warning${RESET}${DIM}|${LIGHT_BLUE}error${RESET}${DIM}|${LIGHT_BLUE}critical${RESET}${DIM}|${LIGHT_BLUE}off${RESET}${DIM})${RESET} (Default: $LOG_LEVEL)
    --log-string:             ${DIM}Parse for additional string to match along with log-level${RESET}
"
  exit "$1"
}
stats_usage() {
  echo -e "
  Description:
      Parse Envoy stats dump by name and/or value.

  Usage: ${CYAN}$(basename "$0")${RESET} ${MAGENTA}stats${RESET} ${INTENSE_YELLOW}[parameters]${RESET} ${BLUE}[options]${RESET}

  ${MAGENTA}Subcommands:${RESET} ${RED}(Required)${RESET}
    stats:                    ${DIM}Parse Envoy stats${RESET}                               (0:19000/stats?format=$FORMAT)

  ${INTENSE_YELLOW}Parameters:${RESET} ${RED}(Required)${RESET}
    --service, -s:            ${DIM}Name of service dump configuration to parse.${RESET}

  ${BLUE}Global Options:${RESET}
    --help:                   ${DIM}Show this menu${RESET}
    --format:                 ${DIM}Configure output format (Options: ${LIGHT_BLUE}text${RESET}${DIM}/${LIGHT_BLUE}json${RESET}${DIM}) for cluster and listener output${RESET}   (Default: $FORMAT)
    --dump-dir:               ${DIM}Root Envoy dump directory filepath for Envoy configuration/logging dumps${RESET}       (Default: $ENVOY_DUMP_DIR/)

  ${LIGHT_GREEN}Envoy Stats Options:${RESET}

    ${DIM}Combine these flags with${RESET} ${MAGENTA}stats${RESET} ${DIM}subcommand to further parse output${RESET}

    --stat-name:              ${DIM}Parse stats based on regex matched name value${RESET} (Optional: Combine with '--non-zero' or '--stat-value')
    --stat-value:             ${DIM}Parse stats based on regex matched value${RESET}
    --non-zero:               ${DIM}Parse stats for all non-zero/non-null based values${RESET}
"
  exit "$1"
}
clusters_usage() {
  echo -e "
  Description:
      Parse Envoy clusters dump and filter by name, ip addressing/port, and health status.

  Usage: ${CYAN}$(basename "$0")${RESET} ${MAGENTA}clusters${RESET} ${INTENSE_YELLOW}[parameters]${RESET} ${BLUE}[options]${RESET}

  ${MAGENTA}Subcommands:${RESET} ${RED}(Required)${RESET}
    clusters:                 ${DIM}Parse Envoy clusters and EDS clusters${RESET}           (0:19000/clusters?format=$FORMAT)

  ${INTENSE_YELLOW}Parameters:${RESET} ${RED}(Required)${RESET}
    --service, -s:            ${DIM}Name of service dump configuration to parse.${RESET}

  ${BLUE}Global Options:${RESET}
    --help:                   ${DIM}Show this menu${RESET}
    --format:                 ${DIM}Configure output format (Options: ${LIGHT_BLUE}text${RESET}${DIM}/${LIGHT_BLUE}json${RESET}${DIM}) for cluster and listener output${RESET}   (Default: $FORMAT)
    --dump-dir:               ${DIM}Root Envoy dump directory filepath for Envoy configuration/logging dumps${RESET}       (Default: $ENVOY_DUMP_DIR/)

  ${LIGHT_MAGENTA}Envoy Clusters Options:${RESET}

    ${DIM}Combine these flags with${RESET} ${MAGENTA}clusters${RESET} ${DIM}subcommand to filter output results${RESET}

    --cluster-name,            -cn: ${DIM}Parse by cluster name${RESET}
    --cluster-ip-port,      -cport: ${DIM}Parse by cluster ip port number${RESET}
    --cluster-ip-address,     -cip: ${DIM}Parse by cluster ip address${RESET}
    --cluster-eds-health, -chealth: ${DIM}Parse by cluster EDS health${RESET} (Options: ${INTENSE_YELLOW}HEALTHY${RESET}, ${INTENSE_YELLOW}UNHEALTHY${RESET})
"
  exit "$1"
}
config_dump_usage() {
  echo -e "
  Description:
      Parse Envoy configuration dump (EDS included) for various envoy related components:
        - Bootstrapped Clusters
        - Static/EDS Clusters
        - Listeners (inbound/outbound)
        - Listener Filter Chains
        - Static/EDS Endpoints

  Usage: ${CYAN}$(basename "$0")${RESET} ${MAGENTA}config${RESET} ${INTENSE_YELLOW}[parameters]${RESET} ${BLUE}[options]${RESET}

  ${INTENSE_YELLOW}Parameters:${RESET} ${RED}(Required)${RESET}
    --service, -s:            ${DIM}Name of service dump configuration to parse.${RESET}

  ${BLUE}Global Options:${RESET}
    --help:                   ${DIM}Show this menu${RESET}
    --format:                 ${DIM}Configure output format (Options: ${LIGHT_BLUE}text${RESET}${DIM}/${LIGHT_BLUE}json${RESET}${DIM}) for cluster and listener output${RESET}   (Default: $FORMAT)
    --dump-dir:               ${DIM}Root Envoy dump directory filepath for Envoy configuration/logging dumps${RESET}       (Default: $ENVOY_DUMP_DIR/)

  ${LIGHT_BLUE}Envoy Config Dump Options:${RESET}

    ${DIM}Combine these flags with${RESET} ${MAGENTA}config${RESET} ${DIM}subcommand to reduce output to filter results${RESET}

    --bootstrapped-clusters:  ${DIM}Parse statically bootstrapped clusters.${RESET}
    --eds-clusters:           ${DIM}Parse EDS populated clusters${RESET}
    --static-clusters:        ${DIM}Parse for statically configured clusters${RESET}
    --eds-endpoints:          ${DIM}Parse for dynamically populated EDS endpoints${RESET}
    --static-endpoints:       ${DIM}Parse for statically defined endpoints${RESET}
    --public-listeners:       ${DIM}Parse for configured inbound public listeners${RESET}
    --outbound-listeners:     ${DIM}Parse for configured outbound listeners${RESET}
    --public-filter-chains:   ${DIM}Parse for public inbound listener filter chains${RESET}
    --outbound-filter-chains: ${DIM}Parse for outbound listener filter chains${RESET}
"
  exit "$1"
}
listeners_usage() {
  echo -e "
  Description:
      Parse Envoy listeners dump.

  Usage: ${CYAN}$(basename "$0")${RESET} ${MAGENTA}listeners${RESET} ${INTENSE_YELLOW}[parameters]${RESET} ${BLUE}[options]${RESET}

  ${INTENSE_YELLOW}Parameters:${RESET} ${RED}(Required)${RESET}
    --service, -s:            ${DIM}Name of service dump configuration to parse.${RESET}

  ${BLUE}Global Options:${RESET}
    --help:                   ${DIM}Show this menu${RESET}
    --format:                 ${DIM}Configure output format (Options: ${LIGHT_BLUE}text${RESET}${DIM}/${LIGHT_BLUE}json${RESET}${DIM}) for cluster and listener output${RESET}   (Default: $FORMAT)
    --dump-dir:               ${DIM}Root Envoy dump directory filepath for Envoy configuration/logging dumps${RESET}       (Default: $ENVOY_DUMP_DIR/)
"
  exit "$1"
}
# //////////////////////// Help Functions \\\\\\\\\\\\\\\\\\\\\\\\\\\\ #
# //////////////////////////////////////////////////////////////////// #
# Initialize a flag to check for mutually exclusive parameters
mutually_exclusive_set=0
mutually_exclusive() {
      if [[ $mutually_exclusive_set -eq 1 ]]; then
        err "envoy-parse: Envoy option parameter is mutually exclusive!"

        [ "$CONFIG" = 1 ] && print_msg "envoy-parse: Envoy config_dump mutually exclusive params:" \
            "--bootstrapped-clusters" \
            "--eds-clusters" \
            "--static-clusters" \
            "--eds-endpoints" \
            "--static-endpoints" \
            "--public-listeners" \
            "--outbound-listeners" \
            "--public-filter-chains" \
            "--outbound-filter-chains"
        [ "$STAT_VALUE" = 1 ] || [ "$NONZERO_STATS" = 1 ] && print_msg "envoy-parse: Envoy stat mutually exclusive params:" \
            "--non-zero" \
            "--stat-value"
        exit
    fi
    mutually_exclusive_set=1
}

envoy_log_filter() {
    local logfile="$1"
    local loglevel="$2"
    local string_match="$3"
    local result=""
    local result_array

#    if [[ ! -f "$logfile" ]]; then
#        err "envoy-parse: Log file does not exist *==> $logfile"
#        return 1
#    fi

    if [[ -n "$string_match" ]]; then
        result="$(grep -E "\[$loglevel\].*$string_match" $logfile)"
    else
        result="$(grep -E "\[$loglevel\]" $logfile)"
    fi

    [ -z "$result" ] && print_msg_highlight " Log Parse - No log match found: " "$(echo "$loglevel" | tr '[:lower:]' '[:upper:]')" "No [$(echo "$loglevel" | tr '[:lower:]' '[:upper:]')] logs found in $logfile" && return 0
   # Use mapfile to read the result into an array
    mapfile -t result_array < <(printf "%s\n" "$result")
    # Print the array items
    if [[ -n "$string_match" ]]; then
        print_msg_highlight "Log parser - " "$string_match" "${result_array[@]}"
    else
        print_msg_highlight "Log parser - " "$loglevel" "${result_array[@]}"
    fi
}

envoy_stats_filter() {
    local statsfile="$1"
    local statname="$2"
    local statvalue="$3"

    if [ "${statsfile##*.}" = json ]; then
        local jq_filter='.stats[]'

        # Add name filter
        if [ -n "$statname" ]; then
            jq_filter+=" | select(.name | contains(\$name))"
        fi

        # Add value filter
        if [ -n "$statvalue" ]; then
            if [ "$statvalue" != "non_null" ]; then
                jq_filter+=" | select(.value | contains(\$value))"
            else
                jq_filter+=" | select(.value != null and .value != 0 and .value != \"\")"
            fi
        elif [ -z "$statname" ]; then
            jq_filter+=" | select(.value != null and .value != 0 and .value != \"\")"
        fi
        # Final output format
        jq_filter+=' | "\(.name) = \(.value)"'

        # Execute the jq command with the constructed filter for regular stats
        # shellcheck disable=SC2086
        jq -r --arg name "$statname" --arg value "$statvalue" "$jq_filter" $statsfile || {
            err "envoy-parse: Envoy stat parse failed!!" >&2
            return 1
        }
    elif [ "${statsfile##*.}" = txt ]; then
        ## Parse stats by name + value
        if [ -n "$statname" ] && [ -n "$statvalue" ] && [ "$statvalue" != non_null ]; then
              grep -E ".+$statname.+" < "$statsfile" | awk "\$2 == $statvalue" || {
                  err "envoy-parse: Envoy stat parse failed!!"
                  return 1
              }
        ## Parse stats by name + all non-zero values
        elif [ -n "$statname" ] && [ "$statvalue" = non_null ]; then
              grep -E ".+$statname.+" < "$statsfile" | awk '$2 > 0' || {
                  err "envoy-parse: Envoy stat parse failed!!"
                  return 1
              }
        ## Parse stats for all non-zero values
        elif [ -z "$statname" ] && [ "$statvalue" = non_null ]; then
              awk '$2 > 0' <"$statsfile" || {
                  err "envoy-parse: Envoy stat parse failed!!"
                  return 1
              }
        ## Parse stats by name
        elif [ -n "$statname" ] && [ -z "$statvalue" ]; then
              grep -E ".+$statname.+" < "$statsfile" || {
                  err "envoy-parse: Envoy stat parse failed!!"
                  return 1
              }
        ## Parse stats by user provided value
        elif [ -z "$statname" ] && [ -n "$statvalue" ]; then
              awk "\$2 == $statvalue" <"$statsfile" || {
                  err "envoy-parse: Envoy stat parse failed!!"
                  return 1
              }
        ## Dump full stats capture (no filtering)
        else
              cat "$statsfile" || {
                  err "envoy-parse: Envoy stat parse failed!!"
                  return 1
              }
        fi
    fi
}

envoy_clusters_filter() {
    local clusterfile="$1"
    local name_filter="$2"
    local ip_addr_filter="$3"
    local ip_port_filter="$4"
    local cluster_eds_health="$5"
    local result result_array

    if [[ ! -f "$clusterfile" ]]; then
        err "envoy-parse: Clusters file does not exist: $clusterfile"
        return 1
    fi

    if [ "${clusterfile##*.}" = json ]; then
        # Build the jq filter based on the parameters
        local jq_filter='.cluster_statuses[]'
        local filters=()

        # Add name filter
        if [ -n "$name_filter" ]; then
            filters+="Name: $name_filter"
            jq_filter+=" | select(.name | contains(\$name))"
        fi

        # Add IP address filter
        if [ -n "$ip_addr_filter" ]; then
            filters+="IP Address: $ip_addr_filter"
            jq_filter+=" | select(.host_statuses[].address.socket_address.address | contains(\$ip))"
        fi

        # Add IP port filter
        if [ -n "$ip_port_filter" ]; then
            filters+="IP Port: $ip_port_filter"
            jq_filter+=" | select(.host_statuses[].address.socket_address.port_value | tostring | contains(\$ip_port))"
        fi

        # Add EDS health status filter
        if [ -n "$cluster_eds_health" ]; then
            filters+="EDS Health: $cluster_eds_health"
            jq_filter+=" | select(.host_statuses[] | .health_status.eds_health_status | contains(\$health))"
        fi

        # Execute the jq command with the constructed filter
        result="$(jq -r --arg name "$name_filter" --arg ip "$ip_addr_filter" --arg ip_port "$ip_port_filter" --arg health "$cluster_eds_health" "$jq_filter" "$clusterfile")" || {
            return 1
        }
        if [ -n "$result" ]; then
            echo "$result" | jq -r .
        else
            print_msg "envoy-parse: No clusters found with filters:" "${filters[*]}"
        fi
    elif [ "${clusterfile##*.}" = txt ]; then
        if [ -n "$name_filter" ]; then
            result="$(grep -E "$name_filter" "$clusterfile")"
            # Use mapfile to read the result into an array
            mapfile -t result_array < <(printf "%s\n" "$result")
            print_msg_highlight "$SERVICE Cluster Filter - " "$name_filter" "${result_array[@]}"
        elif [ -n "$ip_addr_filter" ]; then
            result="$(grep -E "$ip_addr_filter" "$clusterfile")"
            # Use mapfile to read the result into an array
            mapfile -t result_array < <(printf "%s\n" "$result")
            print_msg_highlight "$SERVICE Cluster Filter - " "$ip_addr_filter" "${result_array[@]}"
        elif [ -n "$ip_port_filter" ]; then
            result="$(grep -E "$ip_port_filter" "$clusterfile")"
            # Use mapfile to read the result into an array
            mapfile -t result_array < <(printf "%s\n" "$result")
            print_msg_highlight "$SERVICE Cluster Filter - " "$ip_port_filter" "${result_array[@]}"
        elif [ -n "$cluster_eds_health" ]; then
            result="$(grep -E "$cluster_eds_health" "$clusterfile")"
            # Use mapfile to read the result into an array
            mapfile -t result_array < <(printf "%s\n" "$result")
            print_msg_highlight "$SERVICE Cluster Filter - " "$cluster_eds_health" "${result_array[@]}"
        else
            result="$(cat "$clusterfile")"
            # Use mapfile to read the result into an array
            mapfile -t result_array < <(printf "%s\n" "$result")
            print_msg "$SERVICE Cluster Filter - " "${result_array[@]}"
        fi

    fi
}

envoy_listeners_filter() {
    local listener_file="$1"
    local result=""
    local result_array

    local public_match='public_listener'
    local outbound_match='outbound_listener'

    local listener_reg=".*$public_match.*|.*$outbound_match.*"

    if [[ ! -f "$listener_file" ]]; then
        err "envoy-parse: Listeners file does not exist: $listener_file"
        return 1
    fi

    if [ "${clusterfile##*.}" = json ]; then
        echo "not implemented...."
    elif [ "${listener_file##*.}" = txt ]; then
        result="$(grep -E "$listener_reg" "$listener_file")"
        mapfile -t result_array < <(printf "%s\n" "$result")
        print_msg_highlight "Listeners parser - " "$listener_reg" "${result_array[@]}"
    fi
}
# //////////////////////// Subcommand Handling \\\\\\\\\\\\\\\\\\\\\\\\\\\\ #
# ///////////////////////////////////////////////////////////////////////// #
[ -n "$1" ] || { banner && usage 0; } ## Handle no params with help menu
subcommand="$1"
shift
case "$subcommand" in
    logs)
        LOGS=1
        ;;
    stats)
        STATS=1
        ;;
    config)
        CONFIG=1
        ;;
    clusters)
        CLUSTERS=1
        ;;
    listeners)
        LISTENERS=1
        ;;
    -h|--help|*)
        usage 1
        ;;
esac
[[ "$subcommand" =~ logs|stats|config|clusters|listeners|-h|--help ]] || {
  err "envoy-parse: Invalid subcommand!"
  banner
  usage 2
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
      --context)
          CONTEXT=$(extract_value "$1" "$2")
          [[ "$1" == *"="* ]] || shift
          [[ "$CONTEXT" =~ dc1|dc2 ]] || {
            err "envoy-parse: '--context' must be one of 'dc1' or 'dc2'"
            exit
          }
          shift
          ;;
      --log-level)
          LOG_LEVEL=$(extract_value "$1" "$2")
          LOG_LEVEL="$(echo "${LOG_LEVEL}" | tr '[:upper:]' '[:lower:]')"
          [[ "$LOG_LEVEL" =~ trace|debug|info|warning|error|critical|off ]] || {
              err "envoy-parse: '--log-level' must be one of 'trace', 'debug', 'info', 'warning', 'error', or 'critical'"
              exit
          }
          [[ "$1" == *"="* ]] || shift
          shift
          ;;
      --log-string)
          LOG_STRING_MATCH=$(extract_value "$1" "$2")
          [[ "$1" == *"="* ]] || shift  # Only shift if it wasn't an '=' included parameter
          shift
          ;;
      --non-zero)
          mutually_exclusive
          NONZERO_STATS=1
          shift
          ;;
      -sn|--stat-name)
          STAT_NAME=$(extract_value "$1" "$2")
          [[ "$1" == *"="* ]] || shift  # Only shift if it wasn't an '=' included parameter
          shift
          ;;
      -sv|--stat-value)
          mutually_exclusive
          STAT_VALUE=$(extract_value "$1" "$2")
          [[ "$1" == *"="* ]] || shift  # Only shift if it wasn't an '=' included parameter
          shift
          ;;
      --bootstrapped-clusters)
          mutually_exclusive
          BOOTSTRAPPED_CLUSTERS=1
          shift
          ;;
      --eds-clusters)
          mutually_exclusive
          DYNAMIC_CLUSTERS=1
          shift
          ;;
      --static-clusters)
          mutually_exclusive
          STATIC_CLUSTERS=1
          shift
          ;;
      --eds-endpoints)
          mutually_exclusive
          DYNAMIC_ENDPOINTS=1
          shift
          ;;
      --static-endpoints)
          mutually_exclusive
          STATIC_ENDPOINTS=1
          shift
          ;;
      --public-listeners)
          mutually_exclusive
          PUBLIC_LISTENERS=1
          shift
          ;;
      --outbound-listeners)
          mutually_exclusive
          OUTBOUND_LISTENERS=1
          shift
          ;;
      --public-filter-chains)
          mutually_exclusive
          PUBLIC_LISTENER_FILTER_CHAINS=1
          shift
          ;;
      --outbound-filter-chains)
          mutually_exclusive
          OUTBOUND_LISTENER_FILTER_CHAINS=1
          shift
          ;;
      -cn|--cluster-name)
          mutually_exclusive
          CLUSTER_NAME_FILTER=$(extract_value "$1" "$2")
          [[ "$1" == *"="* ]] || shift
          shift
          ;;
      -cip|--cluster-ip-address)
          mutually_exclusive
          CLUSTER_IP_ADDR_FILTER=$(extract_value "$1" "$2")
          [[ "$1" == *"="* ]] || shift
          shift
          ;;
      -cport|--cluster-ip-port)
          mutually_exclusive
          CLUSTER_IP_PORT_FILTER=$(extract_value "$1" "$2")
          [[ "$1" == *"="* ]] || shift
          shift
          ;;
      -chealth|--cluster-eds-health)
          mutually_exclusive
          CLUSTER_HEALTH_STATUS=$(extract_value "$1" "$2")
          [[ "$1" == *"="* ]] || shift
          CLUSTER_HEALTH_STATUS="$(echo "${CLUSTER_HEALTH_STATUS}" | tr '[:lower:]' '[:upper:]')"
          [[ "$CLUSTER_HEALTH_STATUS" =~ HEALTHY|UNHEALTHY ]] || {
              err "envoy-parse: '--cluster-eds-health' must be one of 'HEALTHY' or 'UNHEALTHY'"
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
      --dump-dir)
          ENVOY_DUMP_DIR=$(extract_value "$1" "$2")
          [[ "$1" == *"="* ]] || shift
          shift
          ;;
      -h|-\?|--help)
          banner
          case "$subcommand" in
              logs)
                log_usage 0
              ;;
              stats)
                stats_usage 0
              ;;
              config)
                config_dump_usage 0
              ;;
              clusters)
                clusters_usage 0
              ;;
              listeners)
                listeners_usage 0
              ;;
              *)
                usage 0
              ;;
          esac
          ;;
      *)
          warn "Unknown parameter: $1"
          banner
          usage 1
          ;;
    esac
done

## Handle required parameter
[ -z "$SERVICE" ] && err "envoy-parse: '--service' parameter flag is required!" && exit

[ "$FORMAT" = txt ] && FORMAT=text
[ "$FORMAT" = json ] || EXT=txt # Set dump extension according to FORMAT

export ENVOY_LOGS;
# shellcheck disable=SC2125
ENVOY_LOGS=${ENVOY_DUMP_DIR}/logs/${CONTEXT}/${SERVICE}-*-sidecar.log
# shellcheck disable=SC2125
export ENVOY_STATS=${ENVOY_DUMP_DIR}/stats/${CONTEXT}/${SERVICE}-*-sidecar.${EXT}
# shellcheck disable=SC2125
export ENVOY_CLUSTERS=${ENVOY_DUMP_DIR}/clusters/${CONTEXT}/${SERVICE}-*-clusters.${EXT}
# shellcheck disable=SC2125
export ENVOY_LISTENERS=${ENVOY_DUMP_DIR}/listeners/${CONTEXT}/${SERVICE}-*-listeners.${EXT}
# shellcheck disable=SC2125
export ENVOY_CONFIG_DUMP=${ENVOY_DUMP_DIR}/config_dumps/${CONTEXT}/${SERVICE}-*-sidecar.${EXT}

main() {
    if [[ "$LOGS" == 1 ]]; then
        info "envoy-parse: Parsing $LOG_LEVEL entries in Envoy log file '${ENVOY_LOGS}'"
        envoy_log_filter "$ENVOY_LOGS" "$LOG_LEVEL" "$LOG_STRING_MATCH" || {
            err "envoy-parse: Failed to parse Envoy log dump!"
            exit
        }
    fi
    if [[ "$STATS" == 1 ]]; then
        [ "$NONZERO_STATS" = 1 ] && STAT_VALUE=non_null
        envoy_stats_filter "$ENVOY_STATS" "$STAT_NAME" "$STAT_VALUE" || {
            err "envoy-parse: Failed to parse Envoy stats!"
            exit
        }
    fi

    if [[ "$CONFIG" == 1 ]]; then
        # shellcheck disable=SC2194
        case 1 in
            "$BOOTSTRAPPED_CLUSTERS")
                # shellcheck disable=SC2086
                jq -r "$BOOTSTRAPPED_CLUSTERS_QUERY" <$ENVOY_CONFIG_DUMP
                ;;
            "$STATIC_CLUSTERS")
                # shellcheck disable=SC2086
                jq -r "$STATIC_CLUSTERS_QUERY" <$ENVOY_CONFIG_DUMP
                ;;
            "$DYNAMIC_CLUSTERS")
                # shellcheck disable=SC2086
                jq -r "$DYNAMIC_CLUSTERS_QUERY" <$ENVOY_CONFIG_DUMP
                ;;
            "$STATIC_ENDPOINTS")
                # shellcheck disable=SC2086
                jq -r "$STATIC_ENDPOINTS_QUERY" <$ENVOY_CONFIG_DUMP
                ;;
            "$DYNAMIC_ENDPOINTS")
                # shellcheck disable=SC2086
                jq -r "$DYNAMIC_ENDPOINTS_QUERY" <$ENVOY_CONFIG_DUMP
                ;;
            "$PUBLIC_LISTENERS")
                # shellcheck disable=SC2086
                jq -r "$PUBLIC_LISTENERS_QUERY" <$ENVOY_CONFIG_DUMP
                ;;
            "$PUBLIC_LISTENER_FILTER_CHAINS")
                # shellcheck disable=SC2086
                jq -r "$PUBLIC_LISTENER_FILTER_CHAINS_QUERY" <$ENVOY_CONFIG_DUMP
                ;;
            "$OUTBOUND_LISTENERS")
                # shellcheck disable=SC2086
                jq -r "$OUTBOUND_LISTENERS_QUERY" <$ENVOY_CONFIG_DUMP
                ;;
            "$OUTBOUND_LISTENER_FILTER_CHAINS")
                # shellcheck disable=SC2086
                jq -r "$OUTBOUND_LISTENER_FILTER_CHAINS_QUERY" <$ENVOY_CONFIG_DUMP
                ;;
            *)
                # shellcheck disable=SC2086
                jq -r <$ENVOY_CONFIG_DUMP
                ;;
        esac
    fi

    if [[ "$CLUSTERS" == 1 ]]; then
        envoy_clusters_filter "$ENVOY_CLUSTERS" "$CLUSTER_NAME_FILTER" "$CLUSTER_IP_ADDR_FILTER" "$CLUSTER_IP_PORT_FILTER" "$CLUSTER_HEALTH_STATUS" || {
            err "envoy-parse: Failed to parse Envoy clusters!"
            exit
        }
    fi

    if [[ "$LISTENERS" == 1 ]]; then
        info "envoy-parse: Dumping listeners for $SERVICE in $SERVICE_NS namespace (Format: $FORMAT)."
        envoy_listeners_filter "$ENVOY_LISTENERS" || {
            err "envoy-parse: Failed to parse Envoy listeners!"
            exit
        }
    fi
}
main