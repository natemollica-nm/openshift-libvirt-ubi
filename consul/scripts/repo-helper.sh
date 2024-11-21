#!/usr/bin/env bash

HELPER="${1:-general}"
DATACENTER="${2:-dc1}"

eval "$(cat scripts/logging.sh)"
eval "$(cat scripts/formatting.env)"

if ! [[ "$HELPER" =~ general|clean|bastion|cluster|clean-oc-tools ]]; then
    err "repo-helper: First argument must be one of general|clean|bastion|cluster|clean-oc-tools!"
    exit
fi

AWS_REGION=us-east-2
[ "$DATACENTER" = dc2 ] && AWS_REGION=us-east-1

CLUSTER_NAME="$(terraform output -json | jq -r ".cluster_name_${DATACENTER}.value")"
BASTION_DNS_NAME="$(terraform output -json | jq -r ".bastion_public_dns_${DATACENTER}.value")"

ROUTE53_HOST_ZONE="$(terraform output -json | jq -r ".route54_dns_hosted_zone_${DATACENTER}.value")"
OPENSHIFT_INGRESS_DOMAIN="apps.${CLUSTER_NAME}.${ROUTE53_HOST_ZONE}"

BASTION_SSH_CMD="ssh -A ubuntu@$BASTION_DNS_NAME"
CCOCTL_CREDENTIAL_CLEANUP="ccoctl aws delete --name=$CLUSTER_NAME --region=$AWS_REGION"
OPENSHIFT_UNINSTALL_COMMAND="openshift-install --dir=/home/ubuntu/openshift destroy cluster --log-level=debug"

general_info() {
    print_msg "Running general information gather for repository deployment:" \
        "Region:                   $AWS_REGION" \
        "Kubeconfig:               $KUBECONFIG" \
        "Bastion:                  $BASTION_DNS_NAME" \
        "Cluster Name:             $CLUSTER_NAME" \
        "OpenShift Version:        $OPENSHIFT_VERSION" \
        "OpenShift Ingress Domain: $OPENSHIFT_INGRESS_DOMAIN"
}

cleanup_tasks() {
    print_msg "OpenShift Cleanup Tasks -- ($DATACENTER) Perform the following OpenShift cleanup tasks in order (wait for completion on each):" \
        "SSH to Bastion:   $BASTION_SSH_CMD" \
        "From Bastion run: $OPENSHIFT_UNINSTALL_COMMAND" \
        "From Bastion run: $CCOCTL_CREDENTIAL_CLEANUP"
}

clean_oc_tooling() {
    print_msg "clean: Cleaning up (removing) 'openshift/' directory OpenShift tooling:" \
        "openshift/$DATACENTER/kubeconfig (Kubeconfig)" \
        "openshift/$DATACENTER/kubeadmin-password" \
        "openshift/openshift-install" \
        "openshift/kubeconfig" \
        "openshift/kubectl" \
        "openshift/oc"
    local f
    for f in \
          openshift/"${DATACENTER}" \
          openshift/openshift-install \
          openshift/kubeconfig \
          openshift/kubectl \
          openshift/oc; do
        info "clean: Removing $f"
        rm -rf "$f" >/dev/null 2>&1 || true
    done
    info "clean: OpenShift tooling cleanup complete!"
}


case "$HELPER" in
    general)
        general_info
    ;;
    clean)
        cleanup_tasks
    ;;
    bastion)
        print_msg "Gathering Bastion hostname" \
            "Bastion: $BASTION_DNS_NAME"
    ;;
    cluster)
        print_msg "Gathering Cluster info" \
              "Cluster Name:      $CLUSTER_NAME" \
              "OpenShift Version: $OPENSHIFT_VERSION"
    ;;
    clean-oc-tools)
        clean_oc_tooling
    ;;
    *)
        general_info
    ;;
esac

