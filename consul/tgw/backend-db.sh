#!/usr/bin/env bash

eval "$(cat ../env)"
eval "$(cat scripts/logging.sh)"
eval "$(cat scripts/formatting.env)"

export PARTITION
export REGION ZONE

export ACTION="${1:-create}"
export SINGLE_CLUSTER=${2:-false}
export REGISTRATION_TYPE="${3:-destination}"
export CONSUL_K8s_RELEASE_VER="${4}"
export OSS="${5:-false}"

export OC_PATH="$SETUP_DIR"/oc
CLUSTER_CONTEXTS=("${CLUSTER_NAME}")

declare -A CLUSTERS_REGIONS=(
    ["dc1"]="us-east-2"
    ["dc2"]="us-east-1"
)

declare -A LOCALITY_ZONES=(
    ["us-east-1"]="us-east-1a"
    ["us-east-2"]="us-east-2a"
)

[[ "$REGISTRATION_TYPE" =~ destination|explicit ]] || {
    err "backend-db: Service registration type should be one of 'destination' (transparent proxy destinations) or 'explicit' (registration CRD to Catalog) not '$REGISTRATION_TYPE'!"
    exit
}

# Set Helm values file based on OSS flag
HELM_VALUES="values-ent.yaml"
[ "$OSS" = true ] && HELM_VALUES="values-ce.yaml"


export CONSUL_HTTP_ADDR=https://localhost:8501
if [ "$(yq '.global.tls.enabled' < "$HELM_VALUES")" != true ]; then
   CONSUL_HTTP_ADDR=http://localhost:8500
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
    [[ "$version1" -ge "$version2" ]]
}

apply_network_attachment_def() {
    local cluster_context="$1"
    local namespace="$2"
    local action="$3"

    info "install-consul: Applying consul-cni network-attachment-definition.yaml"
    "${OC_PATH}" --context "$cluster_context" --namespace "$namespace" "$action" -f crds/network-attachment-definition.yaml >/dev/null 2>&1 || {
        return 1
    }
}

apply_templates() {
    local cluster_context="$1"
    local action="$2"
    local registration_file

    info "backend-db: Running '$action' for backend-db sa, service, and deployment"
    "${OC_PATH}" "${action}" --context "$cluster_context" -f tgw/backend-db/db-service.yaml >/dev/null 2>&1 || {
        [ "$action" = apply ] && err "backend-db: Failing to run '$action' for backend-db sa, service, and deployment!" && \
            return 1
    }

    # Get Consul Control Plane version
    local consul_control_plane_version="$CONSUL_K8s_RELEASE_VER"
    local consul_k8s_required_ver="1.5.1"


    export PARTITION=default
    export BACKEND_DB_POD_IP=""
    export BACKEND_DB_SVC_IP=""
    local counter=0
    if [ "$action" = apply ]; then
        BACKEND_DB_SVC_IP="$("${OC_PATH}" --context "$cluster_context" get svc -n default backend-db -o json | jq -r '.spec.clusterIP')"
        while [ "$BACKEND_DB_SVC_IP" = null ] || [ -z "$BACKEND_DB_SVC_IP" ] && [ $counter -lt 5 ]; do
           BACKEND_DB_SVC_IP="$("${OC_PATH}" --context "$cluster_context" get svc -n default backend-db -o json | jq -r '.spec.clusterIP')"
           [ "$BACKEND_DB_SVC_IP" = null ] || [ -z "$BACKEND_DB_SVC_IP" ] && warn "backend-db: Waiting for backend-db pod to come online..." && \
              sleep 2
           counter=$((counter+1))
        done
        [ "$counter" -eq 5 ] && err "backend-db: Reached counter limit in trying to obtain backend-db kube svc IP!" && return 1

        counter=0
        BACKEND_DB_POD_IP="$("${OC_PATH}" --context "$cluster_context" get pod -n default -l app=backend-db -o json | jq -r '.items[0].status.podIP')"
        while [ "$BACKEND_DB_POD_IP" = null ] || [ -z "$BACKEND_DB_POD_IP" ] && [ $counter -lt 5 ]; do
           BACKEND_DB_POD_IP="$("${OC_PATH}" --context "$cluster_context" get pod -n default -l app=backend-db -o json | jq -r '.items[0].status.podIP')"
           [ "$BACKEND_DB_POD_IP" = null ] || [ -z "$BACKEND_DB_POD_IP" ] && warn "backend-db: Waiting for backend-db pod to come online..." && \
              sleep 2
           counter=$((counter+1))
        done
        [ "$counter" -eq 5 ] && err "backend-db: Reached counter limit in trying to obtain backend-db podIP!" && return 1
    fi

    yq eval -i 'del(.spec.destination)' tgw/backend-db/defaults.yaml ## Delete/reset destination block
    yq eval -i '.spec.protocol = "tcp"' tgw/backend-db/defaults.yaml
    case "$REGISTRATION_TYPE" in
        explicit)
              registration_file=tgw/explicit-registration/registration.yaml
              yq eval -i '.spec.transparentProxy.dialedDirectly = true' tgw/backend-db/defaults.yaml
              info "backend-db: Running '$action' for backend-db ServiceResolver (VirtualIP Resolution) | $cluster_context"
              "${OC_PATH}" --context "$cluster_context" "${action}" -f tgw/backend-db/resolver.yaml >/dev/null 2>&1 || {
                  [ "$action" = apply ] && err "backend-db: Failing to run '$action' for backend-db ServiceResolver!" && \
                      yq . tgw/backend-db/resolver.yaml && \
                      return 1
              }
        ;;
        destination)
              registration_file=tgw/backend-db/defaults.yaml
              yq eval -i '.spec.transparentProxy.dialedDirectly = true' tgw/backend-db/defaults.yaml
              yq eval -i '.spec.destination.port = 5432' "$registration_file"
              yq eval -i '.spec.destination.addresses = []' "$registration_file"
              yq eval -i '.spec.destination.addresses += "backend-db.default.svc.cluster.local"' "$registration_file"
              yq eval -i ".spec.destination.addresses += \"$BACKEND_DB_SVC_IP\"" "$registration_file"
              yq eval -i ".spec.destination.addresses += \"$BACKEND_DB_POD_IP\"" "$registration_file"
        ;;
    esac
    export REGION="${CLUSTERS_REGIONS[$cluster_context]}"
    export ZONE="${LOCALITY_ZONES[$REGION]}"
    local REGISTRATION_PAYLOAD
    if version_greater_equal "$consul_control_plane_version" "$consul_k8s_required_ver" || [ "$REGISTRATION_TYPE" = destination ]; then
        info "backend-db: Running '$action' for backend-db | $registration_file | (Destination/RegistrationIP: $BACKEND_DB_SVC_IP/$BACKEND_DB_POD_IP) | Partition: $PARTITION | $cluster_context"
        envsubst < "$registration_file"  | "${OC_PATH}" --context "$cluster_context" "${action}" -f - >/dev/null 2>&1 || {
            [ "$action" = apply ] && err "backend-db: Failing to run '$action' for backend-db ServiceDefaults!" && \
                cat "$registration_file" && \
                return 1
        }
    else
        info "backend-db: Running '$action' for backend-db ServiceDefaults"
        "${OC_PATH}" --context "$cluster_context" "$action" -f tgw/backend-db/defaults.yaml >/dev/null 2>&1 || {
            err "backend-db: Failed to run '$action' for backend-db ServiceDefaults!"
            return 1
        }

        local BOOTSTRAP_TOKEN
        local CONSUL_ACL_HEADER=""
        if [ "$(yq '.global.acls.manageSystemACLs' < "$HELM_VALUES")" = true ]; then
            BOOTSTRAP_TOKEN=$("${OC_PATH}" get secret --context "$cluster_context" --namespace consul bootstrap-token -o yaml | yq -r '.data.key' | base64 -d)
            if [ -z "$BOOTSTRAP_TOKEN" ]; then
                err "tgw-acl: failed to retrieve bootstrap token"
                return 1
            fi
            CONSUL_ACL_HEADER="X-Consul-Token:$BOOTSTRAP_TOKEN"
        fi

        [ "$cluster_context" = "$CLUSTER2_CONTEXT" ] && cluster_context="$CLUSTER1_CONTEXT" ## AP Cluster has no consul-server, so use associated DCs

        if [ "$action" = apply ]; then
            info "backend-db: Running '$action' for backend-db.json catalog registration (CatalogIPs (svc/pod): $BACKEND_DB_SVC_IP/$BACKEND_DB_POD_IP) | Partition: $PARTITION | $cluster_context"
            REGISTRATION_PAYLOAD="$(envsubst < tgw/explicit-registration/backend-db.json)"
            echo "$REGISTRATION_PAYLOAD" | jq .
            "${OC_PATH}" exec --context "$cluster_context" --namespace consul pod/consul-server-0 -c consul -it -- curl --silent --insecure --request PUT --header "$CONSUL_ACL_HEADER" --data "$REGISTRATION_PAYLOAD" "$CONSUL_HTTP_ADDR"/v1/catalog/register >/dev/null 2>&1 || {
                    err "backend-db: Failed running '$action' for catalog registration on backend-db!"
                    echo "$REGISTRATION_PAYLOAD" | jq .
                    return 1
            }
        else
            info "backend-db: Running deregistration for backend-db-dereg.json catalog (CatalogIPs (svc/pod): $BACKEND_DB_SVC_IP/$BACKEND_DB_POD_IP) | Partition: $PARTITION | $cluster_context"
            REGISTRATION_PAYLOAD="$(envsubst < tgw/explicit-registration/backend-db-dereg.json)"
            echo "$REGISTRATION_PAYLOAD" | jq .
            "${OC_PATH}" exec --context "$cluster_context" --namespace consul pod/consul-server-0 -c consul -it -- curl --silent --insecure --request PUT --header "$CONSUL_ACL_HEADER" --data "$REGISTRATION_PAYLOAD" "$CONSUL_HTTP_ADDR"/v1/catalog/deregister >/dev/null 2>&1 || {
                    err "backend-db: Failed running '$action' for catalog deregistration on backend-db!"
                    echo "$REGISTRATION_PAYLOAD" | jq .
                    return 1
            }
        fi
    fi

    return 0
}
info "backend-db: Cluster contexts ${CLUSTER_CONTEXTS[*]}"
for cluster_context in "${CLUSTER_CONTEXTS[@]}"; do
    if [ "${ACTION}" = delete ]; then
        info "backend-db: Destroying backend-db service resources"
        apply_network_attachment_def "$cluster_context" default delete || {
            err "backend-db: Failed to apply network-attachment-policy definition!"
            exit
        }
        apply_templates "$cluster_context" delete || { exit; }
    else
        info "backend-db: Deploying backend-db service resources"
        apply_network_attachment_def "$cluster_context" default apply || {
            err "backend-db: Failed to apply network-attachment-policy definition!"
            exit
        }
        apply_templates "$cluster_context" apply || { exit; }
    fi
done
info "backend-db: Done!"
