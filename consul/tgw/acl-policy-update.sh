#!/usr/bin/env bash

# Load environment variables and functions
eval "$(cat ../env)"
eval "$(cat scripts/logging.sh)"
eval "$(cat scripts/formatting.env)"

export SERVICE="${1:-""}"
export NAMESPACE="${2:-default}"
export SINGLE_CLUSTER="${3:-false}"

# Define cluster contexts
export OC_PATH="$SETUP_DIR"/oc
CLUSTER_CONTEXTS=("${CLUSTER_NAME}")

# Function to create or update policies
create_or_update_policy() {
    local context=$1
    local rules=$2
    local partition=$3

    [ "$partition" = dev ] && context="$CLUSTER_NAME"
    [ -z "$SERVICE" ] && SERVICE="$NAMESPACE"
    warn "tgw-acl: Creating ${SERVICE}-policy | $context"
    "${OC_PATH}" exec --context "$context" --namespace consul pod/consul-server-0 -c consul -it -- /bin/consul acl policy create -partition "$partition" -token "$BOOTSTRAP_TOKEN" -name "${SERVICE}-policy" -rules "$rules" >/dev/null 2>&1 || {
        warn "tgw-acl: failed to create ${SERVICE}-policy, attempting update policy instead | $context"
        "${OC_PATH}" exec --context "$context" --namespace consul pod/consul-server-0 -c consul -it -- /bin/consul acl policy update -partition "$partition" -token "$BOOTSTRAP_TOKEN" -name "${SERVICE}-policy" -rules "$rules" >/dev/null 2>&1 || {
            err "tgw-acl: Failed to update ${SERVICE}-policy!"
            return 1
        }
    }
}

# Function to update ACL role
update_acl_role() {
    local context=$1
    local partition=$2
    local role_id

    [ "$partition" = dev ] && context="$CLUSTER_NAME"
    role_id=$("${OC_PATH}" exec --context "$context" --namespace consul pod/consul-server-0 -c consul -it -- /bin/consul acl role list -partition "$partition" -token "$BOOTSTRAP_TOKEN" -format=json | jq --raw-output '[.[] | select(.Name | endswith("-terminating-gateway-acl-role"))] | if (. | length) == 1 then (. | first | .ID) else "Unable to determine the role ID because there are multiple roles matching this name.\n" | halt_error end')

    if [ -z "$role_id" ]; then
        err "tgw-acl: failed to retrieve tgw role id token | $context"
        return 1
    fi

    info "tgw-acl: updating tgw acl role with ${SERVICE}-policy | $context"
    "${OC_PATH}" exec --context "$context" --namespace consul pod/consul-server-0 -c consul -it -- /bin/consul acl role update -partition "$partition" -token "$BOOTSTRAP_TOKEN" -id "$role_id" -policy-name "${SERVICE}-policy" >/dev/null 2>&1 || {
        err "tgw-acl: Failed to attach ${SERVICE}-policy to terminating-gateway role!"
        return 1
    }
}

# Iterate over cluster contexts and apply policies and roles
for cluster_context in "${CLUSTER_CONTEXTS[@]}"; do
    # Retrieve the bootstrap token
    BOOTSTRAP_TOKEN=$("${OC_PATH}" get secret --context "$cluster_context" --namespace consul consul-bootstrap-acl-token -o yaml | yq -r '.data.token' | base64 -d)
    if [ -z "$BOOTSTRAP_TOKEN" ]; then
        err "tgw-acl: failed to retrieve bootstrap token"
        exit
    fi
        RULES="$(cat <<-EOF
partition "default" {
  namespace "$NAMESPACE" {
    service_prefix "" {
      policy    = "write"
      intention = "read"
    }
  }
}
EOF
)"
        PARTITION_RULES="$(cat <<-EOF
partition "dev" {
  namespace "$NAMESPACE" {
    service_prefix "" {
      policy    = "write"
      intention = "read"
    }
  }
}
EOF
)"
    create_or_update_policy "$cluster_context" "$RULES" default || { exit; }
    update_acl_role "$cluster_context" default || { exit; }
    unset BOOTSTRAP_TOKEN
done

info "tgw-acl: Consul Terminating Gateway ACL Role(s) updated with $SERVICE-policy!"
