#!/usr/bin/env bash

set -e

# Load environment
eval "$(cat env)"
eval "$(cat .k8sImages.env)"
eval "$(cat scripts/logging.sh)"
eval "$(cat scripts/formatting.env)"

export CHART_PATH="$1"
export CONSUL_VERSION="$2"
export K8s_VERSION="$3"
export UPGRADE="${4:-false}"


export CONSUL_NS=consul
export OC_PATH="$SETUP_DIR"/oc
export OPENSHIFT_INGRESS_DOMAIN="apps.${CLUSTER_NAME}.${BASE_DOM}"


CLUSTER1_CONTEXT="${CLUSTER_NAME}"
CLUSTER_CONTEXTS=("$CLUSTER1_CONTEXT")

test -f /root/pull-secret.yaml || {
    err "install-consul: Pull secret file not found (/root/pull-secret.yaml)! Download and configure pull-secret.yaml from Redhat customer portal prior to installing Consul"
    exit
}

if [ -z "$CONSUL_LICENSE" ]; then
    err "install-consul: Enterprise licensing error. \$CONSUL_LICENSE not set, ensure you set this to a valid ent license prior to running"
    exit
fi

version_greater_equal() {
    # Extract the version strings
    local version1=$1
    local version2=$2

    # Convert versions to a comparable format
    # shellcheck disable=2086
    version1=$(echo $version1 | awk -F. '{ printf("%d%03d%03d", $1,$2,$3); }')
    # shellcheck disable=2086
    version2=$(echo $version2 | awk -F. '{ printf("%d%03d%03d", $1,$2,$3); }')

    # Compare the versions
    if [[ $version1 -ge $version2 ]]; then
        return 0 # True
    else
        return 1 # False
    fi
}

enableHelmRepo() {
    info "helm: Clearing helm repository cache from $HOME/Library/Caches/helm/repository"
    rm -rf "${HOME}"/Library/Caches/helm/repository/* || true
    sleep 2
    info "helm: Adding https://helm.releases.hashicorp.com and updating"
    helm repo add hashicorp https://helm.releases.hashicorp.com >/dev/null 2>&1 || true
    helm repo add hashicorppreview https://helm.mirror.hashicorp.services >/dev/null 2>&1 || true
    helm repo update &>/dev/null
}

is_helm_release_installed() {
    local release_name="$1"
    local namespace="$2"
    local cluster_context="$3"

    # Run 'helm list' and check if the release exists in the specified namespace
    if helm list -n "$namespace" --kube-context "$cluster_context" | grep -qE "^$release_name\s"; then
        return 0 # Return 0 if the release is installed
    else
        return 1 # Return 1 if the release is not installed
    fi
}

import_redhat_images() {
    local cluster_context="$1"

    print_msg "install-consul: Importing redhat registry images for consul, consul-k8s, and consul-dataplane" \
        "${CONSUL_IMAGE}" \
        "${CONSUL_K8S_IMAGE}" \
        "${CONSUL_K8S_DP_IMAGE}"

    if [[ "$CONSUL_IMAGE" == registry.connect.redhat.com/hashicorp/* ]]; then
        "$OC_PATH" --context "$cluster_context" import-image "${CONSUL_IMAGE#registry.connect.redhat.com/}" --from="${CONSUL_IMAGE}" --confirm &>/dev/null || {
            err "install-consul: Failed to import $CONSUL_IMAGE"
            return 1
        }
        info "install-consul: Successfully imported $CONSUL_IMAGE"
    else
        warn "install-consul: Skipping import of $CONSUL_IMAGE (non registry.connect.redhat.com image)"
    fi

    if [[ "$CONSUL_K8S_IMAGE" == registry.connect.redhat.com/hashicorp/* ]]; then
        "$OC_PATH" --context "$cluster_context" import-image "${CONSUL_K8S_IMAGE#registry.connect.redhat.com/}" --from="${CONSUL_K8S_IMAGE}" --confirm &>/dev/null || {
            err "install-consul: Failed to import $CONSUL_K8S_IMAGE"
            return 1
        }
        info "install-consul: Successfully imported $CONSUL_K8S_IMAGE"
    else
        warn "install-consul: Skipping import of $CONSUL_IMAGE (non registry.connect.redhat.com image)"
    fi

    if [[ "$CONSUL_K8S_DP_IMAGE" == registry.connect.redhat.com/hashicorp/* ]]; then
        "$OC_PATH" --context "$cluster_context" import-image "${CONSUL_K8S_DP_IMAGE#registry.connect.redhat.com/}" --from="${CONSUL_K8S_DP_IMAGE}" --confirm &>/dev/null || {
            err "install-consul: Failed to import $CONSUL_K8S_DP_IMAGE"
            return 1
        }
        info "install-consul: Successfully imported $CONSUL_K8S_DP_IMAGE"
    else
        warn "install-consul: Skipping import of $CONSUL_IMAGE (non registry.connect.redhat.com image)"
    fi
    return 0
}

validate_ns() {
  local cluster_context="$1"
  local namespace="$2"
  if ! "$OC_PATH" get namespace --context "$cluster_context" --no-headers -o name | grep -E "$namespace" >/dev/null 2>&1; then
      return 1
  fi
  return 0
}

validate_secret() {
  local cluster_context="$1"
  local namespace="$2"
  local secret="$3"
  if ! "$OC_PATH" get secret --context "$cluster_context" --namespace "$namespace" --no-headers -o name | grep -E "$secret" >/dev/null 2>&1; then
      return 1
  fi
  return 0
}

enforce_pull_secret_name() {
    info "install-consul: Updating /root/pull-secret.yaml name to 'pull-secret'"
    yq -i e '.metadata.name |= "pull-secret"' /root/pull-secret.yaml || {
        return 1
    }
}

create_secret() {
    local cluster_context="$1"
    local namespace="$2"
    local secret_name="$3"
    local key="$4"

    info "install-consul: Creating generic secret $secret_name in ns $namespace | $cluster_context"
    "$OC_PATH" --context "$cluster_context" -n "$namespace" create secret generic "$secret_name" --from-literal="key=$key" >/dev/null 2>&1 || true
    validate_secret "$cluster_context" "$namespace" "$secret_name" || {
        return 1
    }
}

create_consul_project() {
    local cluster_context="$1"
    local namespace="$2"

    info "install-consul: Creating 'consul' project (namespace)"
    "$OC_PATH" adm --context "$cluster_context" new-project "$namespace" >/dev/null 2>&1 || {
        warn "install-consul: Failed to create 'consul' project (may already be created)!"
    }
    info "install-consul: Setting admin cluster context"
    "$OC_PATH" config use-context "${CLUSTER_NAME}" >/dev/null 2>&1 || {
        err "install-consul: Failed to set context to cluster admin context ${CLUSTER_NAME}"
        exit
    }
    validate_ns "$cluster_context" "$namespace" || {
        err "install-consul: '$namespace' creation validation failed!"
        return 1
    }
    info "install-consul: Creating 'consul' project pull-secret"
    "$OC_PATH" create -f /root/pull-secret.yaml --context "$cluster_context" --namespace "$namespace" >/dev/null 2>&1 || {
        warn "install-consul: Failed to create 'consul' project pull-secret (/root/pull-secret.yaml - may already be created)!"
    }
    validate_secret "$cluster_context" "$namespace" pull-secret || {
        err "install-consul: '$namespace' project secret 'pull-secret' validation failed!"
        return 1
    }
}

apply_network_attachment_def() {
    local cluster_context="$1"
    local namespace="$2"

    info "install-consul: Applying consul-cni network-attachment-definition.yaml"
    "$OC_PATH" --context "$cluster_context" apply -f crds/network-attachment-definition.yaml >/dev/null 2>&1 || {
        return 1
    }
}

apply_consul_scc() {
    info "install-consul: Applying consul-tproxy-scc.yaml"
    "$OC_PATH" apply -f scc/consul-tproxy-scc.yaml >/dev/null 2>&1 || {
        return 1
    }
    info "install-consul Attaching consul-tproxy-scc *==> system:serviceaccounts:consul"
    "$OC_PATH" adm policy add-scc-to-group consul-tproxy-scc system:serviceaccounts:consul >/dev/null 2>&1 || {
        return 1
    }
}

apply_proxy_defaults() {
    local cluster_context="$1"
    info "install-consul: Applying crds/proxy-defaults.yaml"
    "$OC_PATH" apply --context "$cluster_context" -f crds/proxy-defaults.yaml >/dev/null 2>&1 || {
        return 1
    }
}

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

enableHelmRepo

for cluster_context in "${CLUSTER_CONTEXTS[@]}"; do
    if [ "$UPGRADE" = false ]; then
        enforce_pull_secret_name || {
            err "install-consul: Failed to update pull-secret.yaml name to 'pull-secret'!"
            exit
        }
        create_consul_project "$cluster_context" consul || {
            err "install-consul: Failed to establish 'consul' project configuration!"
            exit
        }
        create_secret "$cluster_context" "consul" "license" "$CONSUL_LICENSE" || {
            err "install-consul: Failed to create CONSUL_LICENSE secret in 'consul' namespace!"
            exit
        }
        if [ "$(yq '.terminatingGateways.gateways[].extraVolumes' <values-ent.yaml )" != null ]; then
            info "install-consul: Creating/verifying root-tgw-certs in ns consul | $cluster_context"
            kubectl --context "$cluster_context" --namespace consul create secret generic root-tgw-certs --from-file=tgw/certs/ca-roots.pem >/dev/null 2>&1 || true
        fi
    fi
    print_msg "install-consul: Current image settings:" \
        "${CONSUL_IMAGE}" \
        "${CONSUL_K8S_IMAGE}" \
        "${CONSUL_K8S_DP_IMAGE}"
    if confirm 'Import images from RedHat registry to cluster? (any key to continue | ctrl+c to cancel)'; then
        import_redhat_images "$cluster_context" || {
            err "install-consul: Failed during image import from RedHat container registry!"
            exit
        }
    fi

    export HELM_RELEASE_NAME=consul-"${CLUSTER_NAME}"
    print_msg "install-consul: Running helm install for" \
          "Helm Chart: ${CHART_PATH}" \
          "Helm Release: ${HELM_RELEASE_NAME}" \
          "Consul: ${CONSUL_IMAGE}" \
          "Consul Control Plane: ${CONSUL_K8S_IMAGE}" \
          "Consul Dataplane: ${CONSUL_K8S_DP_IMAGE}" \
          "OpenShift Cluster: ${CLUSTER_NAME}.${ROUTE53_HOST_ZONE}"
    helm upgrade "${HELM_RELEASE_NAME}" "${CHART_PATH}" \
        --install \
        --create-namespace \
        --namespace "${CONSUL_NS}" \
        --version "${K8s_VERSION}" \
        --kube-context "${cluster_context}" \
        --values values-ent.yaml \
        --set global.datacenter="${CLUSTER_NAME}" \
        --set global.image="${CONSUL_IMAGE}" \
        --set global.imageK8S="${CONSUL_K8S_IMAGE}" \
        --set global.imageConsulDataplane="${CONSUL_K8S_DP_IMAGE}" \
        --set ui.enabled=true \
        --set ui.ingress.enabled=true \
        --set ui.ingress.pathType=ImplementationSpecific \
        --set ui.ingress.annotations="route.openshift.io/termination: passthrough" \
        --set ui.ingress.hosts[0].host="consul-ui-consul.${OPENSHIFT_INGRESS_DOMAIN}" \
        --set ui.ingress.hosts[0].paths[0]="" 2>&1 || true
    is_helm_release_installed "${HELM_RELEASE_NAME}" "${CONSUL_NS}" "$cluster_context" || {
        err "install-consul: Failed to install consul release ${HELM_RELEASE_NAME}"
        exit
    }
    info "install-consul: Waiting for $HELM_RELEASE_NAME mesh-gateway to become ready (90s)"
    "$OC_PATH" wait \
        --context "$cluster_context" \
        --namespace consul \
        --for=condition=ready pod \
        --selector=app=consul,component=mesh-gateway \
        --timeout=90s >/dev/null 2>&1 || {
            warn "install-consul: Timed out waiting for mesh-gateway pod (90s)"
        }

    apply_network_attachment_def "$cluster_context" consul || {
        err "install-consul: Failed to apply network-attachment-policy definition!"
        exit
    }

    # Get Consul Control Plane version
    consul_control_plane_version="$K8s_VERSION"
    consul_k8s_required_ver="1.5.1"

    if version_greater_equal "$consul_control_plane_version" "$consul_k8s_required_ver"; then
        info "install-consul: $consul_control_plane_version >= $consul_k8s_required_ver, skipping custom SCC creation."
    else
        if confirm 'Configure custom SCC 'consul-tproxy-scc'? (any key to continue | ctrl+c to cancel)'; then
            apply_consul_scc || {
                err "install-consul: Failed to apply SCC consul-tproxy-scc!"
                exit
            }
        fi
    fi
done
info "install-consul: Done!"