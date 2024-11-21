#!/bin/bash

export BOOTSTRAP_TOKEN CONSUL_API TOKEN_HEADER

CONSUL_API=https://localhost:8501

BOOTSTRAP_TOKEN="$(openshift/oc get secret --context "$CLUSTER1_CONTEXT" --namespace "$CONSUL_NS" consul-bootstrap-acl-token -o yaml | yq -r '.data.token' | base64 -d)"
if [ -z "$BOOTSTRAP_TOKEN" ]; then
  echo "failed to retrieve bootstrap token"
  exit 1
fi

TOKEN_HEADER="X-Consul-Token: $BOOTSTRAP_TOKEN"

function consulServerExec() {
  openshift/oc exec --namespace "$CONSUL_NS" -it statefulset/consul-server -c consul -- /bin/sh -c "$*"
}

function getConsulNamespaces() {
  consulServerExec curl -sk -H "${TOKEN_HEADER}" "${CONSUL_API}/v1/namespaces" | jq -r '[.[] | .Name] | join (" ")'
}

getConsulCatalogNodes() {
  local namespace="${1:-"${CONSUL_NS}"}"
  local nodes
  # In Zsh, consider avoiding complex inline expansions if they cause issues.
  # Direct use of headers in the command line call.
  #
  nodes=$(consulServerExec curl -sk -H "${TOKEN_HEADER}" -H "X-Consul-Namespace: ${namespace}" "${CONSUL_API}/v1/catalog/nodes")
  echo "$nodes"
}

getConsulNodeServices() {
  local namespace="${1:-"*"}"
  local node service service_instances
  local ns namespaces

  for node in $(getConsulCatalogNodes "$namespace" | jq -r '[ .[].Node ]| join (" ")'); do
    # Skip consul server nodes
    if echo "$node" | grep -q ".*consul-server.*"; then
        continue
    fi
    printf '%s\n' "Node: $node | Namespace: $( [ "$namespace" = "*" ] && echo "all" || echo "$namespace" )"
    if [ "$namespace" = "*" ]; then
      # shellcheck disable=2207
      namespaces=($(getConsulNamespaces))
      for ns in "${namespaces[@]}"; do
        # shellcheck disable=2207
        service_instances=($(consulServerExec curl -sk -H "${TOKEN_HEADER}" "${CONSUL_API}/v1/catalog/node-services/${node}?ns=$ns" | jq -r 'try ([.Services[] | select(. != null ) | .Service] | join (" ")) catch "<none>"'))
        for service in "${service_instances[@]}"; do
          printf '%s\n' \
            "    >- $service (ns: $ns)"
        done
      done
    else
      # shellcheck disable=2207
      service_instances=($(consulServerExec curl -sk -H "${TOKEN_HEADER}" "${CONSUL_API}/v1/catalog/node-services/${node}?ns=$namespace" | jq -r 'try ([.Services[] | select(. != null ) | .Service] | join (" ")) catch "<none>"'))
      for service in "${service_instances[@]}"; do
        printf '%s\n' \
          "    >- $service"
      done
    fi
  done
}