#!/usr/bin/env bash

eval "$(cat env)"
eval "$(cat scripts/logging.sh)"
eval "$(cat scripts/formatting.env)"

export OC_PATH="$SETUP_DIR"/oc

# /////////////////////////////////////////////////////////////////////////////////////////////// #
# /////////////////////////////////////////////////////////////////////////////////////////////// #
info "kubeconfig: Backing up $KUBECONFIG *==> $KUBECONFIG.bak"
cp "${KUBECONFIG}" "${KUBECONFIG}".bak || {
    err "Failed to backup $KUBECONFIG!"
    exit
}

info "kubeconfig: Renaming openshift/${CLUSTER_NAME}/kubeconfig 'admin' context *==> ${CLUSTER_NAME}"
"${OC_PATH}" config rename-context admin "${CLUSTER_NAME}" >/dev/null 2>&1 || {
    err "kubeconfig: Failed to update $CLUSTER_NAME kubeconfig context name"
    exit
}

info "kubeconfig: Renaming '$CLUSTER_NAME' admin user to admin-$CLUSTER_NAME"
"${OC_PATH}" config set "contexts.${CLUSTER_NAME}.user" "admin-${CLUSTER_NAME}" >/dev/null 2>&1 || {
    err "kubeconfig: Failed to set $CLUSTER_NAME admin username!"
    exit
}

info "kubeconfig: Updating '$CLUSTER_NAME' admin-$CLUSTER_NAME user credential name"
yq -ei '.users[].name = "admin-'${CLUSTER_NAME}'"' "${KUBECONFIG}" 2>&1 || {
    err "kubeconfig: Failed to update $CLUSTER_NAME admin-$CLUSTER_NAME credential name!"
    exit
}


info "kubeconfig: Setting 0600 permissions for ${KUBECONFIG}"
chmod 0600 "${KUBECONFIG}" || {
      err "kubeconfig: Failed to set 'kubeconfig' permissions!"
      exit
}

info "kubeconfig: OpenShift successfully obtained for $CLUSTER_NAME.$BASE_DOM"