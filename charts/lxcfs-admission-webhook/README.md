# lxcfs-admission-webhook Helm Chart

A Kubernetes admission webhook that auto-mounts LXCFS-virtualized `/proc` and
`/sys` files into Pods so containers see cgroup-aware CPU and memory values.
Useful for JVM, Go, and other runtimes that read `/proc/cpuinfo` or
`/proc/meminfo` directly instead of using cgroup limits.

## Prerequisites

| Requirement | Version |
|---|---|
| Kubernetes | >= 1.21 |
| Helm | >= 3.0 |
| [cert-manager](https://cert-manager.io/docs/installation/) | v1.x |
| `fuse3` kernel module | installed on every node |

cert-manager is **not** bundled as a chart dependency. Install it before this
chart:

```sh
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
```

## Installing the chart

### From a local clone

```sh
helm install lxcfs-admission-webhook charts/lxcfs-admission-webhook \
  --namespace lxcfs \
  --create-namespace
```

### Upgrade

```sh
helm upgrade lxcfs-admission-webhook charts/lxcfs-admission-webhook \
  --namespace lxcfs
```

### From GHCR OCI registry (once published)

```sh
helm install lxcfs-admission-webhook \
  oci://ghcr.io/idoyo7/charts/lxcfs-admission-webhook \
  --version 0.1.0 \
  --namespace lxcfs \
  --create-namespace
```

## Enable a namespace

Label any namespace you want the webhook to mutate:

```sh
kubectl label namespace <your-namespace> lxcfs-admission-webhook=enabled
```

## Opt out a single Pod

Add this annotation to a Pod spec to skip mutation:

```yaml
annotations:
  mutating.lxcfs-admission-webhook.io/enable: "false"
```

## Uninstalling

```sh
helm uninstall lxcfs-admission-webhook --namespace lxcfs
```

Note: cert-manager Certificate/Issuer resources and the TLS Secret are removed
with the release. The namespace is not deleted automatically.

## Values reference

See [values.yaml](values.yaml) for the full list of parameters with inline
documentation comments. Key parameters are summarised below.

| Parameter | Default | Description |
|---|---|---|
| `webhook.image.repository` | `ghcr.io/idoyo7/lxcfs-admission-webhook` | Webhook image repository |
| `webhook.image.tag` | chart appVersion | Webhook image tag |
| `webhook.replicas` | `2` | Number of webhook Deployment replicas |
| `webhook.port` | `8443` | HTTPS port the webhook listens on |
| `webhook.resources` | see values.yaml | CPU/memory limits for the webhook |
| `lxcfs.image.repository` | `ghcr.io/idoyo7/lxcfs` | LXCFS image repository |
| `lxcfs.image.tag` | `7.0.0-1` | LXCFS image tag |
| `lxcfs.hostPath` | `/var/lib/lxc` | Node path where LXCFS state is exposed |
| `lxcfs.terminationGracePeriodSeconds` | `60` | Window the preStop FUSE teardown must fit inside; the script's budget is derived from it as `max(5, value - 15)`s |
| `lxcfs.tolerations` | tolerates master/control-plane | DaemonSet tolerations |
| `certificate.ca.duration` | `87600h` (10 years) | Local CA certificate lifetime |
| `certificate.serving.duration` | `8760h` (1 year) | Webhook serving cert lifetime |
| `certificate.serving.renewBefore` | `720h` (30 days) | Serving cert renewal window |
| `mutatingWebhook.failurePolicy` | `Ignore` | Webhook failure policy |
| `mutatingWebhook.namespaceSelector` | `lxcfs-admission-webhook: enabled` | Namespace label selector |

## Architecture

```
cert-manager
  └─ Issuer (selfsigned) → Certificate (CA) → Issuer (ca-issuer)
       └─ Certificate (serving) → Secret mounted by webhook Deployment

webhook Deployment (2 replicas)
  └─ listens :8443, mutates Pod CREATE by injecting LXCFS volumeMounts

LXCFS DaemonSet (every linux node)
  └─ mounts /var/lib/lxc on the host via nsenter
```

## Upgrades

- See [MIGRATION.md](MIGRATION.md) before upgrading. Chart `0.3.0` is
  **not safe to deploy** — its LXCFS image hangs every reader of
  `/proc/cpuinfo`, `/proc/stat` and `/sys/devices/system/cpu/online`
  ([lxc/lxcfs#730](https://github.com/lxc/lxcfs/issues/730)). Go from
  `0.2.x` straight to `0.4.0`.
- MIGRATION.md also covers the cgroup v2 requirement, a pre-flight check
  that actually exercises the affected files, and the recovery procedure
  for a node with a wedged or leaked LXCFS mount.
- Chart resources are all release-named and pruned by `helm rollback` or an
  Argo CD `targetRevision` change — but the LXCFS FUSE mount is not a
  Kubernetes resource and leaks into the host mount namespace, so a
  rollback away from a wedged daemon needs manual node cleanup. See
  MIGRATION.md (Recovery).

## Source

- GitHub: <https://github.com/idoyo7/lxcfs-admission-webhook>
