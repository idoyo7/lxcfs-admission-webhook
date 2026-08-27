#!/usr/bin/env bash

# adjust fuse.lxcfs filesystem mount in container after/before LXCFS DaemonSet start/stop

PATH=$PATH:/bin
LXC_PATH="/var/lib/lxc"
LXCFS_PATH="${LXC_PATH}/lxcfs"

UMOUNT=false
REMOUNT=false

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

# Is <path> a mount point in that namespace?
#
# Parses the mount table only -- it never stat()s the path, so unlike
# mountpoint(1) it cannot block on a wedged FUSE server.
is_mounted_at() {
  awk -v p="$1" '$5 == p { found = 1 } END { exit !found }' "$(mountinfo_file)"
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

# Bounded `test -e <path>` inside a container's mount namespace.
#   0   path exists
#   1   path does not exist
#   124 probe timed out -> the FUSE mount is not answering
probe_path() {
  local container_pid=$1 path=$2 rc

  run_bounded "$PROBE_TIMEOUT" nsenter -t "$container_pid" -m -- test -e "$path"
  rc=$?

  if [[ $rc -eq 124 ]]; then
    echo "ERROR: probing '$path' in pid $container_pid timed out after ${PROBE_TIMEOUT}s;" \
         "the LXCFS FUSE mount is not answering" >&2
    WEDGED_PATHS+=("pid ${container_pid}: ${path}")
  fi

  return $rc
}

# Is <path> currently a fuse.lxcfs mount in this container?
#
# Left unbounded on purpose: `mount -t <type>` only parses
# /proc/self/mountinfo, it never stat()s the mount points, so it cannot
# block on a wedged FUSE server. Keeping the pipeline shaped exactly as
# before also keeps grep running on the host, so this works against
# containers that ship no shell of their own.
is_lxcfs_mounted() {
  local container_pid=$1 path=$2

  nsenter -t "$container_pid" -m -p -- mount -t fuse.lxcfs | grep -qs "$path"
}

# umount that survives a dead mount. A plain umount of a wedged FUSE mount
# can block on the server, so fall back to a lazy umount, which detaches
# the mount from the tree without waiting for anyone still stuck on it.
#
# Both rungs are clamped to $BIND_DEADLINE, which for --umount fences the
# per-container work off from the reserve kept for the host mount, and for
# --remount is far enough out to leave the original per-operation
# behaviour untouched.
bounded_umount() {
  local container_pid=$1 path=$2

  echo nsenter -t "$container_pid" -m -p -- umount -v "$path"
  if run_bounded_until "$BIND_DEADLINE" "$ACTION_TIMEOUT" \
       nsenter -t "$container_pid" -m -p -- umount -v "$path"; then
    return 0
  fi

  echo "WARN: umount of '$path' in pid $container_pid did not succeed;" \
       "retrying lazily (umount -l)" >&2
  run_bounded_until "$BIND_DEADLINE" "$ACTION_TIMEOUT" \
    nsenter -t "$container_pid" -m -p -- umount -lv "$path"
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

--remount exits non-zero if any probe times out, so a wedged mount shows
up as FailedPostStartHook instead of hanging the hook forever.

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
}

# remount fuse.lxcfs filesystem in container
# if fuse.lxcfs mount point is broken in container, umount and mount it again
# if mount point is ok and fuse.lxcfs filesystem mount in container, mount it again
lxcfs_remount() {
  container_pid=$1

  local targets=(
    "/proc/cpuinfo"
    "/proc/diskstats"
    "/proc/loadavg"
    "/proc/meminfo"
    "/proc/stat"
    "/proc/swaps"
    "/proc/uptime"
    "/sys/devices/system/cpu/online"
  )

  local target source rc
  for target in "${targets[@]}"; do
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
    if [[ $rc -ne 0 ]] && is_lxcfs_mounted "$container_pid" "$target"; then
      bounded_umount "$container_pid" "$target"
    fi

    # Bind the canonical LXCFS file over the container's, but only once
    # we have confirmed the canonical file actually answers. Probing the
    # source first is the whole point: a mount that merely *exists* proves
    # nothing, and bind-mounting a wedged source spreads the hang into
    # every mutated container on the node.
    if probe_path "$container_pid" "$source" &&
       ! is_lxcfs_mounted "$container_pid" "$target"; then
      echo nsenter -t "$container_pid" -m -- mount -B -v -o ro "$source" "$target"
      run_bounded "$ACTION_TIMEOUT" \
        nsenter -t "$container_pid" -m -- mount -B -v -o ro "$source" "$target"
    fi
  done
}

# umount fuse.lxcfs filesystem in container
#
# Never probes the FUSE files: whether they answer is irrelevant when the
# goal is to detach them, and probing a dead mount is exactly what used to
# make preStop block until the node was rebooted.
lxcfs_umount() {
  container_pid=$1

  local targets=(
    "/proc/cpuinfo"
    "/proc/diskstats"
    "/proc/loadavg"
    "/proc/meminfo"
    "/proc/stat"
    "/proc/swaps"
    "/proc/uptime"
    "/sys/devices/system/cpu/online"
  )

  local target
  for target in "${targets[@]}"; do
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

    if is_lxcfs_mounted "$container_pid" "$target"; then
      bounded_umount "$container_pid" "$target"
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

      # wait 3 seconds to start lxcfs
      # for post-start hook is executed immediately after a container is created
      sleep 3
      ;;
    *)
      usage
      ;;
    esac
  else
    usage
  fi

  if command -v docker >/dev/null; then
    docker_cli
  else
    crictl_cli
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

  # A preStop that could not clear the host mount surfaces as
  # FailedPreStopHook. kubelet proceeds with the kill either way, so this
  # costs nothing and is the only alertable signal that a node was left
  # needing attention.
  exit "$host_rc"
}

main "$@"
