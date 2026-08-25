# Migration guide

## 0.2.x -> 0.3.0 (LXCFS 7.0.0)

Chart `0.3.0` moves the LXCFS image from an Alpine-packaged binary
(`6.0.1-r1`, the last version Alpine community shipped) to a source
build of the upstream `v7.0.0` release tarball
(https://github.com/lxc/lxcfs/releases). This decouples the image
from Alpine's packaging cadence, and it is a breaking change: LXCFS
7.0 drops legacy cgroup v1 support and libfuse2, and changes pidfd
handling from opt-in to mandatory.

### What changed

- `lxcfs-image/Dockerfile` is now a multi-stage build: an
  `alpine:3.22` build stage compiles LXCFS from source with meson/
  ninja, and the runtime stage copies only the resulting `lxcfs`
  binary and `liblxcfs.so`. The runtime stage no longer installs the
  Alpine `lxcfs` apk package, so libfuse2 is not pulled in at all.
- `lxcfs-image/entrypoint.sh` now calls `fusermount3` instead of
  `fusermount` to clean up stale mounts, matching the binary Alpine's
  `fuse3` package actually ships.
- `charts/lxcfs-admission-webhook/values.yaml` — `lxcfs.image.tag`
  defaults to `7.0.0`.
- `renovate.json` now tracks the `lxc/lxcfs` GitHub release feed
  instead of the Alpine `repology` package feed.

### Before you upgrade

1. **Confirm every node LXCFS runs on is cgroup v2.** LXCFS 7.0 only
   initializes against the unified cgroup hierarchy; nodes still on
   cgroup v1 (legacy) or hybrid mode will fail to expose
   container-aware `/proc` and `/sys` files. Check with:
   ```sh
   stat -fc %T /sys/fs/cgroup
   ```
   Expect `cgroup2fs`. Kubernetes 1.25+ defaults to cgroup v2 on
   kernels 5.15+; older clusters or nodes booted with
   `systemd.unified_cgroup_hierarchy=0` are not compatible with this
   release and should stay on the 6.x image (see Rollback below)
   until they are migrated to cgroup v2.
2. **Do not add `--enable-pidfd` to `lxcfs.args`.** pidfd-based
   process tracking is mandatory and default-on in 7.0 — the flag is
   deprecated and only emits a warning if passed. The chart's default
   `lxcfs.args` (`--foreground --enable-loadavg --enable-cfs`) is
   unaffected and needs no change.
3. **libfuse2 is no longer required or used.** The 7.0.0 image only
   links against `libfuse3`; if you built a custom node image or
   security policy around the old dependency, it can be dropped.

### Upgrade steps

1. Bump the chart to `0.3.0` (`helm repo update` /
   `targetRevision: 0.3.0` for Argo CD). The default
   `lxcfs.image.tag` moves to `7.0.0` automatically.
2. Roll out to a cgroup v2 node first and confirm the LXCFS DaemonSet
   pod starts and `/var/lib/lxc` mounts appear on the host, then let
   the rest of the DaemonSet roll.
3. No `lxcfs.args` changes are required to keep the historical 6.x
   behavior. Optionally opt into new 7.x flags (e.g.
   `--enable-psi-poll`) in a downstream values
   override once you've validated them.

### Staying on 6.x (cgroup v1 nodes)

If some nodes cannot move to cgroup v2 yet, keep those node pools on
the previous image by pinning the tag back:

```yaml
lxcfs:
  image:
    tag: 6.0.1-r1
```

This only works with chart `<= 0.2.3`, since `0.3.0`'s Dockerfile no
longer builds or publishes a libfuse2-based image — the
`ghcr.io/idoyo7/lxcfs:6.0.1-r1` tag published by prior chart versions
remains available, but is no longer rebuilt or updated.

### Rollback

The chart's previous OCI versions remain available
(`oci://ghcr.io/idoyo7/charts/lxcfs-admission-webhook:0.2.3`). Roll
back by changing the consumer's `targetRevision` to `0.2.3` (or
earlier), which restores the `6.0.1-r1` image default; no manual
cleanup is required because all chart resources are release-named and
managed by Argo CD's prune/sync.
