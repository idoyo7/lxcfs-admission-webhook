#!/usr/bin/env bash

set -eo pipefail

usage() {
  cat <<EOF
usage: ${0} [options]

Install the LXCFS admission webhook and DaemonSet using cert-manager
to issue and inject the webhook serving certificate.

Required:
  cert-manager v1.x must already be installed in the cluster
  (https://cert-manager.io/docs/installation/).

Options:
  --namespace         namespace to install into (default: lxcfs)
  --deployment        webhook deployment name (default: lxcfs-admission-webhook)
  --service           webhook service name (default: lxcfs-admission-webhook)
  --secret            Secret name cert-manager writes the cert into
                      (default: lxcfs-admission-webhook)
  --daemonset         LXCFS DaemonSet name (default: lxcfs-ds)
  --mutating          MutatingWebhookConfiguration name
                      (default: lxcfs-admission-webhook)
  --wh-image          webhook image
                      (default: ghcr.io/idoyo7/lxcfs-admission-webhook:latest)
  --lxcfs-image       lxcfs image
                      (default: ghcr.io/idoyo7/lxcfs:6.0.1-r0)

  --create-cert-only  generate a self-signed test cert in ./certs using
                      openssl (used by 'make test'; not the production
                      install path)
EOF
}

pre_check() {
  if ! command -v kubectl >/dev/null; then
    echo "kubectl not found in PATH" >&2
    exit 1
  fi
  if ! kubectl cluster-info >/dev/null 2>&1; then
    echo "Can't reach the Kubernetes control plane" >&2
    exit 101
  fi
  if ! kubectl get crd certificates.cert-manager.io >/dev/null 2>&1; then
    cat >&2 <<EOF
cert-manager CRDs not found.
Install cert-manager v1.x first, e.g.:
  kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
EOF
    exit 102
  fi
  if ! command -v envsubst >/dev/null; then
    echo "envsubst not found in PATH (install gettext)" >&2
    exit 1
  fi
}

apply_template() {
  local file=$1
  local namespaced=${2:-true}
  if [[ "$namespaced" == "true" ]]; then
    envsubst <"$PWD/$file" \
      | kubectl create -n "${NAMESPACE}" -o yaml --dry-run=client -f - \
      | kubectl -n "${NAMESPACE}" apply -f -
  else
    envsubst <"$PWD/$file" \
      | kubectl create -o yaml --dry-run=client -f - \
      | kubectl apply -f -
  fi
}

create_k8s_resources() {
  export NAMESPACE WH_DEP WH_SVC WH_SECRET MUTATING_WH_CONFIG LXCFS_DS \
         WH_IMAGE LXCFS_IMAGE

  kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1 \
    || kubectl create namespace "${NAMESPACE}"

  # 1. cert-manager Issuer + Certificate (produces the webhook Secret).
  apply_template certificate.tpl.yaml

  # 2. LXCFS DaemonSet.
  apply_template lxcfs-daemonset.tpl.yaml

  # 3. Webhook Deployment + Service.
  apply_template deployment.tpl.yaml
  apply_template service.tpl.yaml

  # 4. Wait until cert-manager has issued the serving cert; otherwise the
  #    webhook pod will crash-loop on missing tls.crt.
  echo "Waiting for cert-manager to issue ${WH_SECRET}..."
  kubectl -n "${NAMESPACE}" wait --for=condition=Ready \
    "certificate.cert-manager.io/${WH_DEP}" --timeout=120s

  # 5. MutatingWebhookConfiguration (caBundle is injected by cert-manager
  #    via the cert-manager.io/inject-ca-from annotation).
  apply_template mutatingwebhook.tpl.yaml false
}

create_self_signed_cert() {
  echo "Creating test certs in directory: ${CERT_DIR}"
  local BITS=${BITS:-2048}
  local DAYS=${DAYS:-10950}
  cat <<EOF >"${CERT_DIR}"/csr.conf
[ req ]
default_bits = ${BITS}
prompt = no
default_md = sha256
req_extensions = req_ext
distinguished_name = dn

[ dn ]
CN = ${WH_SVC}.${NAMESPACE}.svc

[ req_ext ]
subjectAltName = @alt_names

[alt_names]
DNS.1 = ${WH_SVC}
DNS.2 = ${WH_SVC}.${NAMESPACE}
DNS.3 = ${WH_SVC}.${NAMESPACE}.svc
DNS.4 = ${WH_SVC}.${NAMESPACE}.svc.cluster
DNS.5 = ${WH_SVC}.${NAMESPACE}.svc.cluster.local

[ v3_ext ]
authorityKeyIdentifier = keyid,issuer:always
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = @alt_names
EOF

  openssl genrsa -out "${CERT_DIR}/ca-key.pem" "${BITS}"
  openssl req -x509 -new -nodes -days "${DAYS}" -key "${CERT_DIR}/ca-key.pem" \
    -subj "/CN=lxcfs-admission-webhook-test-ca" -out "${CERT_DIR}/ca-cert.pem"
  openssl genrsa -out "${CERT_DIR}/server-key.pem" "${BITS}"
  openssl req -new -key "${CERT_DIR}/server-key.pem" -config "${CERT_DIR}/csr.conf" \
    -out "${CERT_DIR}/server.csr"
  openssl x509 -req -in "${CERT_DIR}/server.csr" -CA "${CERT_DIR}/ca-cert.pem" \
    -CAkey "${CERT_DIR}/ca-key.pem" -CAcreateserial -days "${DAYS}" \
    -extensions v3_ext -extfile "${CERT_DIR}/csr.conf" \
    -out "${CERT_DIR}/server-cert.pem"
}

main() {
  NAMESPACE=lxcfs
  WH_DEP=lxcfs-admission-webhook
  WH_SVC=lxcfs-admission-webhook
  WH_SECRET=lxcfs-admission-webhook
  MUTATING_WH_CONFIG=lxcfs-admission-webhook
  LXCFS_DS=lxcfs-ds
  CREATE_CERT_ONLY=false

  : "${WH_IMAGE:=ghcr.io/idoyo7/lxcfs-admission-webhook:latest}"
  : "${LXCFS_IMAGE:=ghcr.io/idoyo7/lxcfs:6.0.1-r0}"

  while [[ $# -gt 0 ]]; do
    case $1 in
      --namespace)        NAMESPACE=$2; shift 2 ;;
      --deployment)       WH_DEP=$2; shift 2 ;;
      --service)          WH_SVC=$2; shift 2 ;;
      --secret)           WH_SECRET=$2; shift 2 ;;
      --mutating)         MUTATING_WH_CONFIG=$2; shift 2 ;;
      --daemonset)        LXCFS_DS=$2; shift 2 ;;
      --wh-image)         WH_IMAGE=$2; shift 2 ;;
      --lxcfs-image)      LXCFS_IMAGE=$2; shift 2 ;;
      --create-cert-only) CREATE_CERT_ONLY=true; shift ;;
      -h|--help)          usage; exit 0 ;;
      *) echo "unknown parameter: $1" >&2; usage; exit 22 ;;
    esac
  done

  if [[ "${CREATE_CERT_ONLY}" == true ]]; then
    CERT_DIR="${PWD}/certs"
    mkdir -p "${CERT_DIR}"
    create_self_signed_cert
    exit 0
  fi

  pre_check

  cat <<EOF
Installing in namespace: ${NAMESPACE}
  webhook deployment:    ${WH_DEP}
  webhook service:       ${WH_SVC}
  webhook secret:        ${WH_SECRET} (managed by cert-manager)
  lxcfs daemonset:       ${LXCFS_DS}
  mutating config:       ${MUTATING_WH_CONFIG}
  webhook image:         ${WH_IMAGE}
  lxcfs image:           ${LXCFS_IMAGE}
EOF

  create_k8s_resources
}

main "$@"
