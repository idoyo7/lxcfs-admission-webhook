# Migration guide

## 0.4.1 -> 0.4.2 (the postStart hook stops racing its own entrypoint)

Image-and-chart, no webhook change: `lxcfs.image.tag` moves from `7.0.0-2`
to `7.0.0-3`, the DaemonSet gains a `readinessProbe` and an explicit
`updateStrategy`, and its postStart hook gains a first stage. New values,
all with working defaults: `lxcfs.readinessProbe.*` and
`lxcfs.updateStrategy`.

### What broke

`0.4.1` fixed the bind logic correctly and then failed to run it. On the
production roll from `7.0.0-1` to `7.0.0-2`, three Alpine-based
`nginx-unprivileged` containers with a 128Mi limit came out of the roll
reporting the **node's** 65600692 kB instead of 131072 kB. Running the same
hook by hand minutes later fixed all of them:

```
nsenter -t 1 -m -- /var/lib/lxc/script/lxcfs-mount.sh --remount
INFO: remount finished in 24s: 48 bound, 24 already mounted, 48 source(s) absent, 0 failed
```

`48 bound` is the tell: postStart should already have bound those paths, in
which case the manual run would have called them *already mounted*.

**kubelet runs postStart concurrently with the container's ENTRYPOINT and
guarantees no ordering between them.** The hook then runs
`/var/lib/lxc/script/lxcfs-mount.sh` — a file on the node's hostPath, put
there by the release being *replaced*, which this container's entrypoint is
concurrently overwriting. Two independent defects follow, both reproduced
by driving real container lifecycles on a Docker-in-Docker node (the hook
fired the way kubelet fires it, immediately on container start, racing the
entrypoint):

| | Measured |
|---|---|
| canonical mount absent from the mount table at hook entry | 3 of 3 rolls |
| staged `lxcfs-mount.sh` still the previous release's copy at hook entry | 3 of 3 rolls |
| mutated Alpine container reading the node's `MemTotal` after the roll | 6 of 6 rolls |
| postStart exit code on those rolls | `0` — silent |

1. **The hook ran the outgoing release's script.** In 5 of 6 rolls the log
   showed `mount -B -v -o ro` — `0.4.0`'s invocation, which `0.4.1`
   replaced precisely because `-B` is util-linux-only and every
   Alpine-based container rejects it. So `0.4.1`'s fix did not take effect
   on the roll that deployed it: the `debian`-based workload was served
   (util-linux accepts `-B`), the Alpine one was not, and the hook still
   exited 0. That split by image family, not by timing, is what the
   production numbers show too — 6 containers the manual run had to bind,
   3 it found already bound.

2. **Worse, the two versions could be spliced together.** `cat src > dst`
   truncates in place, and bash does not read a script in one gulp — it
   reads, executes, and comes back at a saved offset. Rewriting the file
   underneath a running bash therefore executes a mixture. Observed:
   `tool: busybox ()` — `0.4.1`'s `resolve_container_tools` running against
   `0.4.0`'s variable block, so `$CONTAINER_BUSYBOX` was empty and every
   `nsenter` exited 127 — and a tally line printed with empty counters. The
   mechanism, isolated:

   ```
   rewrite in place -> prologue said VERSION=old, epilogue belongs to new
   rename(2)        -> prologue said VERSION=old, epilogue belongs to old
   ```

3. **The only synchronisation with the daemon was `sleep 3`** — a timer,
   not a fact, and one with no failure mode. When it guessed wrong, every
   source file looked absent, every container was skipped, and the hook
   exited **0**. Against a node whose mount is not up, `0.4.1` prints 24
   `does not exist, so … is left as the node's own` warnings and returns
   success; `0.4.2` refuses and exits 1.

Separately, `0.4.1` cried wolf. A container with no `/var/lib/lxc` mount in
its namespace was never an LXCFS consumer and can never be bound — but the
source probe resolves through `/proc/<pid>/root`, so such a container
reported all eight sources absent. On the production node that was six
`istio-proxy` sidecars, i.e. **48 warnings per roll that mean nothing**.
Worse, `resolve_container_tools` ran *before* that was noticed, so a
sidecar that is both distroless and not a consumer landed in
`REMOUNT_FAILED` and failed the whole node's hook. Reproduced: a distroless
non-consumer gives `REMOUNT_FAILED entries: 1` under `0.4.1` and `0` under
`0.4.2`.

### The fix

**1. `entrypoint.sh` stages atomically.** `lxcfs-mount.sh` is now written
to a temporary file and `rename(2)`d into place, the treatment the staged
busybox already got (truncating a running binary gets `ETXTBSY`). A reader
sees either the old inode, complete and never modified, or the new one —
never a splice.

**2. The postStart hook has two stages, and the order is the fix.**

```yaml
postStart:
  exec:
    command:
      - /bin/bash
      - -c
      - /lxcfs/lxcfs-ready.sh --wait && nsenter -t 1 -m -- /var/lib/lxc/script/lxcfs-mount.sh --remount
```

Stage one runs from **the image**, where it cannot be stale, and returns
only once two facts hold: the staged `lxcfs-mount.sh` and `busybox` are
byte-identical to this image's, and a read of
`/var/lib/lxc/lxcfs/proc/cpuinfo` through the mount **answers**. Stage two
is then guaranteed to be the current script running against a serving
mount. If stage one gives up, `&&` short-circuits and the hook fails, which
surfaces as `FailedPostStartHook`.

`--remount` also gates internally, so a manual run — or a hook command from
an older chart — gets the same guarantee instead of silently skipping every
container. On a healthy roll that second gate returns on its first poll.

Note what "serving" has to mean. The `7.0.0` defect answers `lookup` and
`getattr` on the mount root instantly and hangs only in `read()` of the
cpuview-backed files, so `mountpoint`, `stat` and `test -d` all report
success on a mount that will hang every consumer it is bound into.
Measured healthy start-up on an idle node: **~0.2s** from container start to
`/proc/cpuinfo` answering.

**3. Three buckets instead of one.** `container_is_consumer()` reads
`/proc/<pid>/mountinfo` — no exec, nothing that can block — and asks
whether the webhook ever injected into this container: does it carry
`/var/lib/lxc` (`cmd/volume.go`'s ninth mount, which survives preStop
removing the eight binds), or does it still have an LXCFS bind (which
covers a Pod mutated by a webhook older than that ninth mount)? Neither
means it is not a consumer, which is an ordinary skip. Asked *before*
anything is exec'd, so a distroless non-consumer can no longer fail the
hook.

| Case | `0.4.1` | `0.4.2` |
|---|---|---|
| container the webhook never injected into | 8 warnings each, counted as `source(s) absent` | counted as `container(s) not LXCFS consumers`, listed once, silent per container |
| LXCFS does not serve the file on this node | same warning, same bucket | counted as `not served by lxcfs`, named once for the node. Empty on `7.0.0`: all eight paths exist whatever `lxcfs.args` says |
| LXCFS serves it and the container cannot see it | same warning, exit 0 | **`ERROR`, counted as failed, exits non-zero** |

The tally changed shape:

```
# 0.4.1, healthy node with six sidecars
INFO: remount finished in 24s: 48 bound, 24 already mounted, 48 source(s) absent, 0 failed
+ 48 x WARN: ... does not exist, so ... is left as the node's own

# 0.4.2, same node
INFO: remount finished in 2s: 48 bound, 24 already mounted, 0 not served by lxcfs, 6 container(s) not LXCFS consumers, 0 failed
```

One consequence worth knowing: a Pod that *should* be a consumer but has
lost its `/var/lib/lxc` mount is now reported as a non-consumer rather than
warned about. It was not a failure in `0.4.1` either — it went into the
same `source(s) absent` bucket and exited 0 — so nothing regressed, but the
authoritative check is the Pod spec, not the hook log:

```sh
kubectl get pod <pod> -o jsonpath='{.spec.containers[*].volumeMounts[?(@.mountPath=="/var/lib/lxc/")].name}'
```

**4. `Ready` now means the mount serves.** The DaemonSet gets a
`readinessProbe` that reads a cpuview-backed file through the mount:

```yaml
lxcfs:
  readinessProbe:
    enabled: true
    initialDelaySeconds: 5
    periodSeconds: 10
    timeoutSeconds: 5
    failureThreshold: 3
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
```

During the `7.0.0` incident a Pod reported `1/1 Running` on a node where
every read through its mount hung forever, and the rolling update moved on
to the second node and wrecked that one too. With `maxUnavailable: 1` — now
spelled out in the template rather than left to the API default — a failing
probe stops the roll where it is.

### Why those probe numbers are safe

- **`timeoutSeconds: 5` against a slow-but-healthy node.** A healthy read
  of `/proc/cpuinfo` through the mount costs microseconds of CPU; measured
  round trip including the exec is 0.1s. The DaemonSet's `500m` limit
  throttles at a 100 ms period, so even a fully throttled daemon completes
  a request within one period. Five seconds is about four orders of
  magnitude of headroom. The script's own read deadline is derived as
  `max(1, timeoutSeconds - 2)` = 3s so that it always returns its own
  verdict, with a reason, rather than being killed and reported as an
  opaque probe timeout.
- **`failureThreshold: 3`, `periodSeconds: 10`, `initialDelaySeconds: 5`.**
  Three *consecutive* failures are needed, so a Pod is marked NotReady
  after ~35s. Healthy start-up is ~0.2s, and the early probes that run
  before the mount exists fail on a mount-table parse without touching the
  filesystem at all, so they cost nothing.
- **The probe cannot hang.** It never reads in the foreground:
  `lxcfs-ready.sh` backgrounds the read and polls. `timeout(1)` is not
  usable here — it would signal a task in uninterruptible sleep that cannot
  run to take the signal, and then block in `wait()` itself.
- **The probe cannot leak processes.** A read that parks is recorded (pid
  plus `/proc/<pid>/stat` start time, so pid reuse cannot fool it) *before*
  the wait, and while that task still exists no further read is started.
  **At most one parked task per container instance**, however long the
  mount stays wedged — versus one per period for a naive
  `exec: [cat, …]` probe, which is the accumulation that turned a
  pod-level defect into a node-level one. The record clears itself as soon
  as the task is gone, so recovery needs no manual step. Measured, with
  the daemon stopped so the mount stops answering:

  ```
  probe: rc=1 in 4.2s   <- fails, names the parked reader, does not hang
  probe: rc=1 in 0.1s   <- refuses to start a second read
  probe: rc=1 in 0.1s
  probe: rc=1 in 0.1s
  (daemon resumed)
  probe: rc=0 in 0.1s   <- ready again, marker cleared automatically
  ```

### Grace period arithmetic

The gate is derived from the same value as the teardown budget, so the two
cannot drift:

```
terminationGracePeriodSeconds     60
LXCFS_MOUNT_READY_TIMEOUT         45   = max(10, 60 - 15)   postStart gate
LXCFS_UMOUNT_BUDGET               45   = max(5,  60 - 15)   preStop teardown
  mandatory teardown rungs        13   = probe 5 + abort 3 + lazy detach 5
```

Start-up and termination are different phases of the same container and
never run at the same time. The only interleaving is a DELETE that lands
while the gate is still open: kubelet's per-Pod worker finishes the hook
before it starts killing, so the teardown begins up to 45s late. That is
survivable precisely because **the gate only stays open while the mount is
not serving**, and in that state the teardown is either
`none (not a mount point)` — a no-op — or the 13s mandatory ladder.
`45 + 13 = 58 <= 60`, so even the worst interleaving fits inside one grace
period, for any grace period, since both sides are derived from it.

`LXCFS_MOUNT_READY_TIMEOUT` can be overridden as a container env var if a
node genuinely needs longer; keep it below
`terminationGracePeriodSeconds - 13`.

### Upgrade steps

1. Bump the chart to `0.4.2`. `lxcfs.image.tag` moves to `7.0.0-3`
   automatically.
2. Verify the image first. `verify-lxcfs.sh image` now also asserts that
   the gate fails on a file that never answers and that the probe refuses
   to start a second read while one is parked:
   ```sh
   ./lxcfs-image/verify-lxcfs.sh image ghcr.io/idoyo7/lxcfs:7.0.0-3
   ```
3. Roll one node and read the DaemonSet Pod's log. A healthy node prints
   one `is serving; '/var/lib/lxc/lxcfs/proc/cpuinfo' answered after 0s`
   line and a tally whose last two fields are
   `N container(s) not LXCFS consumers, 0 failed`. It should print **no**
   `does not exist, so … is left as the node's own` lines at all — that
   message is gone.
4. Confirm the Pod goes Ready, which now means something:
   ```sh
   kubectl -n <ns> get pod -l app=<release>-daemonset
   kubectl -n <ns> exec <lxcfs-pod> -- /lxcfs/lxcfs-ready.sh; echo $?
   ```
5. Check the containers that were broken before. For an Alpine or
   distroless workload with a 128Mi limit, `MemTotal` must be `131072 kB`,
   not the node's:
   ```sh
   kubectl exec <pod> -- /var/lib/lxc/script/busybox head -1 /proc/meminfo
   ```

**This upgrade's own roll is safe with the old hook.** `0.4.1`'s staged
script can serve all three image families, so even when the roll runs it
(the window this release closes) the outcome is correct — verified: the
`7.0.0-2 -> 7.0.0-3` roll came out with all three workloads virtualized
either way. The fix matters for every *future* release that changes
`lxcfs-mount.sh`, and for the splice, which can corrupt any roll.

### One thing this release does not do

There is deliberately no `livenessProbe`. Killing the container on a wedged
mount races the preStop teardown ladder and can loop: the new container's
`entrypoint.sh` refuses to start on a mount it could not clear, so a
restart may CrashLoopBackOff instead of recovering. Readiness plus a halted
roll plus an alert is the chosen behaviour; when a human or kubelet does
remove the Pod, preStop performs the abort-and-detach recovery.

## 0.4.0 -> 0.4.1 (restores LXCFS in containers that ship no `mount`)

Image-and-scripts only. `values.yaml`, the templates and the webhook
binary are untouched, so this is a patch bump: `lxcfs.image.tag` moves
from `7.0.0-1` to `7.0.0-2` and nothing else in your values changes.

### What broke

`lxcfs-mount.sh` reached into each mutated container with

```sh
nsenter -t "$pid" -m    -- test -e "/proc/$file"
nsenter -t "$pid" -m -p -- mount -t fuse.lxcfs | grep -qs "/proc/$file"
nsenter -t "$pid" -m    -- mount -B -v -o ro "$src" "/proc/$file"
nsenter -t "$pid" -m -p -- umount -v "/proc/$file"
```

`nsenter -m` enters the target's mount namespace and *then* resolves the
program, so the binary has to exist inside the workload's image. Two
different image families do not have one:

| Image family | What happens | Symptom in the container |
|---|---|---|
| distroless (oauth2-proxy, istio-proxy, `gcr.io/distroless/*`, Chainguard) | no `test`, `mount`, `umount` or `sh` at all; `nsenter` exits 127 with `nsenter: failed to execute test: No such file or directory` | stale binds survive preStop and are never replaced, so every read of a virtualized file returns **`Transport endpoint is not connected`** |
| Alpine / busybox-based | `test` and `umount` work, but busybox's `mount` rejects `-B`: `mount: invalid option -- 'B'` | preStop *does* remove the binds and postStart cannot recreate them, so the container silently falls back to **the node's `/proc`** |

Either way the script read the failure as "the path is not mounted, so
there is nothing to do", logged nothing, and exited 0. The binds were
created correctly at Pod creation — kubelet makes those, not this script —
so the damage only appeared at the first DaemonSet roll after the Pod
started, and then persisted. On the cluster this was found on, three
oauth2-proxy Pods had been in that state for 75 days.

### The fix

Two of the three in-container calls turned out not to need a process in
the container at all, and are now done from the node through procfs:

- **Mount-table lookup** reads `/proc/<pid>/mountinfo`. procfs renders the
  mount table of whatever namespace the task is in, so `is_lxcfs_mounted`
  is now an `awk` over a text file. Strictly better than the old
  `mount -t fuse.lxcfs | grep`: no dependency, no fork of a `mount(8)` per
  path, and it cannot block on a wedged server because it never stat()s a
  mount point.
- **Existence probe** reads `/proc/<pid>/root/<path>`. That magic symlink
  is resolved by the kernel against the target's root *and* mount
  namespace, so a stat there traverses the same FUSE mount `test -e`
  traversed. Semantics are unchanged (existence, not readability). It can
  still block, so it stays inside the same bounded-probe machinery
  (`run_bounded`) as before — never `timeout(1)`, which would itself block
  in `wait()` on a reader parked in uninterruptible sleep.

`mount(2)` and `umount2(2)` act on the caller's mount namespace, so those
two genuinely have to run inside the target. The image now ships
`busybox-static` and `entrypoint.sh` stages it at
**`/var/lib/lxc/script/busybox`**, next to `lxcfs-mount.sh`. The webhook
already bind-mounts `/var/lib/lxc/` into every Pod it mutates
(`cmd/volume.go`, ninth mount, `HostToContainer`), so that path is
reachable inside every container this script touches — with no cooperation
from the workload's image, and no dynamic loader needed, which those
images also lack. Executing from a read-only mount is fine; only `noexec`
would stop it, and a hostPath mount does not carry it.

The invocation changed with it, because `-B` and `-v` are util-linux-only:

```sh
nsenter -t "$pid" -m -- /var/lib/lxc/script/busybox mount -o bind "$src" "$target"
nsenter -t "$pid" -m -- /var/lib/lxc/script/busybox mount -o remount,bind,ro,nosuid,nodev "$target" "$target"
```

Two calls, because `mount(2)` ignores `MS_RDONLY` on a bind — the new
mount inherits the source's flags — and only a second
`MS_REMOUNT|MS_BIND|MS_RDONLY` call makes it read-only. util-linux issues
that remount for you; busybox does not. `nosuid,nodev` are named because a
remount replaces the flags with exactly what it is given; `0.4.0`'s
`mount -B -o ro` dropped them, so a restored bind is now
*indistinguishable* from the one kubelet makes at Pod creation.

If the staged busybox is missing (a node still running an older image),
the script falls back to the container's own `mount`/`umount`, located by
stat()ing `/proc/<pid>/root/{usr/bin,bin,usr/sbin,sbin}` from the node so
an absent tool is discovered *before* anything is exec'd.

### It no longer fails silently

This was the actual defect: an exec failure was indistinguishable from
"nothing to do".

- `is_lxcfs_mounted` has three outcomes, not two: mounted, not mounted,
  and **could not find out**.
- Every bind is verified against the container's mount table afterwards,
  rather than trusted because the command exited 0.
- `nsenter`'s 126/127 exit statuses are reported as "could not execute
  anything inside that container", with the paths it looked in.
- `--remount` always prints a tally, including on a healthy run:
  `remount finished in 8s: 24 bound, 0 already mounted, 0 source(s)
  absent, 0 failed`. "Did no work" is now visibly different from "had no
  work to do".
- `--remount` exits **non-zero** when it could not complete work it was
  supposed to do, which surfaces as `FailedPostStartHook`. A container
  that merely exited mid-scan is reported but does not fail the hook —
  normal Pod churn must not take a node's hook down.

`--umount` keeps its exit semantics (it fails only when the canonical host
mount could not be cleared) but now reports containers it had to leave
alone.

Everything from `0.4.0` is unchanged: the bounded probes, the global
`--umount` deadline and its derivation from
`terminationGracePeriodSeconds`, the FUSE-connection abort ladder, and the
healthy-path timings.

### Before you upgrade

**Pods created before this fix keep working until the next DaemonSet
roll.** Their binds were made by kubelet at Pod creation and are still
intact; nothing in `0.4.0` removes them while the DaemonSet stays up. The
loss happens at the first roll after the Pod started — preStop tears the
canonical mount down and postStart cannot restore the binds — so *this
upgrade is itself such a roll*. Expect the following on nodes running
distroless or Alpine-based mutated Pods:

1. `0.4.0`'s preStop runs (it is the version being replaced), so those
   containers end the roll with either stale ENOTCONN binds (distroless)
   or no binds (Alpine).
2. `0.4.1`'s postStart then repairs both cases: it detaches a stale bind
   and re-binds it, and it creates a missing one.

So the repair is automatic, but there is a window — a few seconds on a
small node — during which a mutated container reads either ENOTCONN or the
node's `/proc`. Workloads that read these files once at startup (JVMs
sizing their heap, `GOMAXPROCS`, thread pools) do not notice; workloads
that read them continuously see one bad interval.

**Find the Pods that were already broken before this upgrade.** They will
not fix themselves until the roll reaches their node:

```sh
# distroless case: reads fail outright
kubectl get pods -A -o json |
  jq -r '.items[] | select(.metadata.annotations["mutating.lxcfs-admission-webhook.io/status"] == "mutated") |
         "\(.metadata.namespace)/\(.metadata.name) \(.spec.nodeName)"'
```

For each one, the honest check is the DaemonSet's own report on that node
after upgrading — `kubectl logs` the DaemonSet Pod and look for the
`remount finished` line and any `LXCFS bind mounts could not be restored`
block.

### Upgrade steps

1. Bump the chart to `0.4.1` (`helm repo update`, or
   `targetRevision: 0.4.1` for Argo CD). `lxcfs.image.tag` moves to
   `7.0.0-2` automatically.
2. Verify the image before it reaches a node. The checker now also asserts
   that the staged busybox can bind a virtualized file into a root with no
   other executable and no dynamic loader — the exact condition that broke:
   ```sh
   ./lxcfs-image/verify-lxcfs.sh image ghcr.io/idoyo7/lxcfs:7.0.0-2
   ```
   It fails against `7.0.0-1`, which is the point.
3. Roll one node first and read the DaemonSet Pod's log. A healthy node
   prints one `in-container mount tool = busybox (...)` line per mutated
   container and a `remount finished ... 0 failed` tally.
4. Confirm from inside a distroless Pod that values are cgroup-limited
   again. If it has no shell, the staged busybox is reachable inside it:
   ```sh
   kubectl exec <pod> -- /var/lib/lxc/script/busybox head -1 /proc/meminfo
   ```
   Compare against the node's own `MemTotal`; they must differ.

### If a container still cannot be served

`--remount` names it and exits non-zero. The two causes:

- **The node has no staged busybox.** The DaemonSet Pod is running an
  image older than `7.0.0-2`, or its entrypoint could not write to
  `{hostPath}/script`. `entrypoint.sh` refuses to start the daemon in that
  case, so a CrashLoopBackOff on the DaemonSet is the expected signal.
- **The Pod does not carry the `/var/lib/lxc/` mount.** It was mutated by
  a webhook version older than the ninth mount in `cmd/volume.go`.
  Recreate the Pod.

Both leave the container reading the node's `/proc`, which is wrong but
not dangerous; nothing hangs.

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
