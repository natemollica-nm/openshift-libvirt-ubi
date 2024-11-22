#!/usr/bin/env bash

set -e

eval "$(cat ../env)"
eval "$(cat scripts/logging.sh)"
eval "$(cat scripts/formatting.env)"

CTX="$1"
FORCE="${2:-false}"

export OC_PATH="$SETUP_DIR"/oc

delete_consul_crds() {
    local cluster_context="$1"
    export PEER="$2"
    export PARTITION=default
    if [ "$cluster_context" == "$CLUSTER2_CONTEXT" ]; then
      export PARTITION=ap1
    fi
    info "uninstall-consul: removing consul crds from $cluster_context | KUBECONFIG=$KUBECONFIG"
    envsubst < "crds/mesh.yaml" | "$OC_PATH" --context "$cluster_context" delete -f - >/dev/null 2>&1 || true
    envsubst < "crds/proxy-defaults.yaml" | "$OC_PATH" --context "$cluster_context" delete -f - >/dev/null 2>&1 || true
    envsubst < "crds/intentions.yaml" | "$OC_PATH" --context "$cluster_context" delete -f - >/dev/null 2>&1 || true
    envsubst < "crds/exported-services.yaml" | "$OC_PATH" --context "$cluster_context" delete -f - >/dev/null 2>&1 || true
    envsubst < "crds/static-server-service-resolver.yaml" | "$OC_PATH" --context "$cluster_context" delete -f - >/dev/null 2>&1 || true
    envsubst < "crds/static-server-service-defaults.yaml" | "$OC_PATH" --context "$cluster_context" delete -f - >/dev/null 2>&1 || true
    envsubst < "crds/fake-service-resolver.yaml" | "$OC_PATH" --context "$cluster_context" delete -f - >/dev/null 2>&1 || true
    envsubst < "crds/fake-service-defaults.yaml" | "$OC_PATH" --context "$cluster_context" delete -f - >/dev/null 2>&1 || true
}

delete_kube_services() {
    local cluster_context="$1"
    export PEER="$2"
    export PARTITION="$3"

    info "uninstall-consul: uninstalling kube services from $cluster_context"
    envsubst < crds/static-server-template.yaml | "$OC_PATH" delete --context "$cluster_context" -f - >/dev/null 2>&1 || true
    envsubst < crds/static-client-template.yaml | "$OC_PATH" delete --context "$cluster_context" -f - >/dev/null 2>&1 || true
    envsubst < crds/frontend-service-template.yaml | "$OC_PATH" delete --context "$cluster_context" -f - >/dev/null 2>&1 || true
    envsubst < crds/backend-service-template.yaml | "$OC_PATH" delete --context "$cluster_context" -f - >/dev/null 2>&1 || true
}

uninstall_consul() {
    local cluster_context="$1"
    local namespace="$2"

    print_msg "uninstall-consul: consul-k8s uninstall on consul" "Running: consul-k8s uninstall -context $cluster_context -namespace $namespace -auto-approve=true -wipe-data=true"
    consul-k8s uninstall -context "$cluster_context" -namespace "$namespace" -auto-approve=true -wipe-data=true >/dev/null 2>&1 || {
      warn "uninstall-consul: 'consul-k8s' cli uninstall failed"
      print_msg "uninstall-consul: Attempting consul-k8s uninstallation via helm" "Running: helm uninstall consul --namespace $namespace"
      helm uninstall consul --kube-context "$cluster_context" --namespace "$namespace" >/dev/null 2>&1 || {
          return 1
      }
    }
    info "uninstall-consul: Deleting '$namespace' project (namespace)"
    timeout --foreground 1m "$OC_PATH" delete project "$namespace" >/dev/null 2>&1 || {
        warn "uninstall-consul: Project deletion timed out (1m), some resources may need to be cleaned up..."
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

force_uninstall() {
  local ans

  info "uninstall-consul: Running forced namespace cleanup on consul resources"
  if confirm "Run knsk.sh --delete-resource --force? (y/n): "; then
      info "uninstall-consul: Running force namespace removal for consul..." && \
          "$OC_PATH" config use-context "$CTX"
      scripts/knsk.sh --delete-resource --force || {
        return 1
      }
      info "uninstall-consul: Successfully force removed consul!"
      return 0
  else
    info "uninstall-consul: Force uninstallation cancelled!"
    return 0
  fi
}


if [ "$FORCE" = true ]; then
  force_uninstall || {
      err "uninstall-consul: Failed force uninstalling consul!"
      exit
  }
else
  uninstall_consul "$CTX" "$CONSUL_NS" || {
      warn "uninstall-consul: Failed to uninstall consul via 'consul-k8s' cli and helm!"
      exit_code=1
      exit
  }
fi
info "uninstall-consul: done!"