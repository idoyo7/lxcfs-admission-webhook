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

For `/sys/devices/system/cpu/online` it is worse than a read: LXCFS
computes that file's size in its `getattr` handler, which also calls
`max_cpu_count()`, so even a **path lookup** of it hangs. A bare `mount
--bind` of that path parks in `fuse_lookup -> fuse_simple_request`, which
is why the postStart hook's bounded probe of the *source* matters as much
as the probe of the target.

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
- `lxcfs-image/lxcfs-mount.sh` **also tears down the canonical FUSE mount
  at `/var/lib/lxc/lxcfs` in `--umount`**, which nothing used to do — see
  *Teardown on Pod termination* below. It aborts the FUSE connection when
  it has to, which is the only thing that releases a reader already parked
  in the kernel, and it runs the whole teardown against one wall-clock
  budget so it cannot be SIGKILLed halfway.
- `lxcfs-image/entrypoint.sh` aborts a leftover FUSE connection at the
  mount point before trying to unmount it, and now refuses to start if it
  cannot clear the mount, instead of letting `lxcfs` stack a second FUSE
  over the same path. It still falls back to a lazy umount when the stale
  mount from a previous daemon is dead, instead of crash-looping on
  "Transport endpoint is not connected".
- `lxcfs.terminationGracePeriodSeconds` is a new value, defaulting to
  **60** (was the Kubernetes default of 30). The teardown budget is
  derived from it, so the two cannot drift. Arithmetic below.
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

3. **If `0.3.0` ever ran on these nodes, the `0.4.0` Pod cleans up after
   it on startup** — it aborts the leftover FUSE connection, releasing
   readers parked in `D` state, and detaches the leaked mount before
   starting its own daemon. Unlike earlier versions it will *not* start on
   top of a mount it could not clear; it CrashLoopBackOffs instead, which
   is the alertable outcome rather than a second FUSE stacked on the same
   path. Read Recovery for what is still left for you, chiefly restarting
   mutated Pods.

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

### Teardown on Pod termination

Up to and including the first `0.4.0` build, `--umount` unmounted only the
eight in-container bind mounts. **Nothing ever unmounted the canonical FUSE
mount at `/var/lib/lxc/lxcfs`.** The volume carries
`mountPropagation: Bidirectional`, so that mount lives in the host mount
namespace and outlives the container that made it; every roll left it
behind for the *next* Pod's `entrypoint.sh` to clear. When that fallback
failed — the mount was busy, because parked readers held files open on it —
the new daemon mounted a **second** FUSE over the same path, and from then
on everything touching the path blocked forever.

`--umount` now tears that mount down itself, while its own daemon is still
alive to answer, which is the only moment a graceful unmount can work. It
escalates and logs the rung it used:

| Rung | What it does | When |
|---|---|---|
| `none` | nothing | path is not a mount point |
| `graceful` | `fusermount3 -u`, falling back to `fusermount -u` | mount answers and is not busy — the healthy roll |
| `abort + umount` | abort the FUSE connection, then a plain `umount` | mount is wedged, or graceful failed |
| `abort + lazy umount` | abort, then `umount -l` (`MNT_DETACH`) | still busy after the abort |
| `FAILED` | — | still mounted after all of the above; preStop exits non-zero, so you get a `FailedPreStopHook` event |

Two things about that ladder are worth knowing, because they are not what
you would guess:

- **On a wedged mount the unmount rungs do not hang — they fail fast with
  `EBUSY`.** The parked readers hold files open, which is what makes the
  mount busy. So the problem was never that the old code blocked here; it
  was that `umount -l` *appeared to succeed* while leaving readers parked
  in the kernel and the connection alive.
- **Only aborting the FUSE connection releases those readers.** `SIGKILL`
  does not: the task is in uninterruptible sleep, so the signal is never
  delivered. `umount -l` does not either — it detaches the mount and
  leaves the readers exactly where they were.

Whether the mount is wedged is decided by a bounded read of
`/var/lib/lxc/lxcfs/proc/cpuinfo`, not by stat'ing the mount root: the
defect answers `getattr` on the root instantly. That probe can itself
park, so it only runs when `/sys/fs/fuse/connections` is writable and an
abort is therefore available to release it.

#### Grace period arithmetic

preStop has no timeout of its own. It shares
`terminationGracePeriodSeconds` with SIGTERM and the container's exit, and
kubelet SIGKILLs whatever is still running when the window closes — which
would leave the mount behind, possibly wedged, for the next Pod.

The chart therefore sets the grace period explicitly and derives the
script's budget from it:

```
terminationGracePeriodSeconds     60        (chart default; was the k8s default of 30)
LXCFS_UMOUNT_BUDGET               45        = max(5, 60 - 15), set as a container env var
  bind-mount phase              ≤ 30        = budget - LXCFS_HOST_TEARDOWN_RESERVE
  host mount reserve              15        never spendable by the bind phase
    mandatory rungs               13        = probe 5 + abort 3 + lazy detach 5  ≤ 15  ✓
headroom left in the grace period 15        hook start-up + SIGTERM + daemon exit
```

Every bounded operation in `--umount` is clamped to the time remaining in
the budget, so the worst case is `LXCFS_UMOUNT_BUDGET` plus one 50 ms poll
interval — independent of how many mutated containers the node runs. Before
this change the worst case was 8 targets × 2 rungs × `LXCFS_ACTION_TIMEOUT`
= **240 s per container**, unbounded in the number of containers, against a
30 s grace period.

The 15 s reserve is what guarantees the host mount is dealt with even when
there is not enough time for everything. If the bind phase runs out first,
the remaining bind mounts are left in place deliberately and logged: once
the connection is aborted they read `ENOTCONN` instead of hanging, and the
next Pod's postStart `--remount` replaces them. A leftover *host* mount is
the one failure a human has to fix on the node, so it wins the tie.

If you change `lxcfs.terminationGracePeriodSeconds`, the budget follows
automatically. Setting it below 20 is rejected by the values schema, and
the script raises its own budget and reserve at runtime if they are too
small for the rungs that must never be skipped.

### Recovery

Use this when a node has a wedged or leaked LXCFS mount: readers stuck in
`D` state, a DaemonSet Pod that will not go Ready or will not terminate,
or `Transport endpoint is not connected` from `/var/lib/lxc/lxcfs`.

**Most of this is now automatic.** From `0.4.0`, the procedure below is
what the scripts already do for you:

| Step | Done automatically by |
|---|---|
| mount `fusectl` if the node has not | both scripts, on demand |
| find the wedged connection for the mount point | both scripts, from `/proc/1/mountinfo` field 3 |
| abort it, releasing parked readers | `--umount` (preStop) and `entrypoint.sh` (startup) |
| unmount the leaked mount, lazily if needed | `--umount`, escalating; `entrypoint.sh` on startup |
| detach and re-bind mutated containers' bind mounts | `--remount` (postStart) |

So reach for the manual steps only when a node was left in this state by a
chart version **before** `0.4.0`, or when preStop reported `FAILED` /
you see a `FailedPreStopHook` event.

**What still needs a human, in every case:**

- **Restart workloads that cannot tolerate `ENOTCONN`.** Mutated Pods keep
  bind mounts into the old mount and read `ENOTCONN` until this
  DaemonSet's next postStart re-binds them. Nothing restarts them for you.
- **Kill orphaned `lxcfs` daemons**, if any survived their container.
  preStop deliberately does not `pkill lxcfs`: matching on a process name
  from a lifecycle hook risks killing the wrong daemon, and normally
  kubelet's SIGKILL of the container takes ours with it.
  ```sh
  pgrep -af '/usr/bin/lxcfs'
  ```
- **Clean up `volume-subpaths` binds.** Bind mounts that kubelet made
  *from* a file inside the FUSE mount to a path outside it are separate
  mounts sharing the same superblock. Detaching the mount point does not
  remove them, and they answer `ENOTCONN` after an abort. kubelet removes
  them when it tears the referencing Pods down.
- **Find out why the daemon stopped answering.** A wedged mount is an
  image or LXCFS bug, not a transient. Check the image tag against
  *What broke* above.

The manual procedure, for pre-`0.4.0` leftovers. Run on the affected node,
as root.

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
- **Do not skip step 2 because step 4 "works".** On a wedged mount
  `fusermount3 -u` and a plain `umount` fail fast with `EBUSY` — the
  parked readers hold files open — and `umount -l` then succeeds and
  clears the mount point while leaving those readers parked in the kernel
  and the connection alive. The abort is the only step that frees them.
- Killing the daemon also aborts the connection, because the kernel aborts
  it when the last `/dev/fuse` reference is closed. That is a valid
  alternative to step 2 when the daemon is still alive and you are
  removing it anyway — but it does nothing if the daemon has already gone
  while its readers remain parked.

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

- Rolling back to a version **before `0.4.0`** loses the preStop teardown,
  so from that point on every roll again leaves the previous daemon's mount
  at `/var/lib/lxc/lxcfs`. If that daemon was wedged, the mount is dead and
  the replacement Pod cannot mount over it — and pre-`0.4.0`
  `entrypoint.sh` will happily stack a second FUSE on the same path rather
  than refuse to start.
- Note the asymmetry: rolling *away* from `0.4.0` is what reintroduces the
  leak. `0.4.0`'s own preStop runs during the rollback, so the mount it
  leaves behind is clean; it is the versions that follow which stop
  cleaning up.
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
