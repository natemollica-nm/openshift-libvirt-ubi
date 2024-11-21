#!/bin/bash

set -e

export CTX="${1:-"$CLUSTER1_CONTEXT"}"

# https://docs.openshift.com/container-platform/4.14/networking/dns-operator.html#nw-dns-forward_dns-operator

configureCoreDNS() {
  local DNS_IP CONSUL_DNS_FWDR coreDNSConfigMap

  echo "consul-core-dns: retrieving consul-dns clusterIP | ${CTX}" # 172.30.107.79
  DNS_IP=$(openshift/oc --kubeconfig openshift/kubeconfig --context "${CTX}" get svc consul-dns --namespace "$CONSUL_NS" --output jsonpath='{.spec.clusterIP}')
  export CONSUL_DNS_FWDR="$(cat <<-EOF

# consul-server
consul:5353 {
    prometheus 127.0.0.1:9153
    forward . $DNS_IP:53 {
        policy random
    }
    errors
    log . {
        class error
    }
    bufsize 1232
    cache 900 {
        denial 9984 30
    }
}
EOF
)"
  echo "consul-core-dns: appending consul forwarder to Corefile settings | ${CTX}"
  coreDNSConfigMap="$(openshift/oc --kubeconfig openshift/kubeconfig --context "${CTX}" get configmaps --namespace openshift-dns dns-default --output yaml | yq '.data.Corefile += strenv(CONSUL_DNS_FWDR)')"

  echo "consul-core-dns: applying updated coredns configmap: ${DNS_IP}"
  echo "$coreDNSConfigMap" | openshift/oc --kubeconfig openshift/kubeconfig --context "${CTX}" apply -f -
}

configureCoreDNS