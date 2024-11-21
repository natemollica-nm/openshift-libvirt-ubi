#!/bin/bash

set -e

eval "$(cat .env)"
eval "$(cat .k8sImages.env)"

export CHART_PATH=$1
export K8s_VERSION=$2


import_redhat_images() {
  local cluster_context="$1"

  echo "helm-upgrade-consul: importing redhat registry images for consul, consul-k8s, and consul-dataplane"
  echo "    >- ${CONSUL_IMAGE}"
  echo "    >- ${CONSUL_K8S_IMAGE}"
  echo "    >- ${CONSUL_K8S_DP_IMAGE}"
  openshift/oc --kubeconfig openshift/kubeconfig --context "$cluster_context" import-image "${CONSUL_IMAGE#registry.connect.redhat.com/}" --from="${CONSUL_IMAGE}" --confirm &>/dev/null || {
    echo "helm-upgrade-consul: failed to import $CONSUL_IMAGE"
    exit 1
  }
  echo "helm-upgrade-consul: successfully imported $CONSUL_K8S_IMAGE"
  openshift/oc --kubeconfig openshift/kubeconfig --context "$cluster_context" import-image "${CONSUL_K8S_IMAGE#registry.connect.redhat.com/}" --from="${CONSUL_K8S_IMAGE}" --confirm &>/dev/null || {
    echo "helm-upgrade-consul: failed to import $CONSUL_K8S_IMAGE"
    exit 1
  }
  echo "helm-upgrade-consul: successfully imported $CONSUL_K8S_DP_IMAGE"
  openshift/oc --kubeconfig openshift/kubeconfig --context "$cluster_context" import-image "${CONSUL_K8S_DP_IMAGE#registry.connect.redhat.com/}" --from="${CONSUL_K8S_DP_IMAGE}" --confirm &>/dev/null || {
    echo "helm-upgrade-consul: failed to import $CONSUL_K8S_DP_IMAGE"
    exit 1
  }
}
# import_redhat_images "$CLUSTER1_CONTEXT"
clear
export HELM_RELEASE_NAME=consul
echo "helm-upgrade-consul: running helm upgrade ${HELM_RELEASE_NAME}"
helm upgrade ${HELM_RELEASE_NAME} "$CHART_PATH" \
  --create-namespace \
  --namespace "$CONSUL_NS" \
  --version "$K8s_VERSION" \
  --values values-ent.yaml \
  --set global.datacenter=dc1 \
  --set global.image="$CONSUL_IMAGE" \
  --set global.imageK8S="$CONSUL_K8S_IMAGE" \
  --set global.imageConsulDataplane="$CONSUL_K8S_DP_IMAGE" \
  --kubeconfig openshift/kubeconfig \
  --kube-context "$CLUSTER1_CONTEXT"

echo "helm-upgrade-consul: waiting for mesh-gateway to become ready... | $CLUSTER1_CONTEXT"
kubectl wait \
  --kubeconfig openshift/kubeconfig \
  --context "$CLUSTER1_CONTEXT" \
  --namespace "$CONSUL_NS" \
  --for=condition=ready pod \
  --selector=app=consul,component=mesh-gateway \
  --timeout=90s
