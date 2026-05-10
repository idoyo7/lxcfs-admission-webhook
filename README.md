# lxcfs-admission-webhook

[![Go](https://github.com/idoyo7/lxcfs-admission-webhook/actions/workflows/go.yml/badge.svg)](https://github.com/idoyo7/lxcfs-admission-webhook/actions/workflows/go.yml)
[![Publish images](https://github.com/idoyo7/lxcfs-admission-webhook/actions/workflows/docker-publish.yml/badge.svg)](https://github.com/idoyo7/lxcfs-admission-webhook/actions/workflows/docker-publish.yml)
[![License](https://img.shields.io/github/license/idoyo7/lxcfs-admission-webhook)](LICENSE)

Kubernetes admission webhook that gives containers a CGroup-aware view of
`/proc` and `/sys/devices/system/cpu/online` by bind-mounting files that a
[LXCFS](https://linuxcontainers.org/lxcfs/introduction/) DaemonSet exposes
on each node.

When a Pod is created in a labeled namespace, the webhook patches its
spec to add the LXCFS volume and the per-file `volumeMounts`, so commands
like `top`, `free`, `nproc`, and language runtimes (JVM, Node, Go) read
container-scoped CPU/memory values instead of host values.

This is a maintained fork of
[ymping/lxcfs-admission-webhook](https://github.com/ymping/lxcfs-admission-webhook).
Recent changes:

- **LXCFS 6.0.1-r1**, cgroup v2 compatible.
- **Go 1.24** toolchain, **k8s.io v0.34.1** modules.
- **cert-manager**-issued serving certificate; install no longer needs
  openssl or shell-based base64 plumbing.
- **GHCR** as the canonical registry for both images:
  `ghcr.io/idoyo7/lxcfs-admission-webhook` and `ghcr.io/idoyo7/lxcfs`.

## How it works

```
                    +-----------------------+
                    |  LXCFS DaemonSet      |
                    |  (privileged, hostPID)|
                    |   /var/lib/lxc/lxcfs  |
                    +-----------+-----------+
                                |
                  hostPath mount on every node
                                |
+---------+      mutate    +----v----------+
|  kube-  | -- AdmissionReview --> webhook |
|  api    | <-- JSON patch ------ deployment
+---------+                +---------------+
                                |
                                v
                  Pod gets these added:
                    /proc/cpuinfo  -> lxcfs/proc/cpuinfo
                    /proc/meminfo  -> lxcfs/proc/meminfo
                    /proc/stat     -> lxcfs/proc/stat
                    /proc/swaps    -> lxcfs/proc/swaps
                    /proc/uptime   -> lxcfs/proc/uptime
                    /proc/loadavg  -> lxcfs/proc/loadavg
                    /proc/diskstats -> lxcfs/proc/diskstats
                    /sys/devices/system/cpu/online
```

The webhook only patches Pods in namespaces labeled
`lxcfs-admission-webhook=enabled`, and skips any Pod annotated with
`mutating.lxcfs-admission-webhook.io/enable: "false"`.

## Prerequisites

- Kubernetes v1.16+ (uses `admissionregistration.k8s.io/v1`).
- [cert-manager](https://cert-manager.io/) v1.x already installed in the
  cluster — it issues and rotates the webhook's serving certificate.
- Nodes with `fuse3` available (LXCFS 5.x+ links against libfuse3).
- `kubectl` and `envsubst` (from `gettext`) on the operator's machine.

cert-manager quick install (skip if already present):
```sh
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
kubectl -n cert-manager wait --for=condition=Available deployment --all --timeout=120s
```

## Install

```sh
git clone https://github.com/idoyo7/lxcfs-admission-webhook.git
cd lxcfs-admission-webhook/deploy
./install.sh
```

Defaults:

| Flag                    | Default                                               |
|-------------------------|-------------------------------------------------------|
| `--namespace`           | `lxcfs`                                               |
| `--deployment`          | `lxcfs-admission-webhook`                             |
| `--service`             | `lxcfs-admission-webhook`                             |
| `--secret`              | `lxcfs-admission-webhook` (managed by cert-manager)   |
| `--daemonset`           | `lxcfs-ds`                                            |
| `--mutating`            | `lxcfs-admission-webhook`                             |
| `--wh-image`            | `ghcr.io/idoyo7/lxcfs-admission-webhook:latest`       |
| `--lxcfs-image`         | `ghcr.io/idoyo7/lxcfs:6.0.1-r1`                       |

All defaults are overridable. `WH_IMAGE` and `LXCFS_IMAGE` also work as
environment variables, e.g.:
```sh
WH_IMAGE=ghcr.io/idoyo7/lxcfs-admission-webhook:v0.2.0 ./install.sh
```

## Usage

Opt a namespace in:
```sh
kubectl label namespace your-namespace lxcfs-admission-webhook=enabled
```

Subsequent Pods created in that namespace are patched automatically. To
opt a single Pod out, set this annotation on the Pod (or its
Deployment/StatefulSet template):
```yaml
metadata:
  annotations:
    mutating.lxcfs-admission-webhook.io/enable: "false"
```

The webhook records its decision on the Pod with the annotation
`mutating.lxcfs-admission-webhook.io/status` set to `mutated`, `skip`,
or `conflict`.

## Uninstall

```sh
cd deploy
./uninstall.sh
```

This removes the MutatingWebhookConfiguration, Deployment, Service,
LXCFS DaemonSet, the cert-manager Issuer/Certificate pair, and the
Secrets they own. The namespace itself is left in place.

## Build from source

```sh
make build         # binary -> ./build/lxcfs-admission-webhook
make test          # unit tests (creates self-signed test certs)
make build-image-wh   DOCKER_REGISTRY=ghcr.io/<you>
make build-image-lxcfs DOCKER_REGISTRY=ghcr.io/<you>
```

CI pushes both images to GHCR on every push to `main` and on semver
tags; see [`.github/workflows/docker-publish.yml`](.github/workflows/docker-publish.yml).

## License

Apache License 2.0. See [`LICENSE`](LICENSE).

## Maintainer

idoyo7 — [idoyo7@gmail.com](mailto:idoyo7@gmail.com)

Original project: [ymping/lxcfs-admission-webhook](https://github.com/ymping/lxcfs-admission-webhook)
