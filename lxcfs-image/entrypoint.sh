#!/usr/bin/env bash
set -eo pipefail

LXC_PATH="/var/lib/lxc"
LXCFS_PATH="${LXC_PATH}/lxcfs"
LXCFS_SCRIPT_PATH="${LXC_PATH}/script"

# Seconds to allow for each cleanup step below.
CLEANUP_TIMEOUT="${LXCFS_CLEANUP_TIMEOUT:-15}"

# Run a command with a hard wall-clock bound; 124 means it did not finish.
#
# Not timeout(1): every command below touches $LXCFS_PATH, which may still
# be a FUSE mount whose daemon is gone or wedged. Operations on such a
# mount block in uninterruptible sleep, so timeout(1) would send a signal
# the target cannot act on and then block in wait() itself. Polling from
# here lets startup make progress and report instead.
POLL_INTERVAL=0.05
sleep "$POLL_INTERVAL" 2>/dev/null || POLL_INTERVAL=1

run_bounded() {
  local seconds=$1
  shift

  local child deadline=$((SECONDS + seconds))
  "$@" &
  child=$!

  while kill -0 "$child" 2>/dev/null; do
    if ((SECONDS >= deadline)); then
      return 124
    fi
    sleep "$POLL_INTERVAL"
  done

  wait "$child"
}

# Is $LXCFS_PATH a mount point? Reads /proc/self/mountinfo only, so it
# never blocks on the FUSE server. Checked before readability so that a
# fresh node -- where the path simply does not exist yet -- is not mistaken
# for a broken mount.
lxcfs_path_is_mounted() {
  awk -v p="$LXCFS_PATH" '$5 == p { found = 1 } END { exit !found }' \
    /proc/self/mountinfo
}

# ---------------------------------------------------------------------------
# FUSE connection control
# ---------------------------------------------------------------------------
# Deliberately duplicated from lxcfs-mount.sh rather than shared. That
# script is copied out to the host and executed there by the lifecycle
# hooks, while this one runs inside the container; a common library would
# have to be staged to the host too, which is more moving parts than these
# thirty lines are worth. Keep the two copies in step.
FUSECTL_PATH="/sys/fs/fuse/connections"

# Make $FUSECTL_PATH usable. The container mounts hostPath /sys/fs/cgroup
# and /var/lib/lxc but not /sys, so it gets its own sysfs, on which
# nothing has mounted fusectl -- /sys/fs/fuse/connections exists as an
# empty kobject directory. fusectl is not namespaced, so mounting it here
# lists every connection on the kernel, which is what is needed. It takes
# only the CAP_SYS_ADMIN the DaemonSet already has from privileged: true.
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

  mount -t fusectl none "$FUSECTL_PATH" 2>/dev/null
}

# Abort every FUSE connection mounted at $LXCFS_PATH.
#
# mountinfo field 3 is "major:minor"; FUSE reports major 0 and the minor
# is the directory name under $FUSECTL_PATH. The filesystem type is the
# field just past the " - " separator.
#
# This is the step that was missing. fusermount and umount can only help
# while something is still willing to answer; if the previous daemon is
# gone but its readers are parked in fuse_simple_request(), those tasks
# are in uninterruptible sleep and no signal reaches them. Aborting the
# connection fails their requests with ENOTCONN, which is the only thing
# that lets them return -- and the only thing that makes the mount
# unbusy enough to detach.
abort_lxcfs_connections() {
  local minors minor aborted=1

  if ! fusectl_ready; then
    echo "WARN: ${FUSECTL_PATH} is unavailable; cannot abort a wedged FUSE connection" >&2
    return 1
  fi

  minors=$(awk -v p="$LXCFS_PATH" '
    {
      fstype = ""
      for (i = 7; i <= NF; i++)
        if ($i == "-") { fstype = $(i + 1); break }
      if ($5 == p && fstype ~ /^fuse/) {
        split($3, dev, ":")
        print dev[2]
      }
    }
  ' /proc/self/mountinfo)

  while read -r minor; do
    [[ -n "$minor" ]] || continue
    if [[ -w "${FUSECTL_PATH}/${minor}/abort" ]]; then
      echo "WARN: aborting leftover FUSE connection ${minor} at ${LXCFS_PATH}" \
           "(waiting=$(cat "${FUSECTL_PATH}/${minor}/waiting" 2>/dev/null || echo '?'))" >&2
      echo 1 >"${FUSECTL_PATH}/${minor}/abort" && aborted=0
    fi
  done <<<"$minors"

  return "$aborted"
}

# Can $LXCFS_PATH be stat'ed? A mount left behind by a dead daemon answers
# ENOTCONN ("Transport endpoint is not connected"); one left behind by a
# wedged daemon does not answer at all, hence the bound.
lxcfs_path_readable() {
  run_bounded "$CLEANUP_TIMEOUT" test -d "$LXCFS_PATH"
}

# Cleanup any stale mount left by a previous Pod on this node.
#
# This matters more than it looks: the FUSE mount is created with
# Bidirectional propagation, so it outlives the container that made it. A
# rolling upgrade therefore hands the new Pod a mount point that is still
# occupied by the *previous* daemon's dead connection, and the new daemon
# cannot mount over it.
#
# Chart 0.4.0 and later tear this mount down in preStop, so on a healthy
# roll there is nothing here and this whole block is skipped. It still
# matters when the previous Pod was killed outright, when the node is
# coming back from the old behaviour, or when the previous daemon was
# wedged.
if lxcfs_path_is_mounted; then
  # Whether the leftover still answers at its root is worth logging, but
  # it is NOT a usable test for whether it is wedged: the failure this
  # exists for answers getattr on the mount root instantly and only hangs
  # on the cpuview-backed files underneath it. A "readable" leftover can
  # still have readers parked in the kernel.
  if lxcfs_path_readable; then
    echo "WARN: ${LXCFS_PATH} carries a leftover mount whose root still answers" >&2
  else
    echo "WARN: ${LXCFS_PATH} is mounted but not usable (stale mount from a previous daemon)" >&2
  fi

  # Abort before trying to unmount, not after, and unconditionally.
  #
  # Anything mounted here is abandoned by definition -- our own daemon has
  # not started yet -- so there is no live consumer to protect, and the
  # path is about to be unmounted either way.
  #
  # This is the step that was missing. If the previous daemon is gone, or
  # still alive but wedged, while its readers sit in
  # fuse_simple_request(), every rung below is doomed: those tasks are in
  # uninterruptible sleep, no signal reaches them, and the open files
  # they hold keep the mount busy, so fusermount3 -u and umount both
  # return EBUSY. The abort fails their requests with ENOTCONN, which is
  # what lets them return and let go.
  abort_lxcfs_connections || true

  # nsenter resolves the binary in the host mount namespace, so try both the
  # fuse3 and legacy fuse2 names depending on what the node ships.
  run_bounded "$CLEANUP_TIMEOUT" nsenter --target 1 --mount -- fusermount3 -u "$LXCFS_PATH" 2>/dev/null || \
    run_bounded "$CLEANUP_TIMEOUT" nsenter --target 1 --mount -- fusermount -u "$LXCFS_PATH" 2>/dev/null || true

  # fusermount only detaches mounts it can talk to. A dead or wedged mount
  # needs a lazy umount, which detaches it from the tree without waiting for
  # the server or for anyone still stuck on it. Without this the container
  # crash-loops on "Transport endpoint is not connected" until someone
  # cleans the node up by hand.
  if lxcfs_path_is_mounted; then
    echo "WARN: ${LXCFS_PATH} survived fusermount; detaching lazily" >&2
    run_bounded "$CLEANUP_TIMEOUT" umount -l "$LXCFS_PATH" 2>/dev/null || \
      run_bounded "$CLEANUP_TIMEOUT" nsenter --target 1 --mount -- umount -l "$LXCFS_PATH" 2>/dev/null || true
  fi

  # A second mount at the same path only becomes visible once the one
  # above it is gone -- which is precisely the state a failed cleanup
  # produced last time. Abort whatever is left and detach again.
  if lxcfs_path_is_mounted; then
    echo "WARN: ${LXCFS_PATH} is still a mount point; a stacked mount is underneath" >&2
    abort_lxcfs_connections || true
    run_bounded "$CLEANUP_TIMEOUT" nsenter --target 1 --mount -- umount -l "$LXCFS_PATH" 2>/dev/null || true
  fi

  # Refuse to start on top of a mount we could not clear.
  #
  # This used to tolerate a leftover that merely still answered, and
  # lxcfs would then mount a second FUSE over it. That is the failure
  # mode that took out both nodes: from then on every access to the path
  # blocked forever and no unmount could reach the lower mount. A
  # CrashLoopBackOff is a strictly better outcome than an unrecoverable
  # node, and it is alertable.
  if lxcfs_path_is_mounted; then
    echo "ERROR: ${LXCFS_PATH} is still mounted after aborting its FUSE" >&2
    echo "       connection and a lazy umount. Refusing to start, because" >&2
    echo "       mounting over it would stack a second FUSE on the same path" >&2
    echo "       and make every access to it block forever." >&2
    echo "       See charts/lxcfs-admission-webhook/MIGRATION.md (Recovery)." >&2
    exit 1
  fi
fi

if [[ -d "$LXCFS_PATH" ]]; then
  run_bounded "$CLEANUP_TIMEOUT" rm -rf "${LXCFS_PATH:?}"/* || \
    echo "WARN: could not clear ${LXCFS_PATH} within ${CLEANUP_TIMEOUT}s; continuing" >&2
fi

# Prepare directories.
[[ ! -d "$LXCFS_PATH" ]] && mkdir -p "$LXCFS_PATH"
[[ ! -d "$LXCFS_SCRIPT_PATH" ]] && mkdir -p "$LXCFS_SCRIPT_PATH"

# Copy $1 to $2 atomically, skipping an identical file.
#
# Atomic is not a nicety here, it is the fix for a defect this release
# exists to remove. kubelet fires the postStart hook CONCURRENTLY with this
# entrypoint and guarantees no ordering between them, and that hook exec's
# ${LXCFS_SCRIPT_PATH}/lxcfs-mount.sh -- a file that survives on the node's
# hostPath from the release being replaced, and that this entrypoint
# used to rewrite in place with `cat src > dst`, i.e. with O_TRUNC.
#
# Two things went wrong with that, both reproduced on a Docker-in-Docker
# node driving real container lifecycles:
#
#   1. The hook exec'd the OUTGOING release's script (measured: the staged
#      script was stale at hook entry in 3 out of 3 rolls), so the fix in a
#      new image did not take effect on the roll that deployed it. Mutated
#      Alpine containers ended those rolls reading the node's /proc.
#   2. Worse, bash does not read a script in one gulp; it reads, executes,
#      and comes back for more at a saved offset. Truncating and rewriting
#      the file underneath a running bash therefore SPLICES the two
#      versions: observed symptoms were `tool: busybox ()` -- the new
#      resolve_container_tools() running against the old file's variable
#      block, so $CONTAINER_BUSYBOX was unset -- and a tally line printed
#      with empty counters.
#
# rename(2) fixes both halves: a reader either has the old inode, which is
# never modified and stays complete, or the new one. It is also why the
# busybox staging below already worked this way -- truncating a binary
# another container is executing gets ETXTBSY -- so this is that treatment
# extended to the file that actually gets executed on every roll.
#
# $LXCFS_SCRIPT_PATH is under $LXC_PATH, which the webhook bind-mounts into
# every Pod it mutates (cmd/volume.go, ninth mount: /var/lib/lxc/,
# HostToContainer, read-only), so anything dropped here is reachable at the
# same absolute path inside every container lxcfs-mount.sh touches.
stage_file() {
  local src=$1 dst=$2 what=$3
  local tmp="${dst}.staging.$$"

  # Skip an identical file so a DaemonSet roll does not churn a file that
  # another process may be reading or executing right now.
  if cmp -s "$src" "$dst" 2>/dev/null; then
    echo "INFO: ${dst} is already current"
    return 0
  fi

  if cat "$src" >"$tmp" && chmod 0755 "$tmp" && mv -f "$tmp" "$dst"; then
    echo "INFO: staged ${what} ($(stat -c %s "$dst" 2>/dev/null || echo '?') bytes) at ${dst}"
    return 0
  fi

  rm -f "$tmp"
  echo "ERROR: could not stage ${src} at ${dst}" >&2
  return 1
}

# Remove temp files from a previous run that was killed between the write
# and the rename. Only this Pod writes here -- one DaemonSet Pod per node --
# so there is nobody else's in-flight staging to destroy.
rm -f "${LXCFS_SCRIPT_PATH}"/.busybox.* "${LXCFS_SCRIPT_PATH}"/*.staging.* 2>/dev/null || true

stage_script() {
  local src=/lxcfs/lxcfs-mount.sh

  if [[ ! -r "$src" ]]; then
    echo "ERROR: ${src} is missing from this image. The lifecycle hooks have" >&2
    echo "       nothing to run. This is a broken image build." >&2
    return 1
  fi

  stage_file "$src" "${LXCFS_SCRIPT_PATH}/lxcfs-mount.sh" "lxcfs-mount.sh"
}

# Refuse to start without it, for the same reason as the busybox below: a
# daemon whose preStop tears bind mounts down while its postStart cannot
# put them back is the silent outage this line prevents.
stage_script

# Stage the statically linked busybox next to the script.
#
# lxcfs-mount.sh has to run mount(2) and umount2(2) *inside* each mutated
# container, because both act on the calling process's mount namespace.
# `nsenter -t <pid> -m -- mount` enters that namespace and then resolves
# the binary there, so it fails outright in a distroless image, which
# ships no mount, no umount, no test and no shell. Before 0.4.1 that
# failure was read as "there is nothing to do" and the container was
# skipped without a log line.
#
# $LXCFS_SCRIPT_PATH is under $LXC_PATH, which the webhook bind-mounts
# into every Pod it mutates (cmd/volume.go, ninth mount: /var/lib/lxc/,
# HostToContainer, read-only). A binary dropped here is therefore
# reachable at the same absolute path inside every container this script
# touches, needs no cooperation from the workload's image, and -- being
# static -- needs no dynamic loader, which those images do not have
# either. Executing from a read-only mount is fine; only noexec would
# stop it, and a hostPath mount does not carry it.
#
# Renamed into place rather than written over, via stage_file above: a
# container may be executing this exact file right now, and truncating a
# running binary gets ETXTBSY.
stage_busybox() {
  local src=/bin/busybox

  if [[ ! -x "$src" ]]; then
    echo "ERROR: ${src} is missing from this image. lxcfs-mount.sh cannot" >&2
    echo "       restore bind mounts in containers that ship no mount/umount" >&2
    echo "       of their own. This is a broken image build." >&2
    return 1
  fi

  stage_file "$src" "${LXCFS_SCRIPT_PATH}/busybox" "static busybox"
}

# Refuse to start without it. A daemon that comes up while the node has no
# staged busybox will tear down bind mounts in preStop that its own
# postStart then cannot restore -- which is exactly the 75-day silent
# outage this release fixes. Crash-looping is alertable; that is not.
stage_busybox

# Run lxcfs with whatever args were passed (CMD or container.args). Falls
# back to the historical default when invoked with no args, so the image
# still works when run standalone.
if [[ $# -eq 0 ]]; then
  set -- --foreground --enable-loadavg --enable-cfs
fi

echo /usr/bin/lxcfs "$@" "$LXCFS_PATH"
exec /usr/bin/lxcfs "$@" "$LXCFS_PATH"
