#!/bin/bash

set -e

delete_namespace_crds() {
  local namespace=$1

  if [ -z "$namespace" ]; then
    echo "Usage: delete_namespace_crds <namespace>"
    return 1
  fi

  echo "Checking for CRDs associated with namespace: $namespace"

  # Get all CRDs
  local crds
  mapfile -t crds < <(kubectl get crds -o json | jq -r '.items[].metadata.name')

  if [ "${#crds[@]}" -le 0 ]; then
    echo "No CRDs found in the cluster."
    return 0
  fi

  # Iterate over CRDs to find and delete those referencing the namespace
  local crd
  for crd in "${crds[@]}"; do
    echo -n "  ====> CRD $crd count: "

    # Check if the CRD has resources in the namespace
    local resources
    mapfile -t resources < <(kubectl get "$crd" -n "$namespace" --ignore-not-found -o name)

    if [ "${#resources[@]}" -gt 0 ]; then
      echo "${#resources[@]}"

      # Delete each resource in the namespace
      for resource in "${resources[@]}"; do
        echo -n "  ==> Deleting $resource: "
        kubectl delete "$resource" -n "$namespace" --ignore-not-found --wait=false >/dev/null 2>&1 && echo "OK" || echo "FAILED"
      done
    else
      echo "NONE"
    fi
  done

  echo "Completed cleanup of CRD resources in namespace: $namespace"
}

NAMESPACE=$1

if [ -z "$NAMESPACE" ]; then
  echo "Usage: $0 <namespace>"
  exit 1
fi

# Check if the namespace exists
if ! oc get namespace "$NAMESPACE" >/dev/null 2>&1; then
  echo "Error: Namespace '$NAMESPACE' does not exist."
  exit 1
fi

echo "Removing all lingering resources in namespace: $NAMESPACE"

# Get all namespaced resources
mapfile -t resources < <(oc api-resources --verbs=list --namespaced -o name)

# Iterate through each resource type and delete all instances
for resource in "${resources[@]}"; do
  echo -n "Resource count ($resource): "

  # Use mapfile to split command output into an array
  mapfile -t items < <(oc get "$resource" -n "$NAMESPACE" --ignore-not-found -o name)

  if [ "${#items[@]}" -gt 0 ]; then
      echo " ${#items[@]}"
      # Iterate through the items array
      for item in "${items[@]}"; do
          if [[ "${item}" =~ packagemanifest.packages.operators.coreos.com ]]; then
              continue
          fi
          echo -n "  ==> Deleting resource $item: "
          oc delete "$item" -n "$NAMESPACE" --ignore-not-found --wait=false >/dev/null 2>&1 && echo "OK" || echo "FAILED"
      done
  else
    echo "None"
  fi
done

delete_namespace_crds "${NAMESPACE}"

echo "Completed cleanup of lingering resources in namespace: $NAMESPACE"
