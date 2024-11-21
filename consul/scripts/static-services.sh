#!/bin/bash

set -e

ACTION="${1:-apply}"

eval "$(cat .env)"

apply_templates() {
  local cluster_context="$1"
  export PEER="$2"
  export PARTITION="$3"
  local action="$4"

  envsubst < static-services/static-server-template.yaml | openshift/oc --kubeconfig openshift/kubeconfig "${action}" --context "$cluster_context" -f -
  envsubst < static-services/static-client-template.yaml | openshift/oc --kubeconfig openshift/kubeconfig "${action}" --context "$cluster_context" -f -
}

if [ "${ACTION}" = delete ]; then
  apply_templates "$CLUSTER1_CONTEXT" "cluster-01-a" "default" delete
  exit 0
fi
apply_templates "$CLUSTER1_CONTEXT" "cluster-01-a" "default" apply
#apply_templates "$CLUSTER2_CONTEXT" "cluster-01-b" "ap1"
#apply_templates "$CLUSTER3_CONTEXT" "cluster-02" "default"
#apply_templates "$CLUSTER4_CONTEXT" "cluster-03" "default"
