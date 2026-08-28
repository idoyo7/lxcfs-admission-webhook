#!/usr/bin/env bash
#
# Is the canonical LXCFS mount at /var/lib/lxc/lxcfs actually SERVING?
#
# One question, two callers, and the same answer for both:
#
#   lxcfs-ready.sh            readinessProbe. One bounded read. Exit 0 if
#                             the mount answered it.
#   lxcfs-ready.sh --wait [N] postStart gate. Poll for up to N seconds
#                             until it answers, and additionally assert
#                             that this image's entrypoint has finished
#                             staging the files the hook is about to run.
#
# Both run INSIDE the DaemonSet container, which is where the FUSE mount is
# created; it reaches the host mount namespace only because the volume
# carries mountPropagation: Bidirectional.
#
# --------------------------------------------------------------------------
# Why "the process is up" is not readiness
# --------------------------------------------------------------------------
# During the LXCFS 7.0.0 incident the DaemonSet Pod showed 1/1 Running on a
# node where every read of /proc/cpuinfo through its mount hung forever
# (https://github.com/lxc/lxcfs/issues/730). There was no readinessProbe, so
# "Ready" meant "the daemon exec'd", and the rolling update happily moved on
# to the second node and wrecked that one too. So this asks the only
# question worth asking: does a cpuview-backed file answer?
#
# It has to be cpuview-backed. The defect answers lookup and getattr on the
# mount root instantly and hangs only in read() of the files that reach
# max_cpu_count(), so `mountpoint`, `stat` and `test -d` all report success
# on a wedged mount. /proc/meminfo answers on a wedged mount too.
#
# --------------------------------------------------------------------------
# Why this is not a one-line `cat`
# --------------------------------------------------------------------------
# A read against a wedged FUSE mount sits in uninterruptible sleep. It is
# not killable -- SIGKILL is queued and never delivered, because the task
# never runs to take it -- and only aborting the FUSE connection releases
# it. Consequences:
#
#   * timeout(1) is useless here. It would signal a target that cannot act
#     on the signal and then block in wait() itself, so the probe would
#     never return and kubelet would report a probe timeout instead of a
#     probe failure. Every bounded read below backgrounds its child and
#     polls, exactly as entrypoint.sh and lxcfs-mount.sh do.
#
#   * `exec: [cat, /var/lib/lxc/lxcfs/proc/cpuinfo]` as a probe would leak
#     one unkillable task per period, forever, on a wedged mount. That is
#     the accumulation that turned a pod-level defect into a node-level
#     one. So the first read that parks is recorded, and while that task is
#     still parked no further read is started: at most ONE reader can ever
#     be parked by this script, per container instance. Until it is
#     released the probe fails immediately and says why.
#
# See charts/lxcfs-admission-webhook/MIGRATION.md.

set -uo pipefail

LXC_PATH="/var/lib/lxc"
LXCFS_PATH="${LXC_PATH}/lxcfs"
LXCFS_SCRIPT_PATH="${LXC_PATH}/script"

# Where this image keeps its own copies of the staged files, i.e. the
# authoritative version for the container that is starting.
IMAGE_DIR="${LXCFS_IMAGE_DIR:-/lxcfs}"
IMAGE_BUSYBOX="${LXCFS_IMAGE_BUSYBOX:-/bin/busybox}"

# The file whose read decides the verdict, relative to $LXCFS_PATH.
PROBE_FILE="${LXCFS_READY_PROBE_FILE:-/proc/cpuinfo}"

# Seconds to allow one read. Must stay strictly below the probe's own
# timeoutSeconds, or kubelet SIGKILLs this script before it can record the
# parked reader and the next period starts another one. The chart derives
# it from timeoutSeconds so the two cannot drift.
READ_TIMEOUT="${LXCFS_READY_READ_TIMEOUT:-3}"

# --wait only: total seconds to keep polling.
WAIT_TIMEOUT="${LXCFS_MOUNT_READY_TIMEOUT:-45}"

# Container-instance state, deliberately NOT under $LXC_PATH: a marker on
# the node's hostPath would outlive the container it describes and the pid
# it names would be meaningless. A restarted container gets a fresh
# writable layer, which is exactly the lifetime this needs.
STATE_DIR="${LXCFS_READY_STATE_DIR:-/run}"
PARKED_FILE="${STATE_DIR}/lxcfs-readiness-parked"

MODE="probe"
REASON="not checked yet"

usage() {
  cat <<EOF
usage: ${0##*/}                 one-shot readiness check (exit 0 = serving)
       ${0##*/} --wait [N]      poll for up to N seconds (default ${WAIT_TIMEOUT})

Environment:
  LXCFS_READY_PROBE_FILE     file under ${LXCFS_PATH} to read (default ${PROBE_FILE})
  LXCFS_READY_READ_TIMEOUT   seconds for one read (default ${READ_TIMEOUT})
  LXCFS_MOUNT_READY_TIMEOUT  --wait budget in seconds (default ${WAIT_TIMEOUT})
  LXCFS_READY_STATE_DIR      where the parked-reader marker lives (default ${STATE_DIR})
EOF
}

# Not every sleep(1) takes a fraction; degrade to whole seconds where it
# does not. The inner poll wants to be short (it is pure latency on the
# healthy path) and the outer one does not.
POLL_INTERVAL=0.05
sleep "$POLL_INTERVAL" 2>/dev/null || POLL_INTERVAL=1
WAIT_POLL_INTERVAL=0.5
[[ "$POLL_INTERVAL" == 1 ]] && WAIT_POLL_INTERVAL=1

# Which mount table describes the namespace the canonical mount has to be
# visible in. It is created in this container but must reach the host
# namespace, which is PID 1's, for any other Pod to use it -- so that is
# the table to trust when it is readable.
mountinfo_file() {
  if [[ -r /proc/1/mountinfo ]]; then
    echo /proc/1/mountinfo
  else
    echo /proc/self/mountinfo
  fi
}

# Is <path> a FUSE mount according to the mount table <file>?
#
# Parses the table only; it never stat()s the path, so it cannot block on a
# wedged server. The filesystem type is the field just past the " - "
# separator.
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

# One-byte read of <file>, backgrounded so the parent can give up on it.
#   0    it answered
#   124  it did not answer in <seconds>; $PARKED_PID is the task left behind
#   1..  the read failed (ENOTCONN on a dead mount, ENOENT, ...)
#
# stderr is dropped: a child that timed out stays parked until someone
# aborts the FUSE connection, at which point its read fails with ENOTCONN
# and bash prints "read error" long after this function returned.
PARKED_PID=""
bounded_read() {
  local file=$1 seconds=$2 child deadline

  ( read -r -n 1 <"$file" ) 2>/dev/null &
  child=$!
  PARKED_PID=$child

  # Recorded before the wait rather than after the timeout, so the record
  # survives this script being killed mid-read -- which kubelet does when
  # the exec probe hits its own timeoutSeconds. Without it, that kill would
  # lose the only knowledge that a reader is parked, and every following
  # period would start another one: the per-period leak this whole
  # mechanism exists to prevent, reintroduced by the one path that skips
  # the code below.
  #
  # A record naming a task that has since finished costs nothing: the guard
  # tests whether that exact task (pid plus start time) still exists, and
  # clears the record when it does not.
  record_parked "$child"
  deadline=$((SECONDS + seconds))

  while kill -0 "$child" 2>/dev/null; do
    if ((SECONDS >= deadline)); then
      return 124
    fi
    sleep "$POLL_INTERVAL"
  done

  # The reader returned, so nothing is parked on our account.
  rm -f "$PARKED_FILE" 2>/dev/null
  wait "$child"
}

# Field 22 of /proc/<pid>/stat is the task's start time in clock ticks.
# Recording it alongside the pid makes the "is it still parked?" test
# immune to pid reuse, which matters because hostPID: true puts this script
# in the node's pid space where reuse is not hypothetical.
task_starttime() {
  awk '{ print $22 }' "/proc/${1}/stat" 2>/dev/null
}

record_parked() {
  local pid=$1
  mkdir -p "$STATE_DIR" 2>/dev/null
  printf '%s %s\n' "$pid" "$(task_starttime "$pid")" >"$PARKED_FILE" 2>/dev/null
}

# Is the reader recorded earlier still parked in the kernel?
#   0  yes -- do not start another one
#   1  no  -- it was released (the connection was aborted) or never existed
parked_reader_stuck() {
  local pid start now_start

  [[ -r "$PARKED_FILE" ]] || return 1
  read -r pid start <"$PARKED_FILE" 2>/dev/null || return 1
  [[ -n "${pid:-}" ]] || return 1

  now_start=$(task_starttime "$pid")
  if [[ -z "$now_start" || "$now_start" != "$start" ]]; then
    rm -f "$PARKED_FILE" 2>/dev/null
    return 1
  fi
  return 0
}

# Has this image's entrypoint finished putting on the node the files the
# postStart hook is about to execute?
#
# This is the check that would have caught the defect this release fixes.
# kubelet fires postStart concurrently with the container's ENTRYPOINT and
# guarantees no ordering between them, and the hook runs
# ${LXCFS_SCRIPT_PATH}/lxcfs-mount.sh -- a file on the node's hostPath that
# survives from the PREVIOUS release and that this container's entrypoint
# is busy replacing. Fired early enough, the hook runs the outgoing
# release's script, so a fix does not take effect on the roll that deploys
# it. Measured: at hook entry the staged script was the previous release's
# copy in 3 out of 3 rolls.
#
# Comparing bytes rather than inferring from "the mount is serving" (which
# entrypoint.sh establishes strictly later) because the direct check is
# cheap, and because it also covers the case where staging failed outright.
staging_current() {
  cmp -s "${IMAGE_DIR}/lxcfs-mount.sh" "${LXCFS_SCRIPT_PATH}/lxcfs-mount.sh" 2>/dev/null || {
    REASON="'${LXCFS_SCRIPT_PATH}/lxcfs-mount.sh' is not yet the copy this image ships"
    return 1
  }
  if [[ -x "$IMAGE_BUSYBOX" ]]; then
    cmp -s "$IMAGE_BUSYBOX" "${LXCFS_SCRIPT_PATH}/busybox" 2>/dev/null || {
      REASON="'${LXCFS_SCRIPT_PATH}/busybox' is not yet the copy this image ships"
      return 1
    }
  fi
  return 0
}

# One verdict.
#   0  serving
#   1  not serving; $REASON says why
#   2  mounted and not answering -- do not retry, see below
serving_now() {
  local rc probe="${LXCFS_PATH}${PROBE_FILE}"

  if [[ "$MODE" == wait ]] && ! staging_current; then
    return 1
  fi

  if ! is_fuse_mounted_in "$(mountinfo_file)" "$LXCFS_PATH"; then
    REASON="'${LXCFS_PATH}' is not a FUSE mount in $(mountinfo_file) yet"
    return 1
  fi

  if parked_reader_stuck; then
    REASON="a reader this script started earlier is still parked in uninterruptible
       sleep on '${probe}'. Starting another would leak a second unkillable
       task, so no read was attempted. Only aborting the FUSE connection
       releases it -- see MIGRATION.md (Recovery)."
    return 2
  fi

  bounded_read "$probe" "$READ_TIMEOUT"
  rc=$?
  case $rc in
  0)
    return 0
    ;;
  124)
    REASON="'${probe}' did not answer within ${READ_TIMEOUT}s. The mount exists and
       the daemon holds it, but it has stopped answering reads, which is the
       LXCFS 7.0.0 cpuview hang. Reader pid ${PARKED_PID} is now parked in
       uninterruptible sleep and no signal can release it."
    return 2
    ;;
  *)
    REASON="reading '${probe}' failed with exit ${rc} (a dead mount answers ENOTCONN)"
    return 1
    ;;
  esac
}

# --wait: poll until it serves, or the budget runs out.
#
# Only the "not there yet" reason is worth polling on -- it is the normal
# start-up race, and testing for it is a mount-table parse that cannot
# block or leak. "Mounted and not answering" is a code defect, not a
# transient: a read that costs microseconds of CPU does not miss a
# multi-second deadline because the node is busy, and every retry would
# park another unkillable reader. So that verdict ends the wait
# immediately.
wait_until_serving() {
  local deadline=$((SECONDS + WAIT_TIMEOUT)) started=$SECONDS rc

  while :; do
    serving_now
    rc=$?
    if ((rc == 0)); then
      echo "INFO: ${LXCFS_PATH} is serving; '${PROBE_FILE}' answered after $((SECONDS - started))s"
      return 0
    fi
    if ((rc == 2)); then
      break
    fi
    if ((SECONDS >= deadline)); then
      break
    fi
    sleep "$WAIT_POLL_INTERVAL"
  done

  {
    echo
    echo "==================================================================="
    echo "LXCFS is not serving on $(hostname) after $((SECONDS - started))s of ${WAIT_TIMEOUT}s."
    echo
    echo "  ${REASON}"
    echo
    echo "Refusing to run the postStart remount. Iterating containers now"
    echo "would find every source file absent, skip all of them, and report"
    echo "success -- which is how three Pods stayed unvirtualized for 75"
    echo "days. Failing here surfaces as FailedPostStartHook instead."
    echo
    echo "Check this container's own log first: entrypoint.sh refuses to"
    echo "start when it cannot clear a leftover mount, and says so."
    echo
    echo "See charts/lxcfs-admission-webhook/MIGRATION.md (Recovery)."
    echo "==================================================================="
  } >&2
  return 1
}

main() {
  while (($#)); do
    case $1 in
    --wait)
      MODE="wait"
      shift
      if [[ ${1:-} =~ ^[0-9]+$ ]]; then
        WAIT_TIMEOUT=$1
        shift
      fi
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
    esac
  done

  if [[ "$MODE" == wait ]]; then
    wait_until_serving
    exit $?
  fi

  # readinessProbe. One line on failure, nothing on success: kubelet keeps
  # the last failure message in the Pod's events, and a probe that prints
  # on every success buries it.
  if serving_now; then
    exit 0
  fi
  echo "NOT READY: ${REASON}" >&2
  exit 1
}

main "$@"
