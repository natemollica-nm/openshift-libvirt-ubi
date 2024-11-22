#!/usr/bin/env bash

eval "$(cat scripts/logging.sh)"
eval "$(cat scripts/formatting.env)"

SERVICE="${1:-frontend}"
SINGLE_CLUSTER=${2:-false}

CLUSTER_CONTEXTS=("$CLUSTER1_CONTEXT" "$CLUSTER2_CONTEXT")
if [ "$SINGLE_CLUSTER" = true ]; then
    CLUSTER_CONTEXTS=("$CLUSTER1_CONTEXT")
fi

# SECRET_NAME to create in the Kubernetes secrets store.
# TMPDIR is a temporary working directory.
# CSR_NAME will be the name of our certificate signing request as seen by Kubernetes.

TMPDIR=tgw/certs/${SERVICE}
CSR_CONF=${TMPDIR}/csr.conf
CERT_KEY=${TMPDIR}/${SERVICE}.key

CSR_NAME=${SERVICE}-csr
SECRET_NAME=${SERVICE}-server-cert

test -d "$TMPDIR" || {
    info "tls-cert-create: Creating $TMPDIR"
    mkdir -p "$TMPDIR"
}
rm -rf "${TMPDIR:?}"/*
################################################################################################################
# Vault mTLS CLuster TLS Certificate Generation - CA: K8s
################################################################################################################
# Create private key
info "tls-cert-create: Creating ${SERVICE} server tls key"
openssl genrsa -out "$CERT_KEY" 2048 >/dev/null 2>&1 || {
    err "tls-cert-create: Failed to create $CERT_KEY!"
    exit
} # -days 3651
chmod 400 "$CERT_KEY"

# Create a file ${TMPDIR}/${NS}-csr.conf with the following contents
info "tls-cert-create: Creating ${SERVICE} server CSR"
( cat <<-EOF
[ req ]
req_extensions = v3_req
distinguished_name = req_distinguished_name
[ req_distinguished_name ]
[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names
[alt_names]
DNS.1  = ${SERVICE}
DNS.2  = ${SERVICE}.consul
DNS.3  = ${SERVICE}.consul.svc
DNS.4  = ${SERVICE}.consul.svc.cluster.local
DNS.5  = localhost
DNS.6  = host.docker.internal
IP.1   = 127.0.0.1
EOF
) >"${CSR_CONF}"

# Create a CSR
info "tls-cert-create: Generating Kubernetes server.csr (openssl)"
openssl req \
    -new \
    -key "$CERT_KEY" \
    -subj "/O=system:nodes/CN=system:node:${SERVICE}.consul.svc" \
    -out "${TMPDIR}/server.csr" \
    -config "${CSR_CONF}" \
    >/dev/null 2>&1 || {
        err "tls-cert-create: Failed to create $TMPDIR/server.csr"
        exit
    }
    
chmod 400 "${TMPDIR}/server.csr"

# Create a file ${TMPDIR}/${BASENAME}.yaml with the following contents : see https://github.com/hashicorp/vault/blob/main/website/content/docs/platform/k8s/helm/examples/standalone-tls.mdx
info "tls-cert-create: Creating Kubernetes API signing request"
( cat <<-EOF
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: "$CSR_NAME"
spec:
  groups:
  - system:authenticated
  request: $( cat "${TMPDIR}/server.csr" | base64 | tr -d '\r\n' )
  signerName: kubernetes.io/kubelet-serving
  usages:
  - digital signature
  - key encipherment
  - server auth
EOF
) > "${TMPDIR}/csr.yaml"

# Delete CSR and secret if exist
for cluster_context in "${CLUSTER_CONTEXTS[@]}"; do
    info "tls-cert-create: Clearing previous $CSR_NAME and $SECRET_NAME Kubernetes secrets (if present) | $cluster_context"
    kubectl --context "${cluster_context}" delete csr "${CSR_NAME}" --namespace "${NS}" >/dev/null 2>&1 || true || true
    kubectl --context "${cluster_context}" delete secret "${SECRET_NAME}" --namespace "${NS}" >/dev/null 2>&1 || true || true
    kubectl --context "${cluster_context}" delete csr "${CSR_NAME}" --namespace consul >/dev/null 2>&1 || true || true
    kubectl --context "${cluster_context}" delete secret "${SECRET_NAME}" --namespace consul >/dev/null 2>&1 || true || true

    # Send the CSR to Kubernetes.
    info "tls-cert-create: Submitting Kubernetes Signing Request | $cluster_context"
    kubectl --context "${cluster_context}" create -f "${TMPDIR}/csr.yaml" >/dev/null 2>&1 || {
        err "tls-cert-create: Failed to create Kubernetes CSR ($TMPDIR/csr.yaml)!"
        exit
    }
    sleep 2
    
    # Approve the CSR in Kubernetes
    info "tls-cert-create: Requesting approval from Kubernetes API | $cluster_context"
    kubectl --context "${cluster_context}" certificate approve "${CSR_NAME}" >/dev/null 2>&1 || {
        err "tls-cert-create: Failed to approve $CSR_NAME!"
        exit
    }
    sleep 5
    kubectl --context "${cluster_context}" get csr "${CSR_NAME}"
    
    serverCert=$(kubectl --context "${cluster_context}" get csr "${CSR_NAME}" -o jsonpath='{.status.certificate}')
    echo "$serverCert" | openssl base64 -d -A -out "${TMPDIR}/${SERVICE}.crt"
    
    
    kubectl --context "${cluster_context}" config view --raw --minify --flatten -o jsonpath='{.clusters[].cluster.certificate-authority-data}' | base64 -d > "${TMPDIR}/kube-root.ca"
    kubectl --context "${cluster_context}" create secret tls "${SECRET_NAME}" \
        --namespace=default \
        --key="$CERT_KEY" \
        --cert="${TMPDIR}/${SERVICE}.crt" >/dev/null 2>&1 || {
            err "tls-cert-create: Failed to create 'default' namespace $SECRET_NAME! | $cluster_context"
            exit
        }
    # Needed for Consul K8s Namespace CA Designation - secretsBackend.vault.ca
    kubectl --context "${cluster_context}" create secret tls "${SECRET_NAME}" \
        --namespace=consul \
        --key="$CERT_KEY" \
        --cert="${TMPDIR}/${SERVICE}.crt" >/dev/null 2>&1 || {
            err "tls-cert-create: Failed to create 'default' namespace $SECRET_NAME! | $cluster_context"
            exit
        }
    
done
# Read secret
# kubectl --context "${cluster_context}" get secret ${SECRET_NAME} --namespace="${NS}" -o jsonpath="{.data}" && echo
# kubectl --context "${cluster_context}" get secret ${SECRET_NAME} --namespace="${NS}" -o jsonpath='{.data.vault\.crt}' | base64 -d
unset TMPDIR
info "tls-cert-create: Done!"