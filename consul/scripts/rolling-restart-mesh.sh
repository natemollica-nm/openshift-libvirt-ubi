#!/usr/bin/env bash

SINGLE_CLUSTER=${1:-false}

CLUSTER1_CONTEXT=dc1
CLUSTER2_CONTEXT=dc2
CLUSTER_CONTEXTS=("$CLUSTER1_CONTEXT" "$CLUSTER2_CONTEXT")

if "$SINGLE_CLUSTER"; then
     CLUSTER_CONTEXTS=("$CLUSTER1_CONTEXT")
fi

eval "$(cat scripts/logging.sh)"
eval "$(cat scripts/formatting.env)"

for cluster_context in "${CLUSTER_CONTEXTS[@]}"; do
    for svc in frontend backend consul-mesh-gateway consul-terminating-gateway; do
        info "mesh-rolling-restart: Running rollout restart on $svc | $cluster_context"
        oc --context "$cluster_context" --namespace consul rollout restart deploy/"$svc"
    done
done
    
info "mesh-rolling-restart: Done!"