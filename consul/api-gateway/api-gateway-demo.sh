#!/usr/bin/env bash

eval "$(cat env)"
eval "$(cat scripts/logging.sh)"
eval "$(cat scripts/formatting.env)"

APP="${1:-default}"
ACTION="${2:-apply}"
CONTEXT="${3:-"${CLUSTER_NAME}"}"

export SCC_ACTION
[[ "$ACTION" =~ delete|rm|destroy ]] && ACTION=delete && SCC_ACTION=remove-scc-from-group
[[ "$ACTION" =~ create|apply ]] && ACTION=apply && SCC_ACTION=add-scc-to-group

export OPENSHIFT_INGRESS_DOMAIN
export OC_PATH="$SETUP_DIR"/oc

## Counting/Dashboard Demo
###########################
COUNTING_SAMPLE_NS=counting-sample-test
COUNTING_SAMPLE_KUSTOMIZE=.customer/fifth-third/counting-sample-test

## Springboot Demo
###################
SPRINGBOOT_ADMIN_NS=spring-boot-sba
SPRINGBOOT_CLIENT_NS=spring-boot-sbc
SPRINGBOOT_DIR=springboot/

## Consul CNI Network Attachment Definition
############################################
NETWORK_ATTACHMENT_DEF=crds/network-attachment-definition.yaml

## OpenShift Ingress Domain
############################
OPENSHIFT_INGRESS_DOMAIN="apps.${CLUSTER_NAME}.${BASE_DOM}"

validate_ns() {
    local cluster_context="$1"
    local namespace="$2"
    local status="$3"

    if ! "$OC_PATH" get namespace --context "$cluster_context" --no-headers -o name | grep -E "$namespace" >/dev/null 2>&1; then
      [[ "$status" =~ create ]] && return 1 || return 0
    fi
    [[ "$status" =~ create ]] && return 0 || return 1
}

namespace() {#!/usr/bin/env bash

eval "$(cat env)"
eval "$(cat scripts/logging.sh)"
eval "$(cat scripts/formatting.env)"

APP="${1:-default}"
ACTION="${2:-apply}"
CONTEXT="${3:-"${CLUSTER_NAME}"}"

export SCC_ACTION
[[ "$ACTION" =~ delete|rm|destroy ]] && ACTION=delete && SCC_ACTION=remove-scc-from-group
[[ "$ACTION" =~ create|apply ]] && ACTION=apply && SCC_ACTION=add-scc-to-group

export OPENSHIFT_INGRESS_DOMAIN
export OC_PATH="$SETUP_DIR"/oc

## Counting/Dashboard Demo
###########################
COUNTING_SAMPLE_NS=counting-sample-test
COUNTING_SAMPLE_KUSTOMIZE=.customer/fifth-third/counting-sample-test

## Springboot Demo
###################
SPRINGBOOT_ADMIN_NS=spring-boot-sba
SPRINGBOOT_CLIENT_NS=spring-boot-sbc
SPRINGBOOT_DIR=springboot/

## Consul CNI Network Attachment Definition
############################################
NETWORK_ATTACHMENT_DEF=crds/network-attachment-definition.yaml

## OpenShift Ingress Domain
############################
OPENSHIFT_INGRESS_DOMAIN="apps.${CLUSTER_NAME}.${BASE_DOM}"

validate_ns() {
    local cluster_context="$1"
    local namespace="$2"
    local status="$3"

    if ! "$OC_PATH" get namespace --context "$cluster_context" --no-headers -o name | grep -E "$namespace" >/dev/null 2>&1; then
      [[ "$status" =~ create ]] && return 1 || return 0
    fi
    [[ "$status" =~ create ]] && return 0 || return 1
}

namespace() {
    local cluster_context="$1"
    local namespace="$2"
    local action="$3"

    info "api-gateway: Running $action for $namespace namespace"
    "$OC_PATH" --context "$cluster_context" "$action" namespace "$namespace" >/dev/null 2>&1 || true
    validate_ns "$cluster_context" "$namespace" "$action" || {
        return 1
    }
    info "api-gateway: Validated $action run for namespace $namespace in $cluster_context!"
    return 0
}

case "$APP" in
    ##### Frontend *==> Backend API Gateway Demo
    ############################################
    default)
        info "api-gateway: Attempting to run $ACTION for api-gateway"
        "$OC_PATH" "$ACTION" -f api-gateway/api-gateway.yaml >/dev/null 2>&1 || {
            [ "$ACTION" = apply ] && \
                err "api-gateway: Failed to $ACTION api-gateway/api-gateway.yaml!" && \
                exit
        }
        info "api-gateway: Attempting to run $ACTION for api-gateway HTTP route"
        "$OC_PATH" "$ACTION" -f api-gateway/api-gw-route.yaml >/dev/null 2>&1 || {
            [ "$ACTION" = apply ] && \
                err "api-gateway: Failed to run $ACTION api-gateway/api-gw-route.yaml!" && \
                exit
        }
        info "api-gateway: Attempting to run $ACTION for api-gateway ingress object"
        envsubst < api-gateway/ingress.yaml | "$OC_PATH" "$ACTION" -f - >/dev/null 2>&1 || {
            [ "$ACTION" = apply ] && \
                err "api-gateway: Failed to $ACTION for api-gateway/ingress.yaml!" && \
                exit
        }
        [ "$ACTION" = apply ] && print_msg "frontend app now accessible: " \
          "https://frontend.$OPENSHIFT_INGRESS_DOMAIN"
      ;;
    ##### Dashboard *==> Counting API Gateway Demo
    ##############################################
    counting-sample)
        info "api-gateway: Attempting namespace $COUNTING_SAMPLE_NS $ACTION"
        namespace "$CONTEXT" "$COUNTING_SAMPLE_NS" "$([[ $ACTION =~ apply ]] && echo "create" || echo "delete")" || {
            [ "$ACTION" = apply ] && \
                err "api-gateway: Failed to $ACTION for namespace $COUNTING_SAMPLE_NS!" && \
                exit
        }
        info "api-gateway: Attempting to run $ACTION for Network Attachment Definition to $COUNTING_SAMPLE_NS"
        "$OC_PATH" --context "$CONTEXT" "$ACTION" -f "$NETWORK_ATTACHMENT_DEF" -n "$COUNTING_SAMPLE_NS" >/dev/null 2>&1 || {
            [ "$ACTION" = apply ] && \
                err "api-gateway: Failed to $ACTION Network Attachment Definition!" && \
                exit
        }
        info "api-gateway: Attempting to run $ACTION for 'consul-tproxy-scc' in $COUNTING_SAMPLE_NS namespace"
        "$OC_PATH" --context "$CONTEXT" adm policy "$SCC_ACTION" consul-tproxy-scc system:serviceaccounts:"$COUNTING_SAMPLE_NS" >/dev/null 2>&1 || {
            [ "$ACTION" = apply ] && \
                err "api-gateway: Failed running $SCC_ACTION 'consul-tproxy-scc' to $COUNTING_SAMPLE_NS namespace" && \
                exit
        }
        info "api-gateway: Attempting to run $ACTION for counting sample demo"
        "$OC_PATH" --context "$CONTEXT" "$ACTION" -k "$COUNTING_SAMPLE_KUSTOMIZE" >/dev/null 2>&1 || {
            [ "$ACTION" = apply ] && \
                err "api-gateway: Failed to $ACTION $COUNTING_SAMPLE_KUSTOMIZE kustomization!" && \
                exit
        }
        info "api-gateway: Attempting $ACTION on api-gateway ingress object"
        envsubst < .customer/fifth-third/counting-sample-test/openshift-ingress.yaml | "$OC_PATH" --context "$CONTEXT" "$ACTION" -f - >/dev/null 2>&1 || {
            [ "$ACTION" = apply ] && \
                err "api-gateway: Failed to $ACTION api-gateway/ingress.yaml!" && \
                exit
        }
        [ "$ACTION" = apply ] && print_msg "Dashboard app now accessible: " \
          "https://dashboard.$OPENSHIFT_INGRESS_DOMAIN"
      ;;
    ##### Springboot Admin *==> Springboot Client Demo
    ##################################################
    springboot)
        for springboot_ns in $SPRINGBOOT_ADMIN_NS $SPRINGBOOT_CLIENT_NS; do
            info "api-gateway: Running $ACTION for namespace $springboot_ns"
            namespace "$CONTEXT" "$springboot_ns" "$([[ $ACTION =~ apply ]] && echo "create" || echo "delete")" || {
                err "api-gateway: Failed running $ACTION for $springboot_ns namespace!"
                exit
            }
            info "api-gateway: Attempting $ACTION on $NETWORK_ATTACHMENT_DEF in $springboot_ns"
            "$OC_PATH" --context "$CONTEXT" "$ACTION" -f "$NETWORK_ATTACHMENT_DEF" --namespace "$springboot_ns" >/dev/null 2>&1 || {
                [ "$ACTION" = apply ] && \
                    err "api-gateway: Failed to run: $OC_PATH $ACTION -f $NETWORK_ATTACHMENT_DEF --namespace $springboot_ns!" && \
                    exit
            }
        done
        info "api-gateway: Attempting $ACTION on Springboot Application API Gateway Demo"
        for file in \
            intentions \
            service-defaults \
            spring-boot-admin-server \
            spring-boot-admin-client \
            api-gateway \
            spring-boot-admin-route \
            ;
            do "$OC_PATH" --context "$CONTEXT" "$ACTION" -f "$SPRINGBOOT_DIR"/"${file}".yaml >/dev/null 2>&1 || {
                [ "$ACTION" = apply ] && \
                    err "api-gateway: Failed to deploy $SPRINGBOOT_DIR/${file}.yaml!" && \
                    exit
            }
        done
        info "api-gateway: Attempting $ACTION on api-gateway ingress object"
        envsubst < springboot/ingress.yaml | "$OC_PATH" --context "$CONTEXT" "$ACTION" -f - >/dev/null 2>&1 || {
            [ "$ACTION" = apply ] && \
                err "api-gateway: Failed to $ACTION api-gateway/ingress.yaml!" && \
                exit
        }
        [ "$ACTION" = apply ] && print_msg "Dashboard app now accessible: " "https://spring-boot-admin.$OPENSHIFT_INGRESS_DOMAIN/admin"
      ;;
    *)
        err "Unknown application: $APP"
        exit 1
      ;;
esac
[ "$ACTION" = delete ] && exit_code=0
info "api-gateway: $ACTION complete!"
    local cluster_context="$1"
    local namespace="$2"
    local action="$3"

    info "api-gateway: Running $action for $namespace namespace"
    "$OC_PATH" --context "$cluster_context" "$action" namespace "$namespace" >/dev/null 2>&1 || true
    validate_ns "$cluster_context" "$namespace" "$action" || {
        return 1
    }
    info "api-gateway: Validated $action run for namespace $namespace in $cluster_context!"
    return 0
}

case "$APP" in
    ##### Frontend *==> Backend API Gateway Demo
    ############################################
    default)
        info "api-gateway: Attempting to run $ACTION for api-gateway"
        "$OC_PATH" "$ACTION" -f api-gateway/api-gateway.yaml >/dev/null 2>&1 || {
            [ "$ACTION" = apply ] && \
                err "api-gateway: Failed to $ACTION api-gateway/api-gateway.yaml!" && \
                exit
        }
        info "api-gateway: Attempting to run $ACTION for api-gateway HTTP route"
        "$OC_PATH" "$ACTION" -f api-gateway/api-gw-route.yaml >/dev/null 2>&1 || {
            [ "$ACTION" = apply ] && \
                err "api-gateway: Failed to run $ACTION api-gateway/api-gw-route.yaml!" && \
                exit
        }
        info "api-gateway: Attempting to run $ACTION for api-gateway ingress object"
        envsubst < api-gateway/ingress.yaml | "$OC_PATH" "$ACTION" -f - >/dev/null 2>&1 || {
            [ "$ACTION" = apply ] && \
                err "api-gateway: Failed to $ACTION for api-gateway/ingress.yaml!" && \
                exit
        }
        [ "$ACTION" = apply ] && print_msg "frontend app now accessible: " \
          "https://frontend.$OPENSHIFT_INGRESS_DOMAIN"
      ;;
    ##### Dashboard *==> Counting API Gateway Demo
    ##############################################
    counting-sample)
        info "api-gateway: Attempting namespace $COUNTING_SAMPLE_NS $ACTION"
        namespace "$CONTEXT" "$COUNTING_SAMPLE_NS" "$([[ $ACTION =~ apply ]] && echo "create" || echo "delete")" || {
            [ "$ACTION" = apply ] && \
                err "api-gateway: Failed to $ACTION for namespace $COUNTING_SAMPLE_NS!" && \
                exit
        }
        info "api-gateway: Attempting to run $ACTION for Network Attachment Definition to $COUNTING_SAMPLE_NS"
        "$OC_PATH" --context "$CONTEXT" "$ACTION" -f "$NETWORK_ATTACHMENT_DEF" -n "$COUNTING_SAMPLE_NS" >/dev/null 2>&1 || {
            [ "$ACTION" = apply ] && \
                err "api-gateway: Failed to $ACTION Network Attachment Definition!" && \
                exit
        }
        info "api-gateway: Attempting to run $ACTION for 'consul-tproxy-scc' in $COUNTING_SAMPLE_NS namespace"
        "$OC_PATH" --context "$CONTEXT" adm policy "$SCC_ACTION" consul-tproxy-scc system:serviceaccounts:"$COUNTING_SAMPLE_NS" >/dev/null 2>&1 || {
            [ "$ACTION" = apply ] && \
                err "api-gateway: Failed running $SCC_ACTION 'consul-tproxy-scc' to $COUNTING_SAMPLE_NS namespace" && \
                exit
        }
        info "api-gateway: Attempting to run $ACTION for counting sample demo"
        "$OC_PATH" --context "$CONTEXT" "$ACTION" -k "$COUNTING_SAMPLE_KUSTOMIZE" >/dev/null 2>&1 || {
            [ "$ACTION" = apply ] && \
                err "api-gateway: Failed to $ACTION $COUNTING_SAMPLE_KUSTOMIZE kustomization!" && \
                exit
        }
        info "api-gateway: Attempting $ACTION on api-gateway ingress object"
        envsubst < .customer/fifth-third/counting-sample-test/openshift-ingress.yaml | "$OC_PATH" --context "$CONTEXT" "$ACTION" -f - >/dev/null 2>&1 || {
            [ "$ACTION" = apply ] && \
                err "api-gateway: Failed to $ACTION api-gateway/ingress.yaml!" && \
                exit
        }
        [ "$ACTION" = apply ] && print_msg "Dashboard app now accessible: " \
          "https://dashboard.$OPENSHIFT_INGRESS_DOMAIN"
      ;;
    ##### Springboot Admin *==> Springboot Client Demo
    ##################################################
    springboot)
        for springboot_ns in $SPRINGBOOT_ADMIN_NS $SPRINGBOOT_CLIENT_NS; do
            info "api-gateway: Running $ACTION for namespace $springboot_ns"
            namespace "$CONTEXT" "$springboot_ns" "$([[ $ACTION =~ apply ]] && echo "create" || echo "delete")" || {
                err "api-gateway: Failed running $ACTION for $springboot_ns namespace!"
                exit
            }
            info "api-gateway: Attempting $ACTION on $NETWORK_ATTACHMENT_DEF in $springboot_ns"
            "$OC_PATH" --context "$CONTEXT" "$ACTION" -f "$NETWORK_ATTACHMENT_DEF" --namespace "$springboot_ns" >/dev/null 2>&1 || {
                [ "$ACTION" = apply ] && \
                    err "api-gateway: Failed to run: $OC_PATH $ACTION -f $NETWORK_ATTACHMENT_DEF --namespace $springboot_ns!" && \
                    exit
            }
        done
        info "api-gateway: Attempting $ACTION on Springboot Application API Gateway Demo"
        for file in \
            intentions \
            service-defaults \
            spring-boot-admin-server \
            spring-boot-admin-client \
            api-gateway \
            spring-boot-admin-route \
            ;
            do "$OC_PATH" --context "$CONTEXT" "$ACTION" -f "$SPRINGBOOT_DIR"/"${file}".yaml >/dev/null 2>&1 || {
                [ "$ACTION" = apply ] && \
                    err "api-gateway: Failed to deploy $SPRINGBOOT_DIR/${file}.yaml!" && \
                    exit
            }
        done
        info "api-gateway: Attempting $ACTION on api-gateway ingress object"
        envsubst < springboot/ingress.yaml | "$OC_PATH" --context "$CONTEXT" "$ACTION" -f - >/dev/null 2>&1 || {
            [ "$ACTION" = apply ] && \
                err "api-gateway: Failed to $ACTION api-gateway/ingress.yaml!" && \
                exit
        }
        [ "$ACTION" = apply ] && print_msg "Dashboard app now accessible: " "https://spring-boot-admin.$OPENSHIFT_INGRESS_DOMAIN/admin"
      ;;
    *)
        err "Unknown application: $APP"
        exit 1
      ;;
esac
[ "$ACTION" = delete ] && exit_code=0
info "api-gateway: $ACTION complete!"