#!/usr/bin/env bash

# adjust fuse.lxcfs filesystem mount in container after/before LXCFS DaemonSet start/stop

PATH=$PATH:/bin
LXC_PATH="/var/lib/lxc"
LXCFS_PATH="${LXC_PATH}/lxcfs"
LXCFS_SCRIPT_PATH="${LXC_PATH}/script"

UMOUNT=false
REMOUNT=false

# --------------------------------------------------------------------------
# Running mount/umount inside a container that ships neither
# --------------------------------------------------------------------------
# `nsenter -t <pid> -m -- <cmd>` enters the target's mount namespace and
# only *then* resolves <cmd>, so the binary has to exist in the target's
# filesystem. A distroless image (oauth2-proxy, istio-proxy, anything on
# gcr.io/distroless or a Chainguard base) has no test, mount, umount or
# even sh, so every one of those calls failed to exec -- and this script
# used to read the resulting non-zero status as "the path is not there"
# and skip the container without a word. See MIGRATION.md (0.4.0 ->
# 0.4.1).
#
# Two of the three in-container calls turned out not to need a container
# process at all and are now done from the host through procfs; see
# is_lxcfs_mounted() and probe_path(). mount(2) and umount2(2) act on the
# caller's mount namespace, so those two genuinely have to run inside the
# target, which means something executable must be reachable there.
#
# That something is a statically linked busybox. entrypoint.sh stages it
# into $LXCFS_SCRIPT_PATH, i.e. under $LXC_PATH, which the webhook
# bind-mounts into every Pod it mutates (cmd/volume.go, the ninth mount:
# MountPath /var/lib/lxc/, HostToContainer). It is therefore reachable at
# this exact absolute path inside every container this script ever touches,
# with no cooperation from the image, and being static it needs no dynamic
# loader either -- which a distroless image also lacks.
CONTAINER_BUSYBOX="${LXCFS_SCRIPT_PATH}/busybox"

# Where to look for the container's own mount/umount when the staged
# busybox is missing (an image built before 0.4.1, or a node whose
# /var/lib/lxc was not injected). Absolute paths, checked from the host
# via /proc/<pid>/root, so an image that ships them is still served and
# one that does not is *reported* rather than silently skipped.
CONTAINER_TOOL_DIRS=(/usr/bin /bin /usr/sbin /sbin)

# Set by resolve_container_tools() for the container being processed.
CT_MOUNT=()
CT_UMOUNT=()
CT_KIND="none"

# Every probe and mount operation below touches the LXCFS FUSE mount, and
# a FUSE mount whose daemon has stopped answering blocks its readers in
# uninterruptible sleep. Unbounded, that turns one bad file handler into an
# unrecoverable node: the postStart hook never returns, so the container
# never goes Ready; kubelet deletes the Pod but the preStop hook blocks
# identically, so the container cannot be killed; orphaned lxcfs daemons
# accumulate holding the mount. Bound every such operation instead, and
# fail loudly.
#
# Override via the container env if a very large node needs longer.
PROBE_TIMEOUT="${LXCFS_PROBE_TIMEOUT:-5}"
ACTION_TIMEOUT="${LXCFS_ACTION_TIMEOUT:-15}"

# Paths whose probe timed out, i.e. paths served by a wedged FUSE mount.
WEDGED_PATHS=()

# --------------------------------------------------------------------------
# --remount accounting
# --------------------------------------------------------------------------
# Telling these apart is the whole point of the 0.4.1 and 0.4.2 passes.
# 0.4.0 had one bucket -- "non-zero, so presumably nothing to do" -- which
# collapsed "the path is not mounted" together with "I could not find
# out", and the second case then produced no log line at all. Three
# oauth2-proxy Pods sat unvirtualized for 75 days behind that silence.
#
# 0.4.1 split out "could not find out" but still had one bucket, called
# "source absent", for three unrelated facts:
#
#   1. this container was never an LXCFS consumer, so there is nothing to
#      bind -- normal, and by far the commonest of the three;
#   2. LXCFS does not serve this file at all -- a property of the node's
#      daemon, not of any container. Empty on LXCFS 7.0.0, which creates
#      all eight paths regardless of lxcfs.args, but it is the only way to
#      tell case 3 apart from a node that simply has fewer files;
#   3. LXCFS does serve it and this container cannot see it -- a defect.
#
# All three printed "'<src>' does not exist, so '<target>' is left as the
# node's own", eight times per container. On a healthy node with six
# service-mesh sidecars that is 48 warnings per roll that mean nothing,
# which is how the one that means something gets missed. They are now
# counted separately, only (3) warns, and only (3) fails the hook.
REMOUNT_BOUND=0              # binds this run created
REMOUNT_ALREADY=0            # already bound, nothing to do
REMOUNT_NOT_SERVED=0         # (2) lxcfs does not serve this file
REMOUNT_FAILED=()            # hard failures -> non-zero exit
REMOUNT_DEGRADED=()          # done, but not exactly as intended
UNREACHABLE_CONTAINERS=()    # container exited mid-scan; normal churn
UNTOOLED_CONTAINERS=()       # nothing executable reachable inside
NON_CONSUMER_CONTAINERS=()   # (1) never had LXCFS mounts to restore

# --------------------------------------------------------------------------
# Is the canonical mount serving? (--remount precondition)
# --------------------------------------------------------------------------
# kubelet runs postStart CONCURRENTLY with the container's ENTRYPOINT and
# guarantees no ordering between them, so this script can start before
# entrypoint.sh has cleared the previous daemon's mount, before it has
# staged anything, and before lxcfs has FUSE-mounted $LXCFS_PATH. Measured
# on a Docker-in-Docker node driving real rolls: at hook entry the
# canonical mount was absent from the mount table in 3 out of 3 rolls.
#
# 0.4.1's entire answer to that was `sleep 3` -- a timer, not a fact, and
# one with no failure mode: when it guessed wrong every source file looked
# absent, every container was skipped, and the hook exited 0. A node could
# therefore complete a roll with nothing bound and nothing said.
#
# So --remount now refuses to iterate containers until $LXCFS_PATH is
# actually SERVING, and fails loudly when it never does. "Serving" has to
# mean a cpuview-backed file answers a read: the LXCFS 7.0.0 defect
# answers lookup and getattr on the mount root instantly and hangs only in
# read(), so `mountpoint`, `stat` and even `test -d` all report success on
# a mount that will hang every consumer it is bound into.
MOUNT_READY_TIMEOUT="${LXCFS_MOUNT_READY_TIMEOUT:-45}"
READY_PROBE_FILE="${LXCFS_READY_PROBE_FILE:-/proc/cpuinfo}"

# Set when the precondition never held, so discovery is skipped and the
# run exits non-zero rather than reporting a clean sweep of nothing.
GATE_FAILED=false

# Targets $LXCFS_PATH does not serve on this node, as a padded string so
# membership is a substring test and no bash 4 associative array is
# needed (this file also runs under whatever bash the *node* ships).
SOURCES_NOT_SERVED=" "

# --------------------------------------------------------------------------
# Global deadline for --umount
# --------------------------------------------------------------------------
# preStop does not get a timeout of its own: it shares the Pod's
# terminationGracePeriodSeconds with SIGTERM and the container's own exit,
# and kubelet SIGKILLs whatever is still running when that runs out. Being
# SIGKILLed halfway through a teardown is the worst outcome available --
# the canonical FUSE mount survives, possibly wedged, and the next Pod
# inherits it -- so --umount runs against one wall-clock budget rather
# than a bag of independent per-operation timeouts.
#
# Every bounded operation in the --umount path is clamped to the time left
# in this budget, which makes the worst case UMOUNT_BUDGET plus one poll
# interval, regardless of how many containers the node runs. See
# charts/lxcfs-admission-webhook/MIGRATION.md for the arithmetic against
# terminationGracePeriodSeconds; the chart derives this value from the
# grace period so the two cannot drift.
UMOUNT_BUDGET="${LXCFS_UMOUNT_BUDGET:-45}"

# Slice of the budget the per-container bind-mount loop may not touch, so
# that the canonical host mount is always torn down even on a node with
# more mutated containers than there is time for.
#
# Losing bind mounts is recoverable and losing the host mount is not: a
# leftover bind reads ENOTCONN once the connection is aborted, and the
# next Pod's postStart --remount detaches and re-binds it. A leftover
# wedged host mount parks every reader in uninterruptible sleep and needs
# a human on the node.
HOST_TEARDOWN_RESERVE="${LXCFS_HOST_TEARDOWN_RESERVE:-15}"

# Aborting a FUSE connection is a sysfs write with no server behind it and
# a lazy umount is MNT_DETACH, which never waits on the filesystem or on
# anyone still attached. Neither can block, so these bounds exist only to
# catch something pathological.
ABORT_TIMEOUT=3
LAZY_TIMEOUT=5

# How many stacked mounts to drain from a single mount point. More than
# one is the signature of the failure this whole path exists for: a new
# daemon mounted a second FUSE over a path whose first mount refused to
# go, after which everything touching the path blocked forever.
MAX_STACKED_MOUNTS=4

# Absolute deadlines, in $SECONDS. Filled in by main() once the action is
# known; --remount deliberately gets a deadline far enough out to be no
# deadline at all, so its behaviour is exactly what it was before.
DEADLINE=0
BIND_DEADLINE=0

# Set once --umount has walked the ladder, for the closing summary.
HOST_TEARDOWN_RUNG="not attempted"
BIND_BUDGET_EXHAUSTED=false
SKIPPED_BIND_TARGETS=0

# How often run_bounded checks on its child. This is pure latency for the
# healthy path -- a node with many mutated Pods runs 16 probes per
# container -- so keep it small. Not every sleep(1) accepts a fraction,
# so degrade to whole seconds where it does not.
POLL_INTERVAL=0.05
sleep "$POLL_INTERVAL" 2>/dev/null || POLL_INTERVAL=1

# The precondition gate polls a mount table, which is cheap but not free,
# and it may do so for tens of seconds; it does not need 50 ms resolution.
# Derived rather than probed so start-up does not pay a second sleep.
READY_POLL_INTERVAL=0.5
[[ "$POLL_INTERVAL" == 1 ]] && READY_POLL_INTERVAL=1

# Run a command with a hard wall-clock bound.
#   0   command succeeded
#   1.. command's own exit status
#   124 command did not finish in time
#
# Deliberately NOT implemented with timeout(1). A read against a wedged
# FUSE mount sits in uninterruptible sleep (D state): timeout(1) would
# send SIGTERM, the target could not run to handle it, and timeout(1)
# itself would then block forever in wait(). Polling from the parent lets
# this script give up and report while the doomed child stays parked until
# someone aborts the FUSE connection.
run_bounded() {
  local seconds=$1
  shift

  local child rc deadline=$((SECONDS + seconds))
  "$@" &
  child=$!

  while kill -0 "$child" 2>/dev/null; do
    if ((SECONDS >= deadline)); then
      return 124
    fi
    sleep "$POLL_INTERVAL"
  done

  wait "$child"
  rc=$?
  return "$rc"
}

# Seconds left before <deadline>, floored at 0.
time_left() {
  local left=$(($1 - SECONDS))
  ((left < 0)) && left=0
  echo "$left"
}

# run_bounded clamped to an absolute deadline: the operation gets the
# smaller of its own timeout and whatever is left of the budget, and is
# not started at all once the budget is gone.
#   124  timed out, or there was no time left to try
run_bounded_until() {
  local deadline=$1 seconds=$2
  shift 2

  local left
  left=$(time_left "$deadline")
  ((left <= 0)) && return 124
  ((seconds > left)) && seconds=$left

  run_bounded "$seconds" "$@"
}

# --------------------------------------------------------------------------
# FUSE connection control
# --------------------------------------------------------------------------
# fusectl exposes one directory per live FUSE connection, and the `abort`
# file in it is the only way to release a task already parked in
# fuse_simple_request(). Such a task is in uninterruptible sleep, so it
# never runs to take a signal: SIGKILL is queued and never delivered.
# Aborting makes the kernel fail every outstanding and future request on
# the connection with ENOTCONN, at which point the parked task returns,
# sees the error and exits normally.
FUSECTL_PATH="/sys/fs/fuse/connections"

# Which mount table describes the namespace the canonical mount lives in.
#
# The canonical mount is created with mountPropagation: Bidirectional and
# therefore lives in the host mount namespace, which is PID 1's. The
# lifecycle hooks already enter it (`nsenter -t 1 -m`) so /proc/self would
# usually do, but reading PID 1's directly also makes this correct when
# the script is run straight from the container.
mountinfo_file() {
  if [[ -r /proc/1/mountinfo ]]; then
    echo /proc/1/mountinfo
  else
    echo /proc/self/mountinfo
  fi
}

# Is <path> a mount point according to the mount table <file>?
#
# Parses the mount table only -- it never stat()s the path, so unlike
# mountpoint(1) it cannot block on a wedged FUSE server. Field 5 is the
# mount point, expressed relative to the root of the process whose table
# this is, which for both /proc/1 and a container's PID 1 is "/".
is_mounted_in() {
  awk -v p="$2" '$5 == p { found = 1 } END { exit !found }' "$1"
}

# Is <path> a mount point in the namespace the canonical mount lives in?
is_mounted_at() {
  is_mounted_in "$(mountinfo_file)" "$1"
}

# Is <path> a FUSE mount according to the mount table <file>?
#
# Same field layout as fuse_minors_for below: the filesystem type is the
# field just past the " - " separator. A bind mount of a file inside a
# fuse.lxcfs mount reports that same type, which is what makes this a
# drop-in for the old `mount -t fuse.lxcfs | grep` test.
is_fuse_mounted_in() {
  awk -v p="$2" '
    {
      fstype = ""
      for (i = 7; i <= NF; i++)
        if ($i == "-") { fstype = $(i + 1); break }
      if ($5 == p && fstype ~ /^fuse/) found = 1
    }
    END { exit !found }
  ' "$1"
}

# Minor device number of every FUSE connection mounted at <path>, topmost
# mount last.
#
# mountinfo field 3 is "major:minor"; FUSE always reports major 0 and the
# minor is the directory name under $FUSECTL_PATH. Field 5 is the mount
# point, and the filesystem type is the field just past the " - "
# separator. More than one line can match: stacked mounts are exactly the
# state this exists to clean up.
fuse_minors_for() {
  awk -v p="$1" '
    {
      fstype = ""
      for (i = 7; i <= NF; i++)
        if ($i == "-") { fstype = $(i + 1); break }
      if ($5 == p && fstype ~ /^fuse/) {
        split($3, dev, ":")
        print dev[2]
      }
    }
  ' "$(mountinfo_file)"
}

# Make $FUSECTL_PATH usable, mounting fusectl if nothing has yet.
#
# systemd mounts it as soon as the fuse module loads, but that is a
# convention rather than a guarantee, and the mount namespace we are in
# may simply not have inherited it. fusectl is not namespaced -- it lists
# every connection on the kernel -- and mounting it needs only the
# CAP_SYS_ADMIN the DaemonSet already has from `privileged: true`.
#
# Cannot block: there is no server behind fusectl.
fusectl_ready() {
  [[ -d "$FUSECTL_PATH" ]] || return 1

  if awk -v p="$FUSECTL_PATH" '
       {
         fstype = ""
         for (i = 7; i <= NF; i++)
           if ($i == "-") { fstype = $(i + 1); break }
         if ($5 == p && fstype == "fusectl") found = 1
       }
       END { exit !found }
     ' /proc/self/mountinfo; then
    return 0
  fi

  echo "INFO: fusectl is not mounted at ${FUSECTL_PATH}; mounting it"
  mount -t fusectl none "$FUSECTL_PATH" 2>/dev/null
}

# Requests the kernel has handed to the daemon and not had answered. Zero
# on a healthy idle mount; non-zero and not draining means the daemon
# accepted work and stopped answering. Reading it cannot block.
fuse_waiting() {
  cat "${FUSECTL_PATH}/${1}/waiting" 2>/dev/null || echo '?'
}

# Abort one FUSE connection by minor number.
fuse_abort() {
  local minor=$1
  local abort="${FUSECTL_PATH}/${minor}/abort"

  if [[ ! -w "$abort" ]]; then
    echo "WARN: '${abort}' is not writable; cannot abort FUSE connection ${minor}" >&2
    return 1
  fi

  echo "INFO: aborting FUSE connection ${minor} (waiting=$(fuse_waiting "$minor"))"
  echo 1 >"$abort"
}

# Abort every FUSE connection currently mounted at <path>, resolved fresh
# from the mount table. Zero if at least one abort succeeded.
fuse_abort_at() {
  local path=$1 minor aborted=1 minors

  minors=$(fuse_minors_for "$path")
  if [[ -z "$minors" ]]; then
    echo "WARN: no FUSE connection resolves to '${path}'; nothing to abort" >&2
    return 1
  fi

  while read -r minor; do
    [[ -n "$minor" ]] || continue
    if run_bounded_until "$DEADLINE" "$ABORT_TIMEOUT" fuse_abort "$minor"; then
      aborted=0
    fi
  done <<<"$minors"

  return "$aborted"
}

# One-byte read, used as a responsiveness probe.
#
# A function rather than an inline command because run_bounded backgrounds
# "$@" and cannot carry a redirection. `read` is a bash builtin, so this
# needs no head/dd on the host, and the open()+read() it performs is
# exactly the operation that hangs on a wedged mount.
probe_read() {
  # No variable name, so the byte lands in $REPLY and is discarded: only
  # whether the read completed at all matters here.
  #
  # stderr is dropped because of what happens to a probe that timed out:
  # it stays parked until the abort below releases it, at which point its
  # read fails with ENOTCONN and bash prints "read error: Connection
  # aborted" into the hook log, long after this function's caller gave up
  # on it. That line is expected and says nothing the caller has not
  # already reported.
  read -r -n 1 <"$1" 2>/dev/null
}

# umount helpers, wrapped so run_bounded can background them and so the
# nsenter is in one place. The hooks already run in the host mount
# namespace; re-entering it is a no-op there and makes the script correct
# when it is run directly inside the container instead.
host_umount() {
  nsenter -t 1 -m -- umount -v "$1"
}

host_umount_lazy() {
  nsenter -t 1 -m -- umount -lv "$1"
}

# Does <path> exist, as seen from inside the container's mount namespace?
#
# A function rather than an inline test because run_bounded backgrounds
# "$@" and needs something to background.
host_view_exists() {
  [[ -e "$1" ]]
}

# Bounded existence check for <path> inside a container's mount namespace,
# performed entirely from the host.
#   0   path exists
#   1   path does not exist
#   124 probe timed out -> the FUSE mount is not answering
#
# /proc/<pid>/root is a magic symlink: the kernel resolves everything
# below it against the target's root *and* the target's mount namespace,
# so a stat there traverses exactly the mounts `test -e` inside the
# container traversed -- including the LXCFS bind, and therefore the FUSE
# server. Semantics are unchanged from the `nsenter -m -- test -e` this
# replaces (existence, not readability), but no process runs in the
# container, so it works in an image that contains no executables at all.
#
# It can still block, because a stat of a broken or wedged FUSE mount can,
# which is why it stays inside run_bounded and never uses timeout(1).
probe_path() {
  local container_pid=$1 path=$2 rc

  run_bounded "$PROBE_TIMEOUT" host_view_exists "/proc/${container_pid}/root${path}"
  rc=$?

  if [[ $rc -eq 124 ]]; then
    echo "ERROR: probing '$path' in pid $container_pid timed out after ${PROBE_TIMEOUT}s;" \
         "the LXCFS FUSE mount is not answering" >&2
    WEDGED_PATHS+=("pid ${container_pid}: ${path}")
  fi

  return $rc
}

# Is <path> currently a fuse.lxcfs mount in this container?
#   0  mounted
#   1  not mounted
#   2  could not find out
#
# Reads /proc/<pid>/mountinfo from the host. procfs renders the mount
# table of whatever namespace that task is in, so this needs no process in
# the container -- unlike the `nsenter -t <pid> -m -p -- mount -t
# fuse.lxcfs | grep` it replaces, which could not work in a distroless
# container at all: nsenter resolved `mount` in the target's filesystem,
# found nothing, and the pipeline still exited 1 through grep, so the
# caller was told "not mounted".
#
# Strictly better than the old form even where the old form worked: no
# dependency, no fork of a mount(8) and a grep per path, and it cannot
# block, because it parses a text file rather than stat()ing mount points.
#
# The third exit status is the point of this whole change. "I looked and
# it is not there" and "I could not look" are different facts and the
# caller must be able to act on the difference.
is_lxcfs_mounted() {
  local container_pid=$1 path=$2
  local file="/proc/${container_pid}/mountinfo"

  if [[ ! -r "$file" ]]; then
    echo "WARN: cannot read '${file}'; unable to tell whether '${path}' is" \
         "mounted in pid ${container_pid}" >&2
    return 2
  fi

  is_fuse_mounted_in "$file" "$path"
}

# Which executable can run mount/umount inside pid <pid>, and how.
#
# Sets CT_MOUNT / CT_UMOUNT to a full argv prefix and CT_KIND to a label
# for the log. Returns 1 when nothing is reachable, which the callers
# report rather than swallow.
#
# busybox first, always: it is the one option that does not depend on the
# workload's image. Both candidates are located by stat()ing the
# container's filesystem through /proc/<pid>/root from the host, so an
# absent tool is discovered before anything is exec'd instead of showing
# up as an exec failure afterwards. Those stats traverse the container's
# root filesystem and the node's /var/lib/lxc -- never the LXCFS mount --
# so they cannot block on a wedged FUSE server.
resolve_container_tools() {
  local container_pid=$1
  local root="/proc/${container_pid}/root" dir

  CT_MOUNT=()
  CT_UMOUNT=()
  CT_KIND="none"

  if [[ -x "${root}${CONTAINER_BUSYBOX}" ]]; then
    CT_KIND="busybox (${CONTAINER_BUSYBOX})"
    # No -p. busybox needs nothing from /proc for a bind or a umount, and
    # entering one namespace instead of two is one failure mode fewer.
    CT_MOUNT=(nsenter -t "$container_pid" -m -- "$CONTAINER_BUSYBOX" mount)
    CT_UMOUNT=(nsenter -t "$container_pid" -m -- "$CONTAINER_BUSYBOX" umount)
    return 0
  fi

  for dir in "${CONTAINER_TOOL_DIRS[@]}"; do
    [[ -x "${root}${dir}/mount" && -x "${root}${dir}/umount" ]] || continue
    CT_KIND="container's own (${dir})"
    # -m -p, as 0.4.0 used for umount: util-linux's umount canonicalizes
    # its argument against /proc/self/mountinfo, and /proc inside the
    # container belongs to the container's PID namespace, so /proc/self
    # only resolves for a task that is in it.
    CT_MOUNT=(nsenter -t "$container_pid" -m -p -- "${dir}/mount")
    CT_UMOUNT=(nsenter -t "$container_pid" -m -p -- "${dir}/umount")
    return 0
  done

  return 1
}

# Say why an in-container command failed, in the caller's terms.
#
# nsenter exits 127 when it could not execute the program in the target's
# mount namespace and 126 when it found it but could not run it. That is
# precisely the status 0.4.0 discarded, and discarding it is what made a
# distroless container indistinguishable from a container with nothing to
# do.
describe_exec_failure() {
  local rc=$1 container_pid=$2 what=$3

  case $rc in
  124)
    echo "ERROR: ${what} in pid ${container_pid} did not finish within" \
         "${ACTION_TIMEOUT}s" >&2
    ;;
  126 | 127)
    echo "ERROR: could not execute ${what} inside pid ${container_pid}" \
         "(nsenter exit ${rc}). Nothing runnable is reachable in that" \
         "container's mount namespace." >&2
    ;;
  *)
    echo "ERROR: ${what} in pid ${container_pid} failed with exit ${rc}" >&2
    ;;
  esac
}

# umount that survives a dead mount. A plain umount of a wedged FUSE mount
# can block on the server, so fall back to a lazy umount, which detaches
# the mount from the tree without waiting for anyone still stuck on it.
#
# Both rungs are clamped to $BIND_DEADLINE, which for --umount fences the
# per-container work off from the reserve kept for the host mount, and for
# --remount is far enough out to leave the original per-operation
# behaviour untouched.
#
# Requires resolve_container_tools() to have run for this pid. -v is gone
# from both rungs: busybox's umount does not document it, and the echo
# above the call already records what ran.
bounded_umount() {
  local container_pid=$1 path=$2 rc

  echo "${CT_UMOUNT[@]}" "$path"
  run_bounded_until "$BIND_DEADLINE" "$ACTION_TIMEOUT" "${CT_UMOUNT[@]}" "$path"
  rc=$?
  if ((rc == 0)); then
    return 0
  fi
  describe_exec_failure "$rc" "$container_pid" "umount of '${path}'"

  echo "WARN: umount of '$path' in pid $container_pid did not succeed;" \
       "retrying lazily (umount -l)" >&2
  run_bounded_until "$BIND_DEADLINE" "$ACTION_TIMEOUT" "${CT_UMOUNT[@]}" -l "$path"
}

# Bind <source> over <target> inside pid <pid>, read-only, and verify it.
#
# Requires resolve_container_tools() to have run for this pid.
#
# Two calls rather than one `mount -B -o ro`. mount(2) ignores MS_RDONLY
# on a bind -- the new mount inherits the source's rw/ro -- so read-only
# needs a second, MS_REMOUNT|MS_BIND|MS_RDONLY call. util-linux hides that
# by issuing the remount for you; busybox does not, and its `mount -o
# bind,ro` yields a read-write mount. Spelling both steps out makes the
# result identical whichever tool ran. `-o bind` and the two-argument
# `-o remount,bind,ro` are the spellings both tools accept; -B and -v are
# util-linux-only, which is why 0.4.0's `mount -B` also failed on every
# Alpine-based container, whose busybox mount rejects it.
#
# nosuid,nodev are named explicitly because a remount replaces the mount's
# flags with exactly what it is given: asking only for `ro` drops them.
# 0.4.0's `mount -B -o ro` dropped them too, so this is not a regression
# but a small correction -- the LXCFS mount they come from carries them
# (libfuse mounts nosuid,nodev), and so do the equivalent mounts kubelet
# makes at Pod creation, which means a bind restored here is now
# indistinguishable from the one it replaces.
CONTAINER_BIND_OPTS="remount,bind,ro,nosuid,nodev"

container_bind_ro() {
  local container_pid=$1 source=$2 target=$3 rc

  echo "${CT_MOUNT[@]}" -o bind "$source" "$target"
  run_bounded "$ACTION_TIMEOUT" "${CT_MOUNT[@]}" -o bind "$source" "$target"
  rc=$?
  if ((rc != 0)); then
    describe_exec_failure "$rc" "$container_pid" "bind of '${target}'"
    return 1
  fi

  if ! run_bounded "$ACTION_TIMEOUT" \
         "${CT_MOUNT[@]}" -o "$CONTAINER_BIND_OPTS" "$target" "$target"; then
    echo "WARN: pid ${container_pid}: '${target}' is bound but could not be" \
         "remounted read-only, so it stays writable. LXCFS ignores writes, so" \
         "this is cosmetic, but it is not what this script asked for." >&2
    REMOUNT_DEGRADED+=("pid ${container_pid}: ${target}: bound read-write")
  fi

  # Assert the end state rather than trust the exit status. A mount that
  # reports success while the path is absent from the container's mount
  # table is exactly the silent failure this release exists to remove, and
  # the check is a text-file parse, so it costs nothing.
  is_lxcfs_mounted "$container_pid" "$target"
}

# Tear down the canonical LXCFS FUSE mount in the host mount namespace.
#
# Why this belongs in preStop. The mount is made inside the container, but
# the volume carries mountPropagation: Bidirectional, so the mount lands
# in the host mount namespace and outlives the container that made it.
# Nothing else removes it. Leaving it for the *next* Pod's entrypoint to
# clear is what turned a rolling upgrade into a two-node outage: by then
# the daemon is gone, so fusermount cannot talk to it, and the mount is
# busy (kubelet's own volume-subpaths binds reference it), so the unmount
# fails -- and the new daemon then mounts a second FUSE over the same
# path, after which every access to it blocks forever. preStop is the only
# moment at which our own daemon is still alive to answer, i.e. the only
# moment the graceful rung can work.
#
# Escalates one rung at a time and logs which one cleared it, so a
# postmortem can tell a healthy roll from a rescued one:
#
#   none      not a mount point
#   graceful  fusermount3 -u / fusermount -u
#   abort     connection aborted, then a plain umount
#   lazy      MNT_DETACH, with or without a preceding abort
#   FAILED    still mounted after all of them
#
# The one state this must never leave behind is "mounted and not
# answering", so the lazy rung is unconditional and is the last thing the
# reserve pays for.
lxcfs_host_umount() {
  local path="$LXCFS_PATH"
  local minors="" can_abort=false aborted=false probe_rc=0 wedged=false
  local pass=0 lazy_ran=false

  if ! is_mounted_at "$path"; then
    HOST_TEARDOWN_RUNG="none (not a mount point)"
    echo "INFO: '${path}' is not a mount point; no host-side teardown needed"
    return 0
  fi

  if fusectl_ready; then
    can_abort=true
    minors=$(fuse_minors_for "$path")
    if [[ -n "$minors" ]]; then
      echo "INFO: '${path}' is backed by FUSE connection(s):" "$minors"
    else
      echo "WARN: '${path}' is mounted but resolves to no FUSE connection;" \
           "treating it as a plain mount" >&2
    fi
  else
    echo "WARN: '${FUSECTL_PATH}' is unavailable, so a wedged FUSE connection" \
         "cannot be aborted from here. Skipping the responsiveness probe as" \
         "well: it would park a reader that nothing could then release." >&2
  fi

  # Rung 1 -- is the mount answering?
  #
  # Read a cpuview-backed file rather than stat()ing the mount root. The
  # defect that wedges this mount answers lookup and getattr instantly and
  # only hangs in read(), so a stat proves nothing. This probe can itself
  # park unkillably, which is why it only runs when an abort is available
  # to release it, a few lines below.
  if [[ "$can_abort" == true ]]; then
    run_bounded_until "$DEADLINE" "$PROBE_TIMEOUT" probe_read "${path}/proc/cpuinfo"
    probe_rc=$?
    if ((probe_rc == 124)); then
      wedged=true
      WEDGED_PATHS+=("host mount: ${path}/proc/cpuinfo")
      echo "ERROR: '${path}/proc/cpuinfo' did not answer within ${PROBE_TIMEOUT}s;" \
           "the FUSE mount is wedged. Skipping the graceful rung." >&2
    fi
  fi

  # Rung 2 -- graceful, and only while the mount still answers. fusermount
  # talks to the daemon, so on a wedged mount it can only burn budget.
  #
  # nsenter resolves the binary in the host mount namespace, matching
  # entrypoint.sh: the node may ship fuse3 (fusermount3) or fuse2
  # (fusermount).
  if [[ "$wedged" == false ]]; then
    if run_bounded_until "$DEADLINE" "$ACTION_TIMEOUT" \
         nsenter -t 1 -m -- fusermount3 -u "$path"; then
      : # unmounted, or at least fusermount thinks so; verified below
    elif run_bounded_until "$DEADLINE" "$ACTION_TIMEOUT" \
           nsenter -t 1 -m -- fusermount -u "$path"; then
      :
    fi

    if ! is_mounted_at "$path"; then
      HOST_TEARDOWN_RUNG="graceful (fusermount -u)"
      echo "INFO: host teardown rung=graceful; '${path}' unmounted"
      return 0
    fi

    echo "WARN: graceful unmount left '${path}' mounted; escalating" >&2
  fi

  # Rung 3 -- abort the connection, releasing anything parked on it.
  if [[ "$can_abort" == true ]] && fuse_abort_at "$path"; then
    aborted=true
  fi

  # Rung 4 -- plain umount, now that nothing is parked on the connection.
  if run_bounded_until "$DEADLINE" "$ACTION_TIMEOUT" host_umount "$path" &&
     ! is_mounted_at "$path"; then
    if [[ "$aborted" == true ]]; then
      HOST_TEARDOWN_RUNG="abort + umount"
    else
      HOST_TEARDOWN_RUNG="umount"
    fi
    echo "INFO: host teardown rung=${HOST_TEARDOWN_RUNG}; '${path}' unmounted"
    return 0
  fi

  # Rung 5 -- lazy detach, then drain whatever is stacked underneath.
  #
  # MNT_DETACH takes the mount out of the namespace without waiting for
  # the filesystem or for anyone still attached, so it cannot block. A
  # second mount only becomes visible at this path once the one above it
  # is gone, so each pass has to re-resolve the connection.
  while is_mounted_at "$path" &&
        ((pass < MAX_STACKED_MOUNTS)) &&
        (($(time_left "$DEADLINE") > 0)); do
    pass=$((pass + 1))
    if ((pass > 1)); then
      echo "WARN: '${path}' is still a mount point; a stacked mount is" \
           "underneath (pass ${pass})" >&2
    else
      echo "WARN: detaching '${path}' lazily (umount -l)" >&2
    fi

    # Re-abort only when there is a reason to: either rung 3 never got to
    # (no fusectl, or nothing resolved), or a further pass has revealed a
    # different connection stacked underneath. Aborting the same
    # connection twice is harmless but makes the log read as if something
    # went wrong twice.
    if [[ "$can_abort" == true ]] && { [[ "$aborted" == false ]] || ((pass > 1)); }; then
      if fuse_abort_at "$path"; then
        aborted=true
      fi
    fi
    run_bounded_until "$DEADLINE" "$LAZY_TIMEOUT" host_umount_lazy "$path"
    lazy_ran=true
  done

  if is_mounted_at "$path"; then
    HOST_TEARDOWN_RUNG="FAILED (still mounted after ${pass} lazy pass(es))"
    echo "ERROR: '${path}' is still mounted after every rung." >&2
    return 1
  fi

  # Name the rung by what actually ran, not by where control ended up: the
  # plain umount can report failure and still have cleared the mount, and
  # a log that claims a lazy detach happened when it did not is worse than
  # no log at all.
  local how="umount"
  [[ "$lazy_ran" == true ]] && how="lazy umount"
  if [[ "$aborted" == true ]]; then
    HOST_TEARDOWN_RUNG="abort + ${how}"
  else
    HOST_TEARDOWN_RUNG="$how"
  fi
  echo "INFO: host teardown rung=${HOST_TEARDOWN_RUNG}; '${path}' detached"
  return 0
}

# echo script usage
usage() {
  cat <<EOF

Adjust the fuse.lxcfs filesystem mount in container

  - /var/lib/lxc/lxcfs/proc/cpuinfo:/proc/cpuinfo
  - /var/lib/lxc/lxcfs/proc/diskstats:/proc/diskstats
  - /var/lib/lxc/lxcfs/proc/meminfo:/proc/meminfo
  - /var/lib/lxc/lxcfs/proc/stat:/proc/stat
  - /var/lib/lxc/lxcfs/proc/swaps:/proc/swaps
  - /var/lib/lxc/lxcfs/proc/uptime:/proc/uptime
  - /var/lib/lxc/lxcfs/proc/loadavg:/proc/loadavg
  - /var/lib/lxc/lxcfs/sys/devices/system/cpu/online:/sys/devices/system/cpu/online

Umount all fuse.lxcfs filesystem mount in container before LXCFS daemonset pod stop
or fix "Transport endpoint is not connected" error that case by LXCFS pod unexpected stop
by remount fuse.lxcfs filesystem after LXCFS daemonset pod start

usage: ${0} [OPTIONS]

The following one flag are required

  --umount            umount fuse.lxcfs filesystem mount in container,
                      then tear down ${LXCFS_PATH} itself
  --remount           umount fuse.lxcfs filesystem mount in container and remount it

Environment

  LXCFS_PROBE_TIMEOUT   seconds to wait for a single read of an LXCFS
                        file before declaring the mount wedged
                        (default: ${PROBE_TIMEOUT})
  LXCFS_ACTION_TIMEOUT  seconds to wait for a mount/umount to complete
                        (default: ${ACTION_TIMEOUT})
  LXCFS_UMOUNT_BUDGET   --umount only: total wall-clock seconds for the
                        whole teardown, which must fit inside the Pod's
                        terminationGracePeriodSeconds. The chart derives
                        this from that value (default: ${UMOUNT_BUDGET})
  LXCFS_HOST_TEARDOWN_RESERVE
                        seconds of that budget kept back for tearing down
                        ${LXCFS_PATH}, which the per-container loop may
                        not spend (default: ${HOST_TEARDOWN_RESERVE})
  LXCFS_MOUNT_READY_TIMEOUT
                        --remount only: seconds to wait for ${LXCFS_PATH}
                        to start serving before giving up. The chart
                        derives this from terminationGracePeriodSeconds
                        (default: ${MOUNT_READY_TIMEOUT})
  LXCFS_READY_PROBE_FILE
                        file under ${LXCFS_PATH} whose read decides
                        whether the mount is serving. Must be
                        cpuview-backed to be worth anything
                        (default: ${READY_PROBE_FILE})

--remount will not touch a single container until ${LXCFS_PATH} is
actually serving -- not merely present in the mount table, but answering a
read of ${READY_PROBE_FILE}. kubelet fires postStart concurrently with the
container's ENTRYPOINT and guarantees no ordering, so without that
precondition the hook can run before lxcfs has mounted, find every source
absent, skip every container and exit 0.

--remount exits non-zero if that precondition never held, if any probe
times out, or if it could not do work it was supposed to do -- a bind that
did not take effect, a container whose mount table could not be read, a
container with nothing runnable inside it -- so a broken node shows up as
FailedPostStartHook instead of hanging the hook forever or reporting
success while doing nothing. A container that simply exited mid-scan is
reported but does not fail the hook, and neither does a container the
webhook never injected into: one with no ${LXC_PATH} mount and no LXCFS
bind in its mount namespace was never an LXCFS consumer, so there is
nothing to restore in it.

The mount and umount that must run inside a mutated container are executed
via the statically linked busybox this image stages at
${CONTAINER_BUSYBOX}, which is reachable inside every mutated Pod because
the webhook bind-mounts ${LXC_PATH}/ into it. The container's own
mount/umount is used when that is missing. Nothing else runs inside the
container any more: existence probes go through /proc/<pid>/root and mount
table lookups through /proc/<pid>/mountinfo, both from the node.

--umount also detaches the canonical FUSE mount at ${LXCFS_PATH}. That
mount is created with Bidirectional propagation, so it lives in the host
mount namespace and outlives this container; nothing else removes it.
It escalates fusermount -u -> abort the FUSE connection -> umount ->
umount -l, and logs which rung cleared it. Aborting the connection is the
only way to release a reader already parked in uninterruptible sleep --
SIGKILL is never delivered to one.

EOF

  exit 0
}

# check python3, nsenter, crictl or docker command exist on k8s cluster
pre_check() {
  if ! command -v python3 >/dev/null; then
    echo python3 interpreter not found on host, exit
    exit 1
  fi

  if ! command -v nsenter >/dev/null; then
    echo nsenter not found on host, exit
    exit 1
  fi

  if ! command -v crictl >/dev/null && ! command -v docker >/dev/null; then
    echo container cli command crictl or docker not found on host, exit
    exit 1
  fi

  # Not fatal -- resolve_container_tools() falls back to the container's
  # own mount/umount and reports per container when neither exists -- but
  # a node missing the staged busybox cannot serve a distroless container,
  # and that is worth one line at the top of the hook log rather than
  # eight lines per Pod further down.
  if [[ ! -x "$CONTAINER_BUSYBOX" ]]; then
    echo "WARN: '${CONTAINER_BUSYBOX}' is missing or not executable on this node." \
         "Containers whose image ships no mount/umount of its own cannot be" \
         "served. It is staged by this image's entrypoint, so a node in this" \
         "state is running an lxcfs image older than 7.0.0-2." >&2
  fi
}

# The eight files LXCFS virtualizes, i.e. the bind mounts the webhook
# injects (cmd/volume.go) and the ones this script maintains.
LXCFS_TARGETS=(
  "/proc/cpuinfo"
  "/proc/diskstats"
  "/proc/loadavg"
  "/proc/meminfo"
  "/proc/stat"
  "/proc/swaps"
  "/proc/uptime"
  "/sys/devices/system/cpu/online"
)

# Is the container still there?
#
# A container that exited between discovery and now is normal churn, not a
# defect: `crictl ps` and `docker ps` are snapshots and kubelet is always
# moving Pods. Distinguishing it from a real failure matters because only
# one of the two should make the hook exit non-zero. /proc is procfs, so
# this cannot block.
container_alive() {
  [[ -d "/proc/${1}" ]]
}

# Block until $LXCFS_PATH is serving, or give up loudly.
#
# See the MOUNT_READY_TIMEOUT comment at the top for why this exists. Two
# distinct waits, deliberately treated differently:
#
#   not a mount point yet   The normal start-up race. Polling for it is a
#                           mount-table parse: it cannot block, cannot
#                           leak, and costs nothing, so poll to the
#                           deadline.
#   mounted, not answering  Not a transient. The read this gate performs
#                           costs microseconds of CPU, so missing a
#                           multi-second deadline is not "the node is
#                           busy", it is the cpuview hang -- and the
#                           reader that missed it is now parked in
#                           uninterruptible sleep where no signal can
#                           reach it. Retrying would park another one per
#                           attempt, so exactly one is ever spent and the
#                           wait ends there.
#
# Where the wait belongs, and the arithmetic:
#
#   Blocking here blocks postStart, which blocks the Pod's kubelet worker
#   and therefore the Pod going Ready -- which is the correct semantic: a
#   DaemonSet Pod whose mount does not serve has nothing to offer. It must
#   not fight the teardown budget, though. The chart derives this timeout
#   from terminationGracePeriodSeconds exactly as it derives
#   LXCFS_UMOUNT_BUDGET, so for the default 60s grace period:
#
#     terminationGracePeriodSeconds   60
#     LXCFS_MOUNT_READY_TIMEOUT       45   = max(10, 60 - 15)   [this gate]
#     LXCFS_UMOUNT_BUDGET             45   = max(5,  60 - 15)   [preStop]
#       mandatory teardown rungs      13   = probe 5 + abort 3 + lazy 5
#
#   The two never run concurrently for one container: they are the start-up
#   and termination phases of the same instance. The only interleaving is a
#   DELETE that lands while this gate is still open, in which case kubelet
#   finishes the hook before it starts killing, so the teardown begins up
#   to 45s late. That is survivable precisely because this gate only stays
#   open while the mount is NOT serving, and in that state the teardown is
#   either "none (not a mount point)" -- a no-op -- or the 13s mandatory
#   ladder. 45 + 13 = 58 <= 60, so even the worst interleaving fits inside
#   one grace period.
lxcfs_wait_until_serving() {
  local deadline=$((SECONDS + MOUNT_READY_TIMEOUT)) started=$SECONDS
  local probe="${LXCFS_PATH}${READY_PROBE_FILE}" rc reason="not checked yet"

  while :; do
    if is_fuse_mounted_in "$(mountinfo_file)" "$LXCFS_PATH"; then
      run_bounded "$PROBE_TIMEOUT" probe_read "$probe"
      rc=$?
      if ((rc == 0)); then
        echo "INFO: '${LXCFS_PATH}' is serving; '${probe}' answered after" \
             "$((SECONDS - started))s"
        return 0
      fi
      if ((rc == 124)); then
        WEDGED_PATHS+=("host mount: ${probe}")
        reason="'${probe}' did not answer within ${PROBE_TIMEOUT}s; the mount exists but the daemon has stopped answering reads"
        break
      fi
      reason="reading '${probe}' failed with exit ${rc} (a mount whose daemon is gone answers ENOTCONN)"
    else
      reason="'${LXCFS_PATH}' is not a FUSE mount in $(mountinfo_file)"
    fi

    (($(time_left "$deadline") <= 0)) && break
    sleep "$READY_POLL_INTERVAL"
  done

  {
    echo
    echo "==================================================================="
    echo "LXCFS is not serving on $(hostname); refusing to remount."
    echo
    echo "  waited ${MOUNT_READY_TIMEOUT}s, gave up after $((SECONDS - started))s"
    echo "  ${reason}"
    echo
    echo "Iterating the node's containers from here would find every source"
    echo "file absent, skip all of them, and exit 0 -- which is how a roll"
    echo "can complete having restored nothing and said nothing. Failing"
    echo "instead surfaces as FailedPostStartHook, which is alertable."
    echo
    echo "Read this DaemonSet Pod's own log first: entrypoint.sh refuses to"
    echo "start on a mount it could not clear, and says so."
    echo
    echo "See charts/lxcfs-admission-webhook/MIGRATION.md (Recovery)."
    echo "==================================================================="
  } >&2
  return 1
}

# Which of $LXCFS_TARGETS the canonical mount actually serves on this node.
#
# Asked once per run, from the host, after the gate has proved the mount
# answers. It separates "LXCFS does not offer this file on this node" from
# "this container cannot see a file LXCFS does offer", which is a defect.
# 0.4.1 could not tell them apart because it only ever looked at the source
# through the *container's* view of it, where both look identical.
#
# On LXCFS 7.0.0 this comes back empty: all eight paths exist whatever
# lxcfs.args says -- --enable-loadavg and --enable-cfs change what the
# files contain, not whether they exist (verified against 7.0.0 run with
# --foreground alone). So the count is normally 0, and that is the point:
# it is no longer possible for a genuinely missing file to hide inside a
# bucket that a healthy node fills with 48 entries. It also keeps working
# if a future release or flag combination does drop a file.
#
# Bounded, because a lookup of /sys/devices/system/cpu/online is itself one
# of the operations the 7.0.0 defect hangs: LXCFS computes that file's size
# in getattr, which calls max_cpu_count().
lxcfs_survey_sources() {
  local target rc

  for target in "${LXCFS_TARGETS[@]}"; do
    run_bounded "$PROBE_TIMEOUT" host_view_exists "${LXCFS_PATH}${target}"
    rc=$?
    ((rc == 0)) && continue

    SOURCES_NOT_SERVED+="${target} "
    if ((rc == 124)); then
      echo "ERROR: '${LXCFS_PATH}${target}' did not answer within ${PROBE_TIMEOUT}s;" \
           "treating it as not served" >&2
      WEDGED_PATHS+=("host mount: ${LXCFS_PATH}${target}")
    fi
  done

  if [[ "$SOURCES_NOT_SERVED" != " " ]]; then
    echo "INFO: ${LXCFS_PATH} does not serve:${SOURCES_NOT_SERVED}-- containers keep" \
         "the node's own file for those paths. LXCFS 7.0.0 creates all of them, so" \
         "check this daemon's log and lxcfs.args if you did not expect it."
  fi
}

source_is_served() {
  [[ "$SOURCES_NOT_SERVED" != *" ${1} "* ]]
}

# Was LXCFS ever injected into pid <pid>'s container?
#   0  yes -- it carries $LXC_PATH, or it already has LXCFS binds
#   1  no  -- nothing here was ever meant to be bound
#   2  could not find out
#
# Reads /proc/<pid>/mountinfo and nothing else: no exec in the container,
# no stat of any path, so it works in an image with no executables and
# cannot block on a wedged FUSE server.
#
# Why this question needs asking. The crictl discovery path selects *Pods*
# carrying the webhook's "mutated" annotation and then walks every
# container in them, but the webhook only injects into the containers that
# existed when it saw the Pod. A sidecar injected afterwards by another
# mutating webhook -- istio-proxy, linkerd-proxy -- is in a mutated Pod and
# has no LXCFS mounts at all. On the cluster this was found on, six
# istio-proxy sidecars produced 48 "does not exist" warnings per roll.
#
# Two signals, because either alone is wrong:
#
#   $LXC_PATH is mounted   The ninth mount in cmd/volume.go. Present in
#                          every container the webhook injected into, and
#                          still present after preStop has removed the
#                          eight binds -- which is the state postStart
#                          actually runs against.
#   a target is fuse-mounted
#                          Covers a Pod mutated by a webhook older than
#                          that ninth mount: it has the binds but not the
#                          directory, and it must keep failing loudly
#                          rather than be dismissed as a non-consumer.
container_is_consumer() {
  local file="/proc/${1}/mountinfo"

  [[ -r "$file" ]] || return 2

  awk -v lxc="$LXC_PATH" -v targets="${LXCFS_TARGETS[*]}" '
    BEGIN { n = split(targets, t, " "); for (i = 1; i <= n; i++) want[t[i]] = 1 }
    {
      if ($5 == lxc || index($5, lxc "/") == 1) { found = 1; exit }
      fstype = ""
      for (i = 7; i <= NF; i++)
        if ($i == "-") { fstype = $(i + 1); break }
      if (fstype ~ /^fuse/ && ($5 in want)) { found = 1; exit }
    }
    END { exit !found }
  ' "$file"
}

# The shared preamble of lxcfs_remount and lxcfs_umount: is there anything
# in this container for us to act on at all?
#   0  yes
#   1  no, and that is normal -- already counted and reported
#   2  no, and that is a failure -- already reported
container_in_scope() {
  local container_pid=$1 action=$2 crc

  if ! container_alive "$container_pid"; then
    echo "WARN: pid ${container_pid} no longer exists; nothing to ${action}" >&2
    UNREACHABLE_CONTAINERS+=("pid ${container_pid}: exited before it could be ${action}ed")
    return 1
  fi

  container_is_consumer "$container_pid"
  crc=$?
  if ((crc == 2)); then
    echo "WARN: cannot read '/proc/${container_pid}/mountinfo', so whether it is an" \
         "LXCFS consumer is unknown; leaving pid ${container_pid} alone" >&2
    return 2
  fi
  if ((crc == 1)); then
    NON_CONSUMER_CONTAINERS+=("pid ${container_pid}")
    return 1
  fi
  return 0
}

# remount fuse.lxcfs filesystem in container
# if fuse.lxcfs mount point is broken in container, umount and mount it again
# if mount point is ok and fuse.lxcfs filesystem mount in container, mount it again
lxcfs_remount() {
  local container_pid=$1

  # Asked before anything is exec'd, which is not merely tidier: a sidecar
  # that is both distroless and not a consumer -- no $LXC_PATH mount, so no
  # staged busybox reachable, and no mount/umount of its own -- used to
  # reach resolve_container_tools, fail it, land in REMOUNT_FAILED and take
  # the whole node's postStart hook down with it. One container the webhook
  # never touched could put the DaemonSet into CrashLoopBackOff.
  container_in_scope "$container_pid" remount
  case $? in
  1) return 0 ;;
  2)
    REMOUNT_FAILED+=("pid ${container_pid}: could not read the container's mount table")
    return 1
    ;;
  esac

  if ! resolve_container_tools "$container_pid"; then
    {
      echo "ERROR: pid ${container_pid} has no reachable mount/umount, so its"
      echo "       LXCFS bind mounts cannot be restored. Looked for"
      echo "       '${CONTAINER_BUSYBOX}' (staged by this image's entrypoint into"
      echo "       ${LXCFS_SCRIPT_PATH}, which the webhook bind-mounts into every"
      echo "       mutated Pod) and for mount+umount in ${CONTAINER_TOOL_DIRS[*]}."
      echo "       Either this node's ${LXCFS_SCRIPT_PATH} predates chart 0.4.1,"
      echo "       or the Pod does not carry the /var/lib/lxc/ mount."
    } >&2
    UNTOOLED_CONTAINERS+=("pid ${container_pid}")
    REMOUNT_FAILED+=("pid ${container_pid}: no mount tool reachable inside the container")
    return 1
  fi
  echo "INFO: pid ${container_pid}: in-container mount tool = ${CT_KIND}"

  local target source rc mrc
  for target in "${LXCFS_TARGETS[@]}"; do
    source="${LXCFS_PATH}${target}"

    # The in-container mount point is present in the mount table but no
    # longer readable ("Transport endpoint is not connected"), i.e. it is
    # left over from a previous daemon. Detach it so it can be replaced.
    #
    # A probe timeout is treated the same way on purpose: a mount point
    # that neither answers nor errors is just as unusable, and detaching
    # it is what lets the container recover.
    probe_path "$container_pid" "$target"
    rc=$?
    if ((rc != 0)); then
      is_lxcfs_mounted "$container_pid" "$target"
      mrc=$?
      case $mrc in
      0)
        if ! bounded_umount "$container_pid" "$target"; then
          # Not fatal on its own: the bind below may still land on top of
          # it and the topmost mount is the one the container reads. The
          # verification at the end of container_bind_ro decides.
          echo "WARN: pid ${container_pid}: could not detach the stale bind at" \
               "'${target}'; a new bind will be stacked over it" >&2
          REMOUNT_DEGRADED+=("pid ${container_pid}: ${target}: stale bind not detached")
        fi
        ;;
      2)
        REMOUNT_FAILED+=("pid ${container_pid}: ${target}: could not read the container's mount table")
        continue
        ;;
      esac
    fi

    # LXCFS does not offer this file on this node, so leaving the
    # container on the node's own is the correct outcome, not a problem.
    # Established once per run against the canonical mount by
    # lxcfs_survey_sources, which also named the files -- so nothing is
    # printed here. This branch is the reason a healthy node no longer
    # emits eight warnings per container about paths that were never
    # going to exist.
    if ! source_is_served "$target"; then
      REMOUNT_NOT_SERVED=$((REMOUNT_NOT_SERVED + 1))
      continue
    fi

    # Bind the canonical LXCFS file over the container's, but only once
    # we have confirmed the canonical file actually answers. Probing the
    # source first is the whole point: a mount that merely *exists* proves
    # nothing, and bind-mounting a wedged source spreads the hang into
    # every mutated container on the node.
    probe_path "$container_pid" "$source"
    rc=$?
    if ((rc == 124)); then
      REMOUNT_FAILED+=("pid ${container_pid}: ${target}: source '${source}' did not answer")
      continue
    fi
    if ((rc != 0)); then
      # A hard failure now, unlike in 0.4.1. The node serves this file --
      # lxcfs_survey_sources just read it -- and this container is a
      # consumer, so the file not being visible inside it means the path
      # that carries it is broken: either the Pod lacks the ${LXC_PATH}/
      # mount (mutated by a webhook older than cmd/volume.go's ninth
      # mount), or that mount is not propagating, which needs ${LXC_PATH}
      # to be a shared mount on the node for HostToContainer to work.
      # Either way the container will never see virtualized values and
      # nothing here can fix it, so say so and fail the hook.
      echo "ERROR: pid ${container_pid}: '${source}' is served by ${LXCFS_PATH} on this" \
           "node but is not visible inside the container, so '${target}' cannot be" \
           "bound. The Pod is missing the ${LXC_PATH}/ mount, or that mount is not" \
           "receiving the node's mounts (HostToContainer needs ${LXC_PATH} to be a" \
           "shared mount on the node)." >&2
      REMOUNT_FAILED+=("pid ${container_pid}: ${target}: '${source}' is served on the node but not visible in the container")
      continue
    fi

    is_lxcfs_mounted "$container_pid" "$target"
    mrc=$?
    if ((mrc == 0)); then
      REMOUNT_ALREADY=$((REMOUNT_ALREADY + 1))
      continue
    fi
    if ((mrc == 2)); then
      REMOUNT_FAILED+=("pid ${container_pid}: ${target}: could not read the container's mount table")
      continue
    fi

    if container_bind_ro "$container_pid" "$source" "$target"; then
      REMOUNT_BOUND=$((REMOUNT_BOUND + 1))
    else
      echo "ERROR: pid ${container_pid}: '${target}' is still not an LXCFS mount" \
           "after binding '${source}' over it (tool: ${CT_KIND})" >&2
      REMOUNT_FAILED+=("pid ${container_pid}: ${target}: bind did not take effect")
    fi
  done
}

# umount fuse.lxcfs filesystem in container
#
# Never probes the FUSE files: whether they answer is irrelevant when the
# goal is to detach them, and probing a dead mount is exactly what used to
# make preStop block until the node was rebooted.
lxcfs_umount() {
  local container_pid=$1

  # Same question as in lxcfs_remount, and it matters here too: without it
  # a distroless sidecar the webhook never touched produced "leaving its
  # LXCFS bind mounts in place" on every teardown -- a warning about bind
  # mounts it never had.
  container_in_scope "$container_pid" unmount
  case $? in
  1 | 2) return 0 ;;
  esac

  # A container with nothing runnable inside keeps its binds. That is
  # recoverable -- they answer ENOTCONN once the connection is aborted and
  # the next Pod's postStart replaces them -- but it must be said out
  # loud, because in 0.4.0 this was the silent path for every distroless
  # container on the node.
  if ! resolve_container_tools "$container_pid"; then
    echo "WARN: pid ${container_pid} has no reachable umount; leaving its LXCFS" \
         "bind mounts in place. They will answer ENOTCONN until the next" \
         "postStart --remount replaces them." >&2
    UNTOOLED_CONTAINERS+=("pid ${container_pid}")
    return 1
  fi

  local target mrc
  for target in "${LXCFS_TARGETS[@]}"; do
    # Out of the bind-mount slice of the budget. Stop rather than keep
    # spending: what is left is reserved for the canonical host mount,
    # which is the part a human cannot recover from remotely. The binds
    # left behind here start answering ENOTCONN as soon as the connection
    # is aborted, and the next Pod's postStart --remount replaces them.
    if (($(time_left "$BIND_DEADLINE") <= 0)); then
      BIND_BUDGET_EXHAUSTED=true
      SKIPPED_BIND_TARGETS=$((SKIPPED_BIND_TARGETS + 1))
      continue
    fi

    is_lxcfs_mounted "$container_pid" "$target"
    mrc=$?
    if ((mrc == 0)); then
      bounded_umount "$container_pid" "$target"
    elif ((mrc == 2)); then
      echo "WARN: pid ${container_pid}: leaving '${target}' alone; its mount" \
           "table could not be read" >&2
    fi
  done
}

# call lxcfs_remount or lxcfs_umount by shell args
lxcfs_mount() {
  container_pid=$1

  if [[ "$REMOUNT" == true ]]; then
    lxcfs_remount "$container_pid"
  elif [[ "$UMOUNT" == true ]]; then
    lxcfs_umount "$container_pid"
  else
    echo "unknown action got, exit"
    exit 1
  fi
}

docker_cli() {
  # skip pause container
  # skip container in namespaces kube-system or kube-public
  containers=$(docker ps | grep -v -E "pause|kube-system|kube-public" | awk 'NR > 1 {print $1}')

  for container in $containers; do
    # `docker inspect` per container is not free either, so stop
    # discovering once the bind-mount budget is gone.
    if [[ "$BIND_BUDGET_EXHAUSTED" == true ]]; then
      break
    fi

    mount_point=$(docker inspect --format "{{ range .Mounts }}{{ if eq .Destination \"$LXC_PATH\"  }}{{ .Source }}{{ end }}{{ end }}" "$container")

    if [[ "$mount_point" == "$LXC_PATH" ]]; then
      # skip itself, the lxcfs daemonset container
      # check by has environment LXCFS_VERSION=xxx set at Dockerfile
      container_envs=$(docker inspect --format '{{ range .Config.Env }} {{ . }} {{ end }}' "$container")
      if [[ "${container_envs[*]}" =~ "LXCFS_VERSION" ]]; then
        # skip this container only -- `break` here aborted the whole scan, so
        # every container discovered after the lxcfs container itself was
        # silently never remounted.
        continue
      fi
      pid=$(docker inspect --format '{{.State.Pid}}' "$container")
      echo "adjust lxcfs mount in container $container on $(hostname) with docker"
      lxcfs_mount "$pid"
    fi
  done
}

crictl_cli() {
  # prepare crictl connect endpoint
  # https://github.com/kubernetes-sigs/cri-tools/blob/33d7f05e2ad599eb269d468447615b5380191a69/docs/crictl.md?plain=1#L99
  endpoints=("/var/run/dockershim.sock" "/run/containerd/containerd.sock" "/run/crio/crio.sock" "/var/run/cri-dockerd.sock")
  for endpoint in "${endpoints[@]}"; do
    if [[ -S $endpoint ]]; then
      export CONTAINER_RUNTIME_ENDPOINT=$endpoint
      break
    fi
  done

  # Select pods annotated "mutating.lxcfs-admission-webhook.io/status: mutated",
  # excluding our own DaemonSet pod.
  #
  # The previous exclusion filtered on the label "app -> lxcfs-ds", which no
  # release of this chart ever sets: the DaemonSet is labelled
  # "app: <release>-daemonset". That clause therefore never matched anything and
  # the guard was dead. Filter on the chart's own opt-out annotation instead --
  # it is set on the DaemonSet pod template, and unlike a label carrying the
  # release name it is the same for every release.
  pods=$(crictl pods --output table --state ready --verbose |
    awk -v RS= '/mutating.lxcfs-admission-webhook.io\/status -> mutated/ &&
                ! /mutating.lxcfs-admission-webhook.io\/enable -> false/ {print $0"\n"}' |
    awk -F ": " '/^ID:/ {print $2}')

  for pod in $pods; do
    if [[ "$BIND_BUDGET_EXHAUSTED" == true ]]; then
      break
    fi

    containers=$(crictl ps --quiet --pod "$pod")
    for container in $containers; do
      # `crictl inspect` plus a python3 start-up per container is the
      # most expensive step in the loop; stop once the budget is gone.
      if [[ "$BIND_BUDGET_EXHAUSTED" == true ]]; then
        break
      fi

      pid=$(crictl inspect --output=json "$container" | python3 -c "import sys, json; print(json.load(sys.stdin)['info']['pid'])")
      echo "adjust lxcfs mount in container $container on $(hostname) with crictl"
      lxcfs_mount "$pid"
    done
  done
}

main() {
  pre_check

  local started_at=$SECONDS host_rc=0

  if [[ $# -eq 1 ]]; then
    case $1 in
    --umount)
      UMOUNT=true

      # One budget for the whole teardown. The bind-mount loop is fenced
      # off short of it so the host mount always gets its reserve; see the
      # UMOUNT_BUDGET comment above.
      #
      # PROBE_TIMEOUT is env-overridable, so check rather than assume that
      # the reserve still covers the rungs that must never be skipped:
      # responsiveness probe, abort, lazy detach.
      local min_reserve=$((PROBE_TIMEOUT + ABORT_TIMEOUT + LAZY_TIMEOUT))
      if ((HOST_TEARDOWN_RESERVE < min_reserve)); then
        echo "WARN: host teardown reserve ${HOST_TEARDOWN_RESERVE}s is below the" \
             "${min_reserve}s its mandatory rungs need; raising it" >&2
        HOST_TEARDOWN_RESERVE=$min_reserve
      fi
      if ((UMOUNT_BUDGET <= HOST_TEARDOWN_RESERVE)); then
        echo "WARN: umount budget ${UMOUNT_BUDGET}s leaves nothing for the" \
             "${HOST_TEARDOWN_RESERVE}s host teardown reserve; raising it" >&2
        UMOUNT_BUDGET=$((HOST_TEARDOWN_RESERVE + 5))
      fi

      DEADLINE=$((SECONDS + UMOUNT_BUDGET))
      BIND_DEADLINE=$((DEADLINE - HOST_TEARDOWN_RESERVE))
      echo "INFO: teardown budget ${UMOUNT_BUDGET}s" \
           "(bind mounts up to $((UMOUNT_BUDGET - HOST_TEARDOWN_RESERVE))s," \
           "${HOST_TEARDOWN_RESERVE}s reserved for ${LXCFS_PATH})"
      ;;
    --remount)
      REMOUNT=true

      # No global deadline: --remount runs from postStart, which is not
      # racing a grace period, and its per-operation timeouts already stop
      # it hanging. A day out is "no deadline" while keeping every call
      # site uniform.
      DEADLINE=$((SECONDS + 86400))
      BIND_DEADLINE=$DEADLINE

      # Replaces 0.4.1's `sleep 3`, whose comment ("wait 3 seconds to start
      # lxcfs, for post-start hook is executed immediately after a
      # container is created") named the race correctly and then answered
      # it with a timer. See lxcfs_wait_until_serving.
      #
      # The chart's postStart hook already gates in-container before it
      # ever gets here, so on a healthy roll this returns on its first
      # poll. It stays because a manual run, an older chart's hook command
      # and any future caller must get the same guarantee instead of
      # quietly skipping every container on the node.
      if lxcfs_wait_until_serving; then
        lxcfs_survey_sources
      else
        GATE_FAILED=true
      fi
      ;;
    *)
      usage
      ;;
    esac
  else
    usage
  fi

  # Skipped entirely when the precondition failed. Walking the node's
  # containers against a mount that does not serve is the behaviour this
  # release removes, not a fallback.
  if [[ "$GATE_FAILED" == false ]]; then
    if command -v docker >/dev/null; then
      docker_cli
    else
      crictl_cli
    fi
  fi

  # Detach the canonical mount only after the in-container binds are
  # gone. That order is what makes this safe: a mutated container whose
  # bind is already detached falls back to the real /proc file, whereas
  # detaching the FUSE mount first would leave every bind pointing into a
  # mount with no filesystem behind it.
  if [[ "$UMOUNT" == true ]]; then
    lxcfs_host_umount || host_rc=1

    {
      echo "INFO: teardown finished in $((SECONDS - started_at))s of ${UMOUNT_BUDGET}s;" \
           "host mount rung: ${HOST_TEARDOWN_RUNG}"
      if [[ "$BIND_BUDGET_EXHAUSTED" == true ]]; then
        echo "WARN: ran out of bind-mount budget; ${SKIPPED_BIND_TARGETS} in-container" \
             "bind mount(s) were left in place. They read ENOTCONN rather than" \
             "hanging, and the next Pod's postStart --remount replaces them."
      fi
      if ((${#UNTOOLED_CONTAINERS[@]} > 0)); then
        echo "WARN: ${#UNTOOLED_CONTAINERS[@]} container(s) kept their bind mounts" \
             "because nothing executable was reachable inside them:" \
             "${UNTOOLED_CONTAINERS[*]}"
      fi
      if ((${#NON_CONSUMER_CONTAINERS[@]} > 0)); then
        echo "INFO: ${#NON_CONSUMER_CONTAINERS[@]} container(s) had no LXCFS mounts to" \
             "remove (not consumers): ${NON_CONSUMER_CONTAINERS[*]}"
      fi
    } >&2
  fi

  # --remount closing report.
  #
  # Always printed, including on a completely healthy run, because the
  # thing that made the distroless bug survive 75 days was a hook log that
  # said nothing at all. A one-line tally makes "did no work" visibly
  # different from "had no work to do".
  if [[ "$REMOUNT" == true ]] && [[ "$GATE_FAILED" == true ]]; then
    echo "INFO: remount did nothing after $((SECONDS - started_at))s:" \
         "${LXCFS_PATH} never started serving, so no container was touched." \
         "Nothing was unbound either -- a container that still has the last" \
         "daemon's bind keeps it, and it reads ENOTCONN rather than hanging." >&2
  elif [[ "$REMOUNT" == true ]]; then
    {
      echo "INFO: remount finished in $((SECONDS - started_at))s:" \
           "${REMOUNT_BOUND} bound, ${REMOUNT_ALREADY} already mounted," \
           "${REMOUNT_NOT_SERVED} not served by lxcfs," \
           "${#NON_CONSUMER_CONTAINERS[@]} container(s) not LXCFS consumers," \
           "${#REMOUNT_FAILED[@]} failed"
      if ((${#NON_CONSUMER_CONTAINERS[@]} > 0)); then
        echo "INFO: nothing to restore in ${#NON_CONSUMER_CONTAINERS[@]} container(s):" \
             "no ${LXC_PATH} mount and no LXCFS bind in their mount namespace, so the" \
             "webhook never injected into them. Sidecars added to a mutated Pod after" \
             "the fact (istio-proxy, linkerd-proxy) are the normal reason." \
             "${NON_CONSUMER_CONTAINERS[*]}"
      fi
      if ((${#UNREACHABLE_CONTAINERS[@]} > 0)); then
        echo "INFO: skipped ${#UNREACHABLE_CONTAINERS[@]} container(s) that exited" \
             "mid-scan: ${UNREACHABLE_CONTAINERS[*]}"
      fi
      if ((${#REMOUNT_DEGRADED[@]} > 0)); then
        printf 'WARN: %s\n' "${REMOUNT_DEGRADED[@]}"
      fi
      if ((${#REMOUNT_FAILED[@]} > 0)); then
        echo
        echo "==================================================================="
        echo "LXCFS bind mounts could not be restored on $(hostname)."
        echo
        printf '  - %s\n' "${REMOUNT_FAILED[@]}"
        echo
        if ((${#UNTOOLED_CONTAINERS[@]} > 0)); then
          echo "Containers with nothing runnable inside them (distroless) need"
          echo "'${CONTAINER_BUSYBOX}' on the node. It is staged by this image's"
          echo "entrypoint, so check that the DaemonSet is running lxcfs 7.0.0-2"
          echo "or newer and that the Pod carries the ${LXC_PATH}/ mount the"
          echo "webhook injects."
          echo
        fi
        echo "Until this is fixed those containers read the node's /proc, not"
        echo "their cgroup's. See charts/lxcfs-admission-webhook/MIGRATION.md"
        echo "(0.4.0 -> 0.4.1)."
        echo "==================================================================="
      fi
    } >&2
  fi

  if ((${#WEDGED_PATHS[@]} > 0)); then
    {
      echo
      echo "==================================================================="
      echo "LXCFS FUSE mount was not answering on $(hostname)."
      echo
      echo "These probes timed out after ${PROBE_TIMEOUT}s each:"
      printf '  - %s\n' "${WEDGED_PATHS[@]}"
      echo
      echo "The lxcfs daemon accepted the mount but stopped answering reads,"
      echo "so its readers were parked in uninterruptible sleep, where no"
      echo "signal reaches them."
      echo
      if [[ "$UMOUNT" == true ]]; then
        echo "This run already did the recovery that used to be manual: it"
        echo "aborted the FUSE connection, which fails every parked request"
        echo "with ENOTCONN and lets those readers exit, and then detached"
        echo "${LXCFS_PATH} (rung: ${HOST_TEARDOWN_RUNG})."
        echo
        echo "Still needs a human:"
        echo "  - Pods that were mutated keep bind mounts into the old mount"
        echo "    and read ENOTCONN until this DaemonSet's next postStart"
        echo "    re-binds them. Restart any workload that cannot tolerate"
        echo "    that window."
        echo "  - Find out why the daemon stopped answering. A wedged mount is"
        echo "    an image or LXCFS bug, not a transient."
      else
        echo "Recover on the node with:"
        echo
        echo "  mountpoint -q ${FUSECTL_PATH} ||"
        echo "    mount -t fusectl none ${FUSECTL_PATH}"
        echo "  grep -l '^[1-9]' ${FUSECTL_PATH}/*/waiting"
        echo "  echo 1 > ${FUSECTL_PATH}/<N>/abort"
        echo "  pkill -f '/usr/bin/lxcfs'"
        echo "  umount -l ${LXCFS_PATH}"
      fi
      echo
      echo "See charts/lxcfs-admission-webhook/MIGRATION.md (Recovery)."
      echo "==================================================================="
    } >&2

    # Fail the hook rather than return success on a broken mount. For
    # postStart this makes the container restart and surface
    # FailedPostStartHook, which is alertable; the previous behaviour was
    # to block here forever, which was not.
    if [[ "$REMOUNT" == true ]]; then
      exit 1
    fi
  fi

  # A precondition that never held is a failure even when nothing was
  # wedged -- the commonest shape is a daemon that never mounted at all,
  # which produces no wedged path to report. Reported here rather than by
  # returning early from the gate so the blocks above still print.
  if [[ "$GATE_FAILED" == true ]]; then
    exit 1
  fi

  # Same reasoning for work that could not be completed for any other
  # reason. A container that merely exited mid-scan is deliberately not in
  # REMOUNT_FAILED: one Pod moving must not fail the hook for the whole
  # node, whereas a bind that did not take effect must.
  if [[ "$REMOUNT" == true ]] && ((${#REMOUNT_FAILED[@]} > 0)); then
    exit 1
  fi

  # A preStop that could not clear the host mount surfaces as
  # FailedPreStopHook. kubelet proceeds with the kill either way, so this
  # costs nothing and is the only alertable signal that a node was left
  # needing attention.
  exit "$host_rc"
}

main "$@"
