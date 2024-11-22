#!/usr/bin/env bash

eval "$(cat ../env)"
eval "$(cat scripts/logging.sh)"
eval "$(cat scripts/formatting.env)"

ACTION="${1:-create}"

export OC_PATH="$SETUP_DIR"/oc
CLUSTER_CONTEXTS=("${CLUSTER_NAME}")

apply_templates() {
    local cluster_context="$1"
    local action="$2"

    info "terminating-gateway: Running '$action' on terminating-gateway | $cluster_context"
    "${OC_PATH}" "${action}" --context "$cluster_context" -f tgw/tgw.yaml >/dev/null 2>&1 || {
        [ "$action" = apply ] && err "terminating-gateway: failed to apply tgw.yaml" && \
            return 1
    }
    return 0
}

for cluster_context in "${CLUSTER_CONTEXTS[@]}"; do
    if [ "${ACTION}" = delete ]; then
        info "terminating-gateway: Destroying terminating-gateway"
        apply_templates "$cluster_context" delete || {
            err "services-services: Failed to delete '$cluster_context' terminating-gateway!"
            exit
        }
        info "terminating-gateway: Terminating Gateway delete complete!"
    else
        info "terminating-gateway: Deploying terminating-gateway"
        apply_templates "$cluster_context" apply || {
            err "terminating-gateway: Failed to deploy '$cluster_context' terminating-gateway!"
            exit
        }
    fi

done
info "terminating-gateway: Done!"
