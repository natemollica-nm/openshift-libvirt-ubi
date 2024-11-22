#!/usr/bin/env bash

eval "$(cat ../env)"
eval "$(cat scripts/logging.sh)"
eval "$(cat scripts/formatting.env)"
contexts=$(oc config get-contexts --no-headers --output=name)

# Check if we got any contexts back
if [[ -z "$contexts" ]]; then
    info "kube-contexts: no contexts found | KUBECONFIG=$KUBECONFIG"
    exit 0
fi

# Loop through each context
for context in $contexts; do
    # Prompt user for confirmation
    prompt "kube-contexts: delete context $context? (y/n): "
    read -r -t 10 answer </dev/tty >/dev/null 2>&1 || answer=y && echo # Check if the answer is 'y' or 'Y', or if the timeout was reached

    if [[ "$answer" =~ Y|y|yes ]]; then
        # Delete the context
        oc config delete-context "$context" >/dev/null 2>&1 || true
        oc config delete-cluster "$context" >/dev/null 2>&1 || true
        oc config delete-user "$context" >/dev/null 2>&1 || true
        info "kube-contexts: context $context deleted!"
    else
        info "kube-contexts: skipping removal for $context"
    fi
done
info "kube-contexts: done!"
