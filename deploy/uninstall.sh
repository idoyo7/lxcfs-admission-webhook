#!/usr/bin/env bash

set -eo pipefail

usage() {
  cat <<EOF
Uninstall the LXCFS admission webhook and DaemonSet.

usage: ${0} [options]

Options:
  --namespace         namespace the resources live in (default: lxcfs)
  --deployment        webhook deployment name (default: lxcfs-admission-webhook)
  --service           webhook service name (default: lxcfs-admission-webhook)
  --secret            cert-manager-managed Secret name
                      (default: lxcfs-admission-webhook)
  --daemonset         LXCFS DaemonSet name (default: lxcfs-ds)
  --mutating          MutatingWebhookConfiguration name
                      (default: lxcfs-admission-webhook)
EOF
}

pre_check() {
  if ! command -v kubectl >/dev/null; then
    echo "kubectl not found in PATH" >&2
    exit 1
  fi
  if ! kubectl cluster-info >/dev/null 2>&1; then
    echo "Can't reach the Kubernetes control plane" >&2
    exit 1
  fi
  if ! kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
    echo "namespace '${NAMESPACE}' does not exist; nothing to do" >&2
    exit 0
  fi
}

uninstall() {
  cat <<EOF
Deleting from namespace: ${NAMESPACE}
  mutating webhook configuration: ${MUTATING_WH_CONFIG}
  webhook deployment:             ${WH_DEP}
  webhook service:                ${WH_SVC}
  cert-manager Certificate:       ${WH_DEP}, ${WH_DEP}-ca
  cert-manager Issuer:            ${WH_DEP}-ca-issuer, ${WH_DEP}-selfsigned
  Secrets:                        ${WH_SECRET}, ${WH_DEP}-ca
  lxcfs daemonset:                ${LXCFS_DS}
EOF

  kubectl delete --ignore-not-found mutatingwebhookconfiguration "${MUTATING_WH_CONFIG}"
  kubectl delete --ignore-not-found -n "${NAMESPACE}" service "${WH_SVC}"
  kubectl delete --ignore-not-found -n "${NAMESPACE}" deployment "${WH_DEP}"
  # Delete cert-manager resources before the secrets they own.
  kubectl delete --ignore-not-found -n "${NAMESPACE}" certificate.cert-manager.io "${WH_DEP}" "${WH_DEP}-ca"
  kubectl delete --ignore-not-found -n "${NAMESPACE}" issuer.cert-manager.io "${WH_DEP}-ca-issuer" "${WH_DEP}-selfsigned"
  kubectl delete --ignore-not-found -n "${NAMESPACE}" secret "${WH_SECRET}" "${WH_DEP}-ca"
  kubectl delete --ignore-not-found -n "${NAMESPACE}" daemonset "${LXCFS_DS}"
}

main() {
  NAMESPACE=lxcfs
  WH_DEP=lxcfs-admission-webhook
  WH_SVC=lxcfs-admission-webhook
  WH_SECRET=lxcfs-admission-webhook
  MUTATING_WH_CONFIG=lxcfs-admission-webhook
  LXCFS_DS=lxcfs-ds

  while [[ $# -gt 0 ]]; do
    case $1 in
      --namespace)  NAMESPACE=$2; shift 2 ;;
      --deployment) WH_DEP=$2; shift 2 ;;
      --service)    WH_SVC=$2; shift 2 ;;
      --secret)     WH_SECRET=$2; shift 2 ;;
      --mutating)   MUTATING_WH_CONFIG=$2; shift 2 ;;
      --daemonset)  LXCFS_DS=$2; shift 2 ;;
      -h|--help)    usage; exit 0 ;;
      *) echo "unknown parameter: $1" >&2; usage; exit 22 ;;
    esac
  done

  pre_check
  uninstall
}

main "$@"
