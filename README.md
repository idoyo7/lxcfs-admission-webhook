# lxcfs-admission-webhook

[![Go](https://github.com/idoyo7/lxcfs-admission-webhook/actions/workflows/go.yml/badge.svg)](https://github.com/idoyo7/lxcfs-admission-webhook/actions/workflows/go.yml)
[![Publish images](https://github.com/idoyo7/lxcfs-admission-webhook/actions/workflows/docker-publish.yml/badge.svg)](https://github.com/idoyo7/lxcfs-admission-webhook/actions/workflows/docker-publish.yml)
[![License](https://img.shields.io/github/license/idoyo7/lxcfs-admission-webhook)](LICENSE)

**English** · [한국어](README.ko.md)

> A Kubernetes MutatingAdmissionWebhook that auto-mounts [LXCFS](https://linuxcontainers.org/lxcfs/introduction/)-virtualized `/proc` and `/sys` files into Pods so JVM / Node / Go / Python runtimes inside containers see **cgroup-aware CPU and memory values** instead of the host's.

This repository is a maintenance fork of
[`ymping/lxcfs-admission-webhook`](https://github.com/ymping/lxcfs-admission-webhook),
brought up to LXCFS 6.x / Go 1.24 / k8s 1.34, with certificate
issuance delegated to cert-manager and image publishing consolidated
on GHCR.

---

## At a glance — the 5W1H

| | |
|--|--|
| **What** | A `MutatingAdmissionWebhook` patches Pod specs at creation time so LXCFS-virtualized files are bind-mounted into the Pod's `/proc` and `/sys`. The virtualized files are produced by an LXCFS DaemonSet running on each node. |
| **Why** | Inside a container, `/proc/cpuinfo` and `/proc/meminfo` expose **host values**, not cgroup-limited values. So the JVM's `-XX:+UseContainerSupport` heuristic, Node's `os.cpus()`, Go's `runtime.NumCPU()`, plus tools like `nproc`, `top`, and `free`, all see far more CPU and memory than the container is actually allowed to use, and pick wrong GC/thread-pool/heap sizes. LXCFS solves this — but adding the mounts to every Pod by hand is tedious. This webhook is the automation layer. |
| **How** | Label a namespace with `lxcfs-admission-webhook=enabled`. From then on, new Pods in that namespace are automatically patched: a JSON Patch adds `volumes`, `volumeMounts`, and a status annotation. |
| **When** | Only on the Pod **CREATE** admission event. Existing Pods are not touched; you must redeploy workloads for the change to take effect. |
| **Where** | The following paths are shadowed by LXCFS views inside the Pod's containers: `/proc/cpuinfo`, `/proc/meminfo`, `/proc/stat`, `/proc/uptime`, `/proc/loadavg`, `/proc/diskstats`, `/proc/swaps`, and `/sys/devices/system/cpu/online`. |
| **Who** | Teams running JVM, Node, Go, Python, or Ruby workloads — runtimes that don't (or can't) read cgroup values directly. Especially helpful when JVMs OOMKill due to wrong memory sizing, or when `nproc` returns the host CPU count and inflates thread-pool sizes. |

---

## Concrete impact — Before / After

> Hypothetical results inside a Pod limited to `cpu: "1", memory: "1Gi"` on a node with 4 vCPUs and 8 GiB RAM:

| Command | Without webhook | With webhook |
|---|---|---|
| `nproc` | `4` (host vCPUs) | `1` (cgroup CPU quota) |
| `cat /proc/cpuinfo \| grep -c processor` | `4` | `1` |
| `free -m` | `... 8000 ...` | `... 1024 ...` |
| `cat /proc/meminfo \| grep MemTotal` | host memory | cgroup memory limit |
| `uptime` load average | host load | container-view load |

What that buys you at the runtime level:

- **JVM**: `Runtime.availableProcessors()` returns the cgroup-correct CPU count, so `ForkJoinPool` and G1 GC worker counts are sane. On cgroup v1 hosts, container-aware memory sizing makes `-XX:MaxRAMPercentage` behave as intended.
- **Node.js**: `os.cpus()` returns an array sized to the limit, preventing the cluster module from forking host-many workers in a small Pod.
- **Go**: `runtime.NumCPU()` shrinks, so `GOMAXPROCS` auto-tuning works correctly without pulling in `automaxprocs`.
- **Python · Ruby**: `multiprocessing.cpu_count()` and `Etc.nprocessors` report the right CPU count.

---

## How it works

```
                      ┌─────────────────────────┐
                      │  LXCFS DaemonSet        │
                      │  (one Pod per node;     │
                      │   privileged, hostPID)  │
                      │  ─ FUSE mount @         │
                      │    /var/lib/lxc/lxcfs   │
                      └──────────┬──────────────┘
                                 │ /var/lib/lxc on the host is
                                 │ exposed via hostPath so any
                                 │ Pod can bind-mount from it
                                 ▼
   ┌──────────────┐  AdmissionReview ┌─────────────────────────┐
   │  kube-       │ ────────────────▶│  webhook Deployment     │
   │  apiserver   │                  │  (mTLS with the cert    │
   │              │ ◀── JSON Patch ──│   issued by cert-manager)│
   └──────────────┘                  └─────────────────────────┘
          │
          │ The Pod spec gains:
          ▼
   spec.volumes:                      spec.containers[*].volumeMounts:
     - name: lxcfs                       - mountPath: /proc/cpuinfo
       hostPath:                           subPath: lxcfs/proc/cpuinfo
         path: /var/lib/lxc/                readOnly: true
         type: DirectoryOrCreate          (… plus meminfo, stat, uptime,
                                          loadavg, diskstats, swaps,
                                          sys/devices/system/cpu/online)
                                          - mountPath: /var/lib/lxc/
                                            readOnly: true
                                            mountPropagation: HostToContainer
   metadata.annotations:
     mutating.lxcfs-admission-webhook.io/status: mutated
```

The webhook can land on one of three outcomes per Pod:

| `status` annotation | Meaning |
|---|---|
| `mutated` | LXCFS volumes/volumeMounts were added successfully |
| `skip` | Patch was deliberately skipped (namespace selector or per-Pod annotation) |
| `conflict` | An existing Pod volume named `lxcfs`, or a colliding mountPath, was detected — patching aborted to stay safe |

> **Caveat**: LXCFS does not virtualize `/proc/cpustat`. Some tools may still report a fraction of CPU *usage* against the host on cgroup v2 hosts. CPU and memory *limits* are reported correctly.

---

## What's added vs upstream (ymping)

A total of 14 fork-only commits, organized below.

### Functional improvements

| Item | Upstream | This fork |
|---|---|---|
| **Annotation patch safety** | A single `add` op against `Path: "/metadata/annotations"` replaces the entire annotation map — risks clobbering annotations the user already set | A per-key `add`/`replace` against `/metadata/annotations/<key>`, with RFC 6901 JSON Pointer escaping (`~` → `~0`, `/` → `~1`) |
| **Certificate issuance** | `install.sh` shells out to openssl to mint a self-signed CA + serving cert, base64-encodes the CA, and `envsubst`s it into `caBundle` — depends on openssl, no auto-renewal | cert-manager issues a self-signed Issuer → 10y CA → 1y serving cert chain, and the `cert-manager.io/inject-ca-from` annotation injects the `caBundle` automatically. **Auto-renews** 30 days before expiry |
| **Image registry** | docker.io, webhook image only; lxcfs image had to be built by hand | A GHCR matrix workflow publishes both `ghcr.io/<owner>/lxcfs-admission-webhook` and `ghcr.io/<owner>/lxcfs` automatically. cosign keyless signing. The `org.opencontainers.image.source` label links each package back to this repo |
| **Image references** | `montkim9/...` was hardcoded in deployment / daemonset YAML | Parametrized as `${WH_IMAGE}` / `${LXCFS_IMAGE}`; `install.sh --wh-image` / `--lxcfs-image` (or the matching env vars) override on the fly |
| **Uninstall robustness** | Errors out if a resource was already missing | All `kubectl delete` calls use `--ignore-not-found`, so partial installs uninstall cleanly |
| **install.sh dependencies** | `kubectl`, `openssl`, `envsubst`, `base64`, `mktemp` | `kubectl`, `envsubst`, and the cert-manager CRDs at runtime — openssl dependency dropped |

### Toolchain modernization

| Item | Upstream | This fork |
|---|---|---|
| LXCFS | 4.0.12-r0 (cgroup v1 only verified) | **6.0.1-r0** (cgroup v2 compatible) |
| Alpine base | 3.15 (EOL 2023-11) | **3.21** (supported) |
| Build Go | 1.17 (EOL 2022-09) | **1.24** (supported) |
| go.mod `go` directive | 1.18 | **1.24.0** + `toolchain go1.24.5` |
| k8s.io modules | v0.24.3 (k8s 1.24, May 2022) | **v0.34.1** (k8s 1.34, 2025) |
| `io/ioutil` (deprecated) | in use | replaced with `io` |
| GitHub Actions | checkout@v2 / setup-go@v3 / login@v2 / build-push@v3 / cosign@v2 | All current majors (v5/v5/v3/v6/v3) |

### Release automation

- Push to `main` or any `v*.*.*` tag publishes both images to GHCR.
- `docker/metadata-action` derives tags for branch / PR / semver / sha / `latest` (on default-branch pushes).
- Each pushed digest is signed with cosign keyless (Fulcio + Rekor).
- Pull requests build images but skip the push.

---

## Prerequisites

- Kubernetes **v1.16+** (uses `admissionregistration.k8s.io/v1`)
- [**cert-manager**](https://cert-manager.io/) v1.x — issues and rotates the webhook serving certificate
- Nodes with **fuse3** available (LXCFS 5.x+ links against libfuse3)
- `kubectl` and `envsubst` (from `gettext`) on the operator's machine

cert-manager quick install (skip if already present):

```sh
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
kubectl -n cert-manager wait --for=condition=Available deployment --all --timeout=120s
```

---

## Install

```sh
git clone https://github.com/idoyo7/lxcfs-admission-webhook.git
cd lxcfs-admission-webhook/deploy
./install.sh
```

Defaults and overridable flags:

| Flag | Default |
|---|---|
| `--namespace` | `lxcfs` |
| `--deployment` | `lxcfs-admission-webhook` |
| `--service` | `lxcfs-admission-webhook` |
| `--secret` | `lxcfs-admission-webhook` (populated by cert-manager) |
| `--daemonset` | `lxcfs-ds` |
| `--mutating` | `lxcfs-admission-webhook` |
| `--wh-image` | `ghcr.io/idoyo7/lxcfs-admission-webhook:latest` |
| `--lxcfs-image` | `ghcr.io/idoyo7/lxcfs:6.0.1-r0` |

Images can also be set via env vars:

```sh
WH_IMAGE=ghcr.io/idoyo7/lxcfs-admission-webhook:v0.2.0 ./install.sh
```

---

## Usage

Opt a namespace in:

```sh
kubectl label namespace your-namespace lxcfs-admission-webhook=enabled
```

Pods created in that namespace afterwards are patched automatically.
To opt a single Pod out, set this annotation on the Pod (or the
Deployment / StatefulSet template):

```yaml
metadata:
  annotations:
    mutating.lxcfs-admission-webhook.io/enable: "false"
```

The webhook records its decision back on the Pod as
`mutating.lxcfs-admission-webhook.io/status: mutated | skip | conflict`.

---

## Verifying it works

After installing and labeling, run a quick test Pod with limits and
read the values back from inside it:

```sh
kubectl label namespace default lxcfs-admission-webhook=enabled
kubectl run lxcfs-check --rm -it --restart=Never \
  --image=alpine:3.21 \
  --limits=cpu=1,memory=1Gi \
  -- sh -c 'echo "nproc:    $(nproc)"; echo; head -3 /proc/meminfo; echo; cat /proc/cpuinfo | grep -c ^processor'
```

If `nproc` is `1` and `MemTotal` is roughly `1048576 kB`, the
mutation is in effect. You can also confirm the status annotation:

```sh
kubectl get pod lxcfs-check -o jsonpath='{.metadata.annotations.mutating\.lxcfs-admission-webhook\.io/status}'
# → mutated
```

---

## Uninstall

```sh
cd deploy
./uninstall.sh
```

Removes the MutatingWebhookConfiguration, Deployment, Service, LXCFS
DaemonSet, the cert-manager Issuer/Certificate pair, and the Secrets
they own. The namespace itself is left in place.

---

## Build from source

```sh
make build         # → ./build/lxcfs-admission-webhook
make test          # unit tests (creates a self-signed test cert)

# Image builds — DOCKER_REGISTRY is overridable
make build-image-wh    DOCKER_REGISTRY=ghcr.io/<you>
make build-image-lxcfs DOCKER_REGISTRY=ghcr.io/<you>
```

CI publishes both images to GHCR on every push to `main` and on
semver tags. See [`.github/workflows/docker-publish.yml`](.github/workflows/docker-publish.yml).

---

## License

Apache License 2.0. See [`LICENSE`](LICENSE).

Apache 2.0 is a permissive license: anyone — including for-profit
companies — can use, modify, and redistribute this code, even inside
closed-source products, as long as they keep the license text and
preserve attribution. It is **not** copyleft; downstream forks are
not forced to be open source. (Contrast with AGPL, which extends
copyleft obligations to network-served use.)

## Maintainer

idoyo7 — [idoyo7@gmail.com](mailto:idoyo7@gmail.com)

Original project: [ymping/lxcfs-admission-webhook](https://github.com/ymping/lxcfs-admission-webhook)
