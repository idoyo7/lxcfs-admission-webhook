# lxcfs-admission-webhook

[![Go](https://github.com/idoyo7/lxcfs-admission-webhook/actions/workflows/go.yml/badge.svg)](https://github.com/idoyo7/lxcfs-admission-webhook/actions/workflows/go.yml)
[![Publish images](https://github.com/idoyo7/lxcfs-admission-webhook/actions/workflows/docker-publish.yml/badge.svg)](https://github.com/idoyo7/lxcfs-admission-webhook/actions/workflows/docker-publish.yml)
[![License](https://img.shields.io/github/license/idoyo7/lxcfs-admission-webhook)](LICENSE)

**English** · [한국어](README.ko.md)

> Automatically mount [LXCFS](https://linuxcontainers.org/lxcfs/introduction/)-virtualized `/proc` and `/sys` files into Kubernetes Pods, so containerized runtimes see cgroup-aware CPU and memory values instead of host-wide resources.

`lxcfs-admission-webhook` is a Kubernetes `MutatingAdmissionWebhook` plus an LXCFS DaemonSet. Opt a namespace in with one label, and newly created Pods are patched with the LXCFS mounts they need for more accurate runtime sizing.

This repository is a maintained fork of [`ymping/lxcfs-admission-webhook`](https://github.com/ymping/lxcfs-admission-webhook), updated for LXCFS 6.x, modern Kubernetes libraries, cert-manager-managed serving certificates, GHCR images, and an OCI Helm chart.

---

## Why this exists

Many tools and runtimes still inspect files such as `/proc/cpuinfo`, `/proc/meminfo`, and `/proc/stat` to decide how much CPU or memory they can use. In containers, those files may expose the node's host-level values rather than the Pod's cgroup limits.

That can lead to oversized heaps, inflated worker pools, noisy metrics, or surprising OOMKills. LXCFS provides container-aware virtual views of those files; this webhook makes the required Pod mounts automatic.

Common beneficiaries include:

- **JVM** workloads using `Runtime.availableProcessors()`, GC worker sizing, or memory percentage flags.
- **Node.js** services using `os.cpus()` or cluster worker counts.
- **Go** applications relying on `runtime.NumCPU()` and `GOMAXPROCS` behavior.
- **Python / Ruby** workloads using standard CPU-count helpers.
- Shell tooling such as `nproc`, `free`, `top`, and similar diagnostics.

---

## Features

- **Namespace opt-in**: only mutate Pods in namespaces labeled `lxcfs-admission-webhook=enabled`.
- **Pod opt-out**: skip individual Pods with `mutating.lxcfs-admission-webhook.io/enable: "false"`.
- **Safe mutation**: detects existing `lxcfs` volumes or mount-path conflicts and marks the Pod as `conflict` instead of overwriting user configuration.
- **Status annotation**: records `mutated`, `skip`, or `conflict` on each handled Pod.
- **cert-manager integration**: serving certificates and CA bundle injection are managed by cert-manager.
- **Multiple install paths**: OCI Helm chart, Argo CD examples, and a lightweight `install.sh` flow.
- **Published artifacts**: webhook and LXCFS images are built for GHCR; chart releases are published as OCI artifacts.

---

## How it works

```text
┌──────────────────────┐       AdmissionReview        ┌──────────────────────────┐
│ Kubernetes API server │ ───────────────────────────▶ │ lxcfs-admission-webhook  │
│                      │ ◀──────── JSON Patch ─────── │ Deployment :8443         │
└──────────┬───────────┘                              └───────────┬──────────────┘
           │                                                      │
           │ patched Pod spec                                     │ TLS certs via
           ▼                                                      │ cert-manager
┌──────────────────────┐                              ┌───────────▼──────────────┐
│ Application Pod       │ read-only bind mounts        │ LXCFS DaemonSet          │
│ /proc/* and /sys/*    │ ◀─────────────────────────── │ /var/lib/lxc/lxcfs       │
└──────────────────────┘                              └──────────────────────────┘
```

On Pod `CREATE`, the webhook injects a hostPath volume from `/var/lib/lxc/` and read-only mounts for these LXCFS-backed paths:

| Path | Purpose |
|---|---|
| `/proc/cpuinfo` | CPU topology visible to runtimes |
| `/proc/meminfo` | memory limit-aware values |
| `/proc/stat` | CPU/statistics view |
| `/proc/uptime` | container-aware uptime view |
| `/proc/loadavg` | load average view |
| `/proc/diskstats` | disk statistics view |
| `/proc/swaps` | swap information view |
| `/sys/devices/system/cpu/online` | online CPU set |
| `/var/lib/lxc/` | host LXCFS source, mounted with `HostToContainer` propagation |

The webhook also skips `kube-system` and `kube-public` in code, and the default webhook failure policy is `Ignore`.

---

## Quick start

### Prerequisites

- Kubernetes with `admissionregistration.k8s.io/v1` support.
- [cert-manager](https://cert-manager.io/) installed in the cluster.
- Linux nodes capable of running LXCFS/FUSE.
- `kubectl` for all install methods.
- `helm` 3.8+ for the OCI chart install.
- `envsubst` from `gettext` if using `deploy/install.sh`.

Install cert-manager if your cluster does not already have it:

```sh
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
kubectl -n cert-manager wait --for=condition=Available deployment --all --timeout=120s
```

### Install with Helm

```sh
helm install lxcfs-admission-webhook \
  oci://ghcr.io/idoyo7/charts/lxcfs-admission-webhook \
  --version 0.2.1 \
  --namespace lxcfs \
  --create-namespace
```

Customize with `--set` or a values file. See [`charts/lxcfs-admission-webhook/values.yaml`](charts/lxcfs-admission-webhook/values.yaml) for the available options.

### Install with Argo CD

Use one of the examples in [`examples/argocd`](examples/argocd):

- [`application-oci.yaml`](examples/argocd/application-oci.yaml) pulls the chart from GHCR.
- [`application-git.yaml`](examples/argocd/application-git.yaml) deploys directly from this repository's chart path.

See [`examples/argocd/README.md`](examples/argocd/README.md) for GitOps notes, sync options, and CA bundle drift handling.

### Install without Helm

```sh
git clone https://github.com/idoyo7/lxcfs-admission-webhook.git
cd lxcfs-admission-webhook/deploy
./install.sh
```

Useful overrides:

| Flag / env | Default |
|---|---|
| `--namespace` | `lxcfs` |
| `--deployment` | `lxcfs-admission-webhook` |
| `--service` | `lxcfs-admission-webhook` |
| `--secret` | `lxcfs-admission-webhook` |
| `--daemonset` | `lxcfs-ds` |
| `--mutating` | `lxcfs-admission-webhook` |
| `--wh-image` / `WH_IMAGE` | `ghcr.io/idoyo7/lxcfs-admission-webhook:latest` |
| `--lxcfs-image` / `LXCFS_IMAGE` | `ghcr.io/idoyo7/lxcfs:6.0.1-r0` |

---

## Usage

Opt a namespace in:

```sh
kubectl label namespace your-namespace lxcfs-admission-webhook=enabled
```

Only Pods created after the label is applied are mutated. Restart or redeploy existing workloads if they should receive LXCFS mounts.

Opt a single Pod out:

```yaml
metadata:
  annotations:
    mutating.lxcfs-admission-webhook.io/enable: "false"
```

Check the webhook decision:

```sh
kubectl get pod <pod> \
  -o jsonpath='{.metadata.annotations.mutating\.lxcfs-admission-webhook\.io/status}'
```

Possible values:

| Status | Meaning |
|---|---|
| `mutated` | LXCFS volumes and mounts were injected. |
| `skip` | The Pod was intentionally skipped. |
| `conflict` | Existing volumes or mounts conflicted with the LXCFS injection. |

---

## Verify the result

Run a limited Pod in an opted-in namespace and compare what it sees from `/proc`:

```sh
kubectl label namespace default lxcfs-admission-webhook=enabled --overwrite

kubectl run lxcfs-check --rm -it --restart=Never \
  --image=alpine:3.21 \
  --limits=cpu=1,memory=1Gi \
  -- sh -c 'echo "nproc: $(nproc)"; head -3 /proc/meminfo; grep -c ^processor /proc/cpuinfo'
```

For a Pod limited to one CPU and 1 GiB memory, `nproc` should report `1`, and `MemTotal` should be close to `1048576 kB`.

> Note: LXCFS virtualizes many resource-reporting files, but not every possible kernel counter. Some usage-oriented tools may still expose host-derived values depending on cgroup mode and kernel behavior.

---

## Configuration highlights

The Helm chart exposes the main operational knobs under [`values.yaml`](charts/lxcfs-admission-webhook/values.yaml):

| Value | Default |
|---|---|
| `webhook.image.repository` | `ghcr.io/idoyo7/lxcfs-admission-webhook` |
| `webhook.replicas` | `2` |
| `webhook.port` | `8443` |
| `lxcfs.image.repository` | `ghcr.io/idoyo7/lxcfs` |
| `lxcfs.image.tag` | `6.0.1-r0` |
| `lxcfs.hostPath` | `/var/lib/lxc` |
| `mutatingWebhook.namespaceSelector.matchLabels.lxcfs-admission-webhook` | `enabled` |
| `mutatingWebhook.timeoutSeconds` | `5` |
| `mutatingWebhook.reinvocationPolicy` | `Never` |

The raw manifest installer uses cert-manager resources from [`deploy/certificate.tpl.yaml`](deploy/certificate.tpl.yaml). The Helm chart has its own certificate defaults in [`charts/lxcfs-admission-webhook/values.yaml`](charts/lxcfs-admission-webhook/values.yaml), so prefer one installation path per cluster and manage it consistently.

---

## Development

```sh
make build          # build ./build/lxcfs-admission-webhook
make test           # run unit tests
make test-coverage  # write build/coverage.out

make build-image-wh    DOCKER_REGISTRY=ghcr.io/<you>
make build-image-lxcfs DOCKER_REGISTRY=ghcr.io/<you>
```

Repository layout:

```text
cmd/                         webhook server and mutation logic
deploy/                      raw Kubernetes templates and install scripts
charts/lxcfs-admission-webhook/ Helm chart
examples/argocd/             GitOps examples
lxcfs-image/                 LXCFS container image and entrypoint
.github/workflows/           CI, image publish, and chart publish workflows
```

The webhook serves:

- `GET /ping` → `pong`
- `POST /mutate` → Kubernetes `AdmissionReview` mutation endpoint

---

## Uninstall

Mirror the install method you used:

```sh
# Helm
helm uninstall lxcfs-admission-webhook -n lxcfs

# Argo CD
kubectl delete application lxcfs-admission-webhook -n argocd

# install.sh
cd deploy && ./uninstall.sh
```

Uninstall removes the webhook configuration, Deployment, Service, LXCFS DaemonSet, cert-manager resources, and owned Secrets. The namespace is left in place.

---

## Release artifacts

- Webhook image: `ghcr.io/idoyo7/lxcfs-admission-webhook`
- LXCFS image: `ghcr.io/idoyo7/lxcfs`
- Helm chart: `oci://ghcr.io/idoyo7/charts/lxcfs-admission-webhook`

CI builds and tests Go code, publishes images on `main` and semantic version tags, publishes the chart from the chart workflow, and signs published OCI artifacts with cosign on release paths.

---

## License

Apache License 2.0. See [`LICENSE`](LICENSE).

---

## Maintainer

idoyo7 — [idoyo7@gmail.com](mailto:idoyo7@gmail.com)

Original project: [`ymping/lxcfs-admission-webhook`](https://github.com/ymping/lxcfs-admission-webhook)
