#!/usr/bin/env bash

eval "$(cat ../env)"
eval "$(cat scripts/logging.sh)"
eval "$(cat scripts/formatting.env)"

ACTION="${1:-create}"

CLUSTER1_CONTEXT="${CLUSTER_NAME}"
CLUSTER_CONTEXTS=("$CLUSTER1_CONTEXT")


case "$ACTION" in
    create|apply|deploy|run) ACTION=apply ;;
    delete|destroy|rm|remove) ACTION=delete ;;
    *)
        warn "fake-services: Invalid parameter option!"
        print_msg "fake-services: Must follow the following:" \
            "Deployment Options:  create, apply, deploy, run" \
            "Teardown Options:    delete, destroy, rm, remove"
    ;;
esac

export OC_PATH="$SETUP_DIR"/oc

declare -A DATACENTERS=(
    ["$CLUSTER1_CONTEXT"]="dc1"
)

run_templated_action() {
    local cluster_context="$1"
    local action="$2"
    local resource

    export BACKEND_REPLICAS=1
    export SVC_CLUSTER="$( echo "${DATACENTERS[$cluster_context]}" | tr '[:lower:]' '[:upper:]')"
    for resource in \
        frontend-service.yaml \
        backend-service.yaml \
        intentions.yaml \
        service-defaults.yaml; do

        export UPSTREAM_URIS="http://backend.consul.svc.cluster.local"
        [ "$resource" = backend-service.yaml ] && export UPSTREAM_URIS="https://example.com, http://backend-db.default.svc.cluster.local:5432"
        info "fake-services: Running 'oc $action -f fake/$resource'"
        [[ "$resource" =~ frontend-service*|backend-service* ]] && info "fake-services: $resource | Upstreams: $UPSTREAM_URIS"
        envsubst <fake/"$resource" | timeout --foreground 1m "$OC_PATH" --context "$cluster_context" "${action}" -f - 2>&1 || {
            [ "$action" != apply ] && \
                warn "fake-services: Timed out running 'oc $action -f fake/$resource' (1m), some resources may still be present" && \
                return 0
            err "fake-services: Timed out running 'oc $action -f fake/$resource' (1m), deploy failed!"
            return 1
        }
    done
}
for cluster_context in "${CLUSTER_CONTEXTS[@]}"; do
    run_templated_action "$cluster_context" "$ACTION"
done
