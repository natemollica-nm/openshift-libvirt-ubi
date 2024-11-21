#!/usr/bin/env bash

eval "$(cat scripts/logging.sh)"
eval "$(cat scripts/formatting.env)"

SINGLE_CLUSTER=${1:-false}
ENVOY_CONCURRENCY="${2:-4}"

CLUSTER1_CONTEXT=dc1
CLUSTER2_CONTEXT=dc2
CLUSTER_CONTEXTS=("$CLUSTER1_CONTEXT" "$CLUSTER2_CONTEXT")

if "$SINGLE_CLUSTER"; then
     CLUSTER_CONTEXTS=("$CLUSTER1_CONTEXT")
fi

for cluster_context in "${CLUSTER_CONTEXTS[@]}"; do
    for svc in \
      terminating-gateway \
      mesh-gateway \
      ; do
      info "envoy-concurrency: Configuring $cluster_context consul-$svc Envoy concurrency *==> $ENVOY_CONCURRENCY"
      oc --context "$cluster_context" patch \
          deployment \
          consul-"$svc" \
          --namespace consul \
          --type='json' \
          --patch "[{\"op\": \"add\", \"path\": \"/spec/template/spec/containers/0/args/-\", \"value\": \"-envoy-concurrency=$ENVOY_CONCURRENCY\"}]" 2>&1 || {
              err "envoy-concurrency: Failed to set Envoy concurrency for $svc | $cluster_context!"
              exit
          }
    done
done
info "envoy-concurrency: Done!"