#!/usr/bin/env bash

eval "$(cat scripts/logging.sh)"
eval "$(cat scripts/formatting.env)"

CONSUL_VERSION="$1"
CONSUL_K8s_VER="$2"
CONSUL_DP_VERSION="$3"
CONSUL_REGISTRY="$4"
CONSUL_K8s_REGISTRY="$5"
CONSUL_DATAPLANE_REGISTRY="$6"
# Confirm user's selection
# Usage: confirm "Are you sure?" && echo "User confirmed."
confirm() {
    local prompt="${1:-Are you sure?}"  # Default prompt message if none provided
    local response

    while true; do
        prompt "$prompt [y/n]: "
        read -r response </dev/tty
        case "$response" in
            [yY][eE][sS]|[yY]) return 0 ;;  # User confirmed
            [nN][oO]|[nN]) return 1 ;;      # User denied
            *) echo "Please respond with yes or no." ;;  # Invalid response
        esac
    done
}

HASHICORP_PREVIEW_REGISTRY=hashicorppreview
CONSUL_K8s_VER="${CONSUL_K8s_VER}-ubi"
[ "$CONSUL_REGISTRY" = "$HASHICORP_PREVIEW_REGISTRY" ] && CONSUL_VERSION="${CONSUL_VERSION%-ent-ubi}" || CONSUL_VERSION="${CONSUL_VERSION}-ent-ubi"
[ "$CONSUL_DATAPLANE_REGISTRY" = "$HASHICORP_PREVIEW_REGISTRY" ] && CONSUL_DP_VERSION="${CONSUL_DP_VERSION%-ubi}" || CONSUL_DP_VERSION="${CONSUL_DP_VERSION}-ubi"

print_msg "consul-version: Confirm the following versions" \
    "export CONSUL_IMAGE=${CONSUL_REGISTRY}/consul-enterprise:${CONSUL_VERSION}" \
    "export CONSUL_K8S_IMAGE=${CONSUL_K8s_REGISTRY}/consul-k8s-control-plane:${CONSUL_K8s_VER}" \
    "export CONSUL_K8S_DP_IMAGE=${CONSUL_DATAPLANE_REGISTRY}/consul-dataplane:${CONSUL_DP_VERSION}"
# docker.mirror.hashicorp.services/hashicorppreview/consul:1.20-dev
# docker.mirror.hashicorp.services/hashicorppreview/consul-k8s-control-plane:1.6-dev
# docker.mirror.hashicorp.services/hashicorppreview/consul-dataplane:1.6-dev
if confirm 'Update '.k8sImages.env' with these versions? (any key to continue | ctrl+c to cancel)'; then
    {
    echo "export CONSUL_IMAGE=${CONSUL_REGISTRY}/consul-enterprise:${CONSUL_VERSION}"
    echo "export CONSUL_K8S_IMAGE=${CONSUL_K8s_REGISTRY}/consul-k8s-control-plane:${CONSUL_K8s_VER}"
    echo "export CONSUL_K8S_DP_IMAGE=${CONSUL_DATAPLANE_REGISTRY}/consul-dataplane:${CONSUL_DP_VERSION}"
    } >.k8sImages.env
    info "consul-version: .k8sImages.env updated!"
else
    info "consul-version: Version update cancelled!"
fi
info "consul-version: done!"
