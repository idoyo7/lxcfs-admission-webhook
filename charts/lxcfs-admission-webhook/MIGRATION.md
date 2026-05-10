# Migration guide

## To LXCFS 7.x (when Alpine packages it)

LXCFS upstream released 7.0 LTS on 2024-04-30 with notable additions
(PSI virtualization, zswap accounting, pidfd as default) and notable
removals (cgroup v1 support, libfuse2 support, cgroupfs emulation).
At the time of writing, Alpine community ships only 6.0.1-r1 — no
3.21/3.22/3.23 branch yet carries 7.x. The chart and image are
preconfigured so the eventual migration is a values-only flip.

### What's already prepared

- `lxcfs-image/Dockerfile` — `ENTRYPOINT` is fixed at
  `dumb-init -- /lxcfs/entrypoint.sh`; `CMD` is the lxcfs flag list
  and is overridable via `container.args`.
- `lxcfs-image/entrypoint.sh` — passes `"$@"` straight through to
  `/usr/bin/lxcfs`, so any flag list the chart provides reaches the
  binary unchanged.
- `charts/lxcfs-admission-webhook/values.yaml` — exposes
  `lxcfs.args` (default mirrors the historical 6.x flag set).
- `renovate.json` — tracks `alpine_3_21/lxcfs` via the repology
  datasource and opens a PR bumping `LXCFS_VERSION` and the chart's
  `lxcfs.image.tag` together when Alpine community publishes a new
  revision.

### Migration steps when 7.x lands in Alpine

1. Merge the Renovate PR (or manually bump `LXCFS_VERSION` in
   `lxcfs-image/.env` and `lxcfs.image.tag` in `values.yaml`). The
   image-publish workflow rebuilds and pushes a new lxcfs image with
   that revision tag.
2. Decide which 7.x flags to opt into. In a downstream values file
   (or directly in the chart's `values.yaml`):
   ```yaml
   lxcfs:
     args:
       - --foreground
       - --enable-loadavg
       - --enable-cfs
       - --enable-psi-poll       # optional, 7.x: Pressure Stall Info
       - --enable-zswap          # optional, 7.x: zswap accounting
   ```
3. Bump the chart `version` in `Chart.yaml` (patch when only the
   image revision changes, minor when adding flags), commit, and let
   the chart-publish workflow push the new OCI artifact.
4. Update the consuming Argo CD `Application`'s `targetRevision` to
   the new chart version. Argo CD will recreate the LXCFS DaemonSet
   pods with the new image and flags.

### Compatibility notes

- 7.x removes cgroup v1 support. Hosts must be on cgroup v2 (default
  on kernels 5.15+ / Kubernetes 1.25+). Verify with
  `stat -fc %T /sys/fs/cgroup` returning `cgroup2fs` on each node.
- 7.x removes libfuse2 support. The chart already pulls `lxcfs` from
  Alpine community where the package depends on `fuse3`; no node
  configuration change required.
- `--enable-cfs` continues to be accepted on cgroup v2 hosts in 6.x
  and 7.x; remove it from `lxcfs.args` only if upstream announces a
  removal.
- `--enable-pidfd` becomes default-on in 7.x; do not pass it
  explicitly (it emits a deprecation warning).

### Rollback

The chart's previous OCI versions remain available
(`oci://ghcr.io/idoyo7/charts/lxcfs-admission-webhook:0.2.x`). Roll
back by changing the consumer's `targetRevision` to the prior tag;
no manual cleanup is required because all chart resources are
release-named and managed by Argo CD's prune/sync.
