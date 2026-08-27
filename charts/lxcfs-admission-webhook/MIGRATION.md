# Migration guide

## 0.3.0 -> 0.4.0 (fixes a node-hanging regression in 0.3.0)

> **Do not run chart `0.3.0`, and do not roll back to it.** Its LXCFS
> image hangs every reader of `/proc/cpuinfo`, `/proc/stat` and
> `/sys/devices/system/cpu/online` on any node whose containers sit in a
> nested cgroup — which is every Kubernetes node. Upgrade straight from
> `0.2.x` to `0.4.0`.

### What broke

Chart `0.3.0` built LXCFS 7.0.0 from source on `alpine:3.22`, i.e. against
musl and without Alpine's distro patches. The daemon looks healthy: it
starts, prints its `api_extensions` (including `cpuview_daemon`,
`loadavg_daemon`, `pidfds`), and FUSE-mounts `/var/lib/lxc/lxcfs`.
`/proc/meminfo` reads instantly. But:

| Read through the mount | Result |
|---|---|
| `/proc/meminfo`, `/proc/loadavg`, `/proc/uptime`, `/proc/swaps`, `/proc/diskstats` | works |
| `/proc/cpuinfo`, `/proc/stat`, `/sys/devices/system/cpu/online` | **never returns** |

The reader ends up in uninterruptible sleep (`D` state) with a kernel
stack of `fuse_file_read_iter -> fuse_direct_io -> fuse_simple_request ->
request_wait_answer`. `timeout` cannot kill it, and neither can `kill -9`.
Meanwhile the lxcfs process burns its entire CPU limit — at the chart's
default `500m` that is ~99% of CFS periods throttled — while completing
zero requests.

The knock-on effect is what makes it a node-level incident rather than a
pod-level one: the postStart hook probes
`/var/lib/lxc/lxcfs/sys/devices/system/cpu/online`, so it never returns,
so the container never goes Ready. kubelet deletes the Pod but cannot kill
the container, because the preStop hook blocks identically. Orphaned lxcfs
daemons accumulate, each holding a FUSE mount that leaked into the host
mount namespace.

### Root cause

Upstream bug, first shipped in LXCFS v7.0.0:
[lxc/lxcfs#730](https://github.com/lxc/lxcfs/issues/730), introduced by
[lxc/lxcfs#690](https://github.com/lxc/lxcfs/pull/690). No upstream
release contains the fix yet.

`get_min_cpu_count_cfs()` in `src/proc_cpuview.c` walks a cgroup path
towards the root by calling `dirname()` and then re-testing its *input*
buffer:

```c
do {
        ...
        char *parent = dirname(cur_sg); // walk up
        if (strcmp(parent, ".") == 0) break;
} while (strcmp(cur_sg, "/") != 0);
```

That only terminates if `dirname()` truncated the buffer in place. POSIX
does not require it to, and musl does not: for a single-component absolute
path, `dirname("/kubepods.slice")` returns a pointer to a static `"/"` and
leaves the buffer untouched, so `cur_sg` is `"/kubepods.slice"` forever.
glibc rewrites the buffer to `"/"` and the loop ends.

Everything that hangs reaches `max_cpu_count()` -> `get_min_cpu_count_cfs()`;
nothing that works does. `/sys/devices/system/cpu/online` is only affected
when `--enable-cfs` is set, which is the chart default. The reading
process's cgroup path must have at least one component for the loop to
spin, which is why a bare `docker run` can look fine while every
Kubernetes Pod hangs.

### What changed in 0.4.0

- `lxcfs-image/Dockerfile` moves both stages to `debian:bookworm-slim`
  (glibc). Upstream develops and CI-tests LXCFS only on glibc — its
  workflow matrix is `ubuntu-22.04`/`ubuntu-24.04` on amd64 and arm64,
  with no musl job — so musl regressions ship unnoticed. Alpine's own
  `lxcfs` package is still on 6.0.1 across every branch; Debian already
  ships 7.0.0 with zero patches.
- `lxcfs-image/patches/0001-cpuview-make-the-cgroup-hierarchy-walk-libc-agnostic.patch`
  carries the upstream fix as well, so the image is correct even if it is
  ever rebased onto a musl base. The build fails loudly if the patch stops
  applying, rather than silently publishing a hanging image.
- `lxcfs.image.tag` defaults to **`7.0.0-1`**. The published tag is now
  `${LXCFS_VERSION}-${LXCFS_IMAGE_REVISION}`, giving image-only rebuilds
  an immutable handle. The floating `7.0.0` tag also points at the fixed
  build, but pin the revision so you can tell which one a node is running.
- `lxcfs-image/lxcfs-mount.sh` bounds every probe and mount operation.
  `--remount` now exits non-zero after `LXCFS_PROBE_TIMEOUT` (default 5s)
  instead of blocking forever, so a wedged mount surfaces as
  `FailedPostStartHook` and a CrashLoopBackOff — visible and alertable —
  rather than as a stuck container. `--umount` no longer probes the FUSE
  files at all and falls back to `umount -l`, so preStop cannot hang.
- `lxcfs-image/entrypoint.sh` falls back to a lazy umount when the stale
  mount from a previous daemon is dead, instead of crash-looping on
  "Transport endpoint is not connected".
- `lxcfs-image/verify-lxcfs.sh` is a new pre/post-flight checker (see
  below).
- CI smoke-tests the image by reading the cpuview-backed files before
  publishing.

The glibc base costs image size: roughly **27 MB compressed** versus
**6.8 MB** for the Alpine build (99 MB versus 27 MB on disk). For a
DaemonSet that pulls once per node this is a reasonable trade for a base
upstream actually tests. If the size matters more than that in your
environment, the carried patch alone is sufficient — it was verified to fix
the hang on musl too — so an Alpine base plus `patches/` is a supported
alternative. It just leaves you on a libc upstream never exercises.

### Before you upgrade

1. **Confirm every node LXCFS runs on is cgroup v2.** LXCFS 7.0 only
   initializes against the unified cgroup hierarchy.
   ```sh
   stat -fc %T /sys/fs/cgroup   # expect: cgroup2fs
   ```
   Nodes on cgroup v1 or hybrid mode are not compatible with 7.x and
   should stay on the 6.x image (see Staying on 6.x below).

2. **Actually read a cpuview-backed file.** This is the check that matters,
   and the one this guide previously lacked. A daemon that starts, prints
   `api_extensions` and mounts successfully proves nothing — that is
   exactly what the broken build does. `stat -fc %T` proves even less.

   From a Pod in a namespace the webhook mutates:
   ```sh
   kubectl -n <mutated-ns> exec <pod> -- timeout 5 head -1 /proc/cpuinfo
   kubectl -n <mutated-ns> exec <pod> -- timeout 5 cat /sys/devices/system/cpu/online
   ```
   If either command produces no output and never returns, the mount is
   wedged. Note that the `exec`'d process is now unkillable — go to
   Recovery.

   Or use the bundled checker, which does the same reads with an outer
   deadline so it always terminates:
   ```sh
   # against a cluster (creates and deletes a throwaway probe Pod)
   ./lxcfs-image/verify-lxcfs.sh cluster -n <mutated-ns>

   # against an image, before it ever reaches a node
   ./lxcfs-image/verify-lxcfs.sh image ghcr.io/idoyo7/lxcfs:7.0.0-1
   ```

   Do **not** run the read on the node itself and call it a pass. LXCFS
   skips the cpuview code path for callers in the host PID namespace whose
   cgroup is the root, so a read from the node can succeed while every
   container hangs.

3. **Expect manual cleanup if 0.3.0 ever ran on these nodes.** Work through
   Recovery first; a rolling upgrade will not displace a leaked mount on
   its own.

4. **Do not add `--enable-pidfd` to `lxcfs.args`.** pidfd-based process
   tracking is mandatory and default-on in 7.0; the flag is deprecated and
   only emits a warning. The chart's default `lxcfs.args`
   (`--foreground --enable-loadavg --enable-cfs`) needs no change.

5. **libfuse2 is no longer required or used.** The 7.x image links only
   against libfuse3.

### Upgrade steps

1. If chart `0.3.0` has already been applied anywhere, run Recovery on
   every affected node before rolling forward. The new Pod cannot mount
   over a leaked mount, and the old Pod cannot be evicted while its
   daemon is wedged.
2. Bump the chart to `0.4.0` (`helm repo update`, or
   `targetRevision: 0.4.0` for Argo CD). `lxcfs.image.tag` moves to
   `7.0.0-1` automatically.
3. Roll out to **one** node first. Confirm the DaemonSet Pod goes Ready,
   then run the step-2 read check from a Pod on that node. Only then let
   the rest of the DaemonSet roll.
4. No `lxcfs.args` changes are required to keep 6.x behaviour.

### Recovery

Use this when a node has a wedged or leaked LXCFS mount: readers stuck in
`D` state, a DaemonSet Pod that will not go Ready or will not terminate,
or `Transport endpoint is not connected` from `/var/lib/lxc/lxcfs`.

Run on the affected node, as root.

```sh
# 1. Find the wedged FUSE connection. A non-zero `waiting` count is a
#    request the daemon accepted and never answered.
mountpoint -q /sys/fs/fuse/connections || mount -t fusectl none /sys/fs/fuse/connections
grep -l '^[1-9]' /sys/fs/fuse/connections/*/waiting

# 2. Abort it. This is the only thing that releases readers parked in
#    uninterruptible sleep -- SIGKILL does not, because they are not
#    running. After the abort they get ENOTCONN and exit normally.
echo 1 > /sys/fs/fuse/connections/<N>/abort

# 3. Kill any orphaned daemons. Expect more than one if the DaemonSet has
#    already tried to restart.
pgrep -af '/usr/bin/lxcfs'
pkill -f '/usr/bin/lxcfs'

# 4. Detach the leaked mount. It survived the container that created it
#    because the volume uses Bidirectional propagation, so it must be
#    removed from the host explicitly. Lazily, because something may still
#    be attached to it.
findmnt -t fuse.lxcfs
umount -l /var/lib/lxc/lxcfs

# 5. Confirm the mount point is a plain empty directory again.
findmnt -t fuse.lxcfs           # expect no output
ls -a /var/lib/lxc/lxcfs
```

Then let the DaemonSet recreate the Pod (`kubectl -n <ns> delete pod
<lxcfs-pod>`) and re-run the read check from step 2 of Before you upgrade.

Notes:

- Step 1 may find the mount in a namespace other than the node's init
  mount namespace, depending on how the container runtime set up
  propagation. `findmnt` from PID 1 is the usual place; if it comes up
  empty while `/var/lib/lxc/lxcfs` still misbehaves, check the runtime's
  own mount namespace:
  ```sh
  nsenter -t "$(pgrep -o containerd)" -m -- findmnt -t fuse.lxcfs
  ```
- Mutated Pods that already had the bind mounts keep pointing at the dead
  mount and need a restart. With chart `0.4.0` the postStart hook detaches
  and re-binds them; before that, restart them.
- If step 2 does not release a reader, the request may be queued against a
  different connection than the one you aborted. Abort every connection
  with a non-zero `waiting`.

### Staying on 6.x (cgroup v1 nodes)

If some nodes cannot move to cgroup v2 yet, pin those node pools back:

```yaml
lxcfs:
  image:
    tag: 6.0.1-r1
```

This only works with chart `<= 0.2.3`, since `0.3.0` and later no longer
build a libfuse2-based image. The `ghcr.io/idoyo7/lxcfs:6.0.1-r1` tag
published by prior chart versions remains available but is no longer
rebuilt or updated.

### Rollback

Previous chart versions remain available as OCI artifacts
(`oci://ghcr.io/idoyo7/charts/lxcfs-admission-webhook:0.2.3`). Roll back by
changing the consumer's `targetRevision`.

**Roll back to `0.2.3`, not `0.3.0`.** `0.3.0` is the version being fixed
here.

**A rollback is not cleanup-free.** The chart's Kubernetes resources are
all release-named and are pruned by Helm or Argo CD as usual, but the LXCFS
FUSE mount is not a Kubernetes resource: the DaemonSet mounts
`/var/lib/lxc` with `mountPropagation: Bidirectional`, so the mount the
daemon creates leaks into the host mount namespace and outlives its
container. Consequences:

- Rolling back (or forward, or sideways) leaves the previous daemon's mount
  at `/var/lib/lxc/lxcfs`. If that daemon was wedged, the mount is dead and
  the replacement Pod cannot mount over it.
- Pods that were mutated keep bind mounts pointing into the old mount and
  must be restarted.

So: run Recovery on each node as part of any rollback that involves a
version whose daemon was wedged, then let the DaemonSet recreate its Pods.

---

## 0.2.x -> 0.3.0 (LXCFS 7.0.0)

> **Superseded.** Chart `0.3.0` is not safe to deploy — see the section
> above. Go from `0.2.x` straight to `0.4.0`. This section is kept only to
> explain the LXCFS 6.x -> 7.x change itself, which `0.4.0` inherits.

Chart `0.3.0` moved the LXCFS image from an Alpine-packaged binary
(`6.0.1-r1`, still the newest version Alpine community ships) to a source
build of the upstream `v7.0.0` release tarball. This decoupled the image
from Alpine's packaging cadence, and it is a breaking change: LXCFS 7.0
drops legacy cgroup v1 support and libfuse2, and changes pidfd handling
from opt-in to mandatory.

What it changed:

- `lxcfs-image/Dockerfile` became a multi-stage build compiling LXCFS from
  source with meson/ninja. `0.4.0` keeps this but on a glibc base.
- `lxcfs-image/entrypoint.sh` calls `fusermount3` with a `fusermount`
  fallback to clean up stale mounts.
- `renovate.json` tracks the `lxc/lxcfs` GitHub release feed instead of the
  Alpine package feed.

Both of `0.3.0`'s "before you upgrade" items remain correct and are
restated in the `0.4.0` section: nodes must be cgroup v2, and
`--enable-pidfd` must not be passed. What `0.3.0` got wrong was claiming
that `stat -fc %T /sys/fs/cgroup` was sufficient pre-flight verification,
and that rollback required no manual cleanup. Neither is true.
