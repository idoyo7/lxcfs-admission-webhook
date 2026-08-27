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
# nsenter resolves the binary in the host mount namespace, so try both the
# fuse3 and legacy fuse2 names depending on what the node ships.
run_bounded "$CLEANUP_TIMEOUT" nsenter --target 1 --mount -- fusermount3 -u "$LXCFS_PATH" 2>/dev/null || \
  run_bounded "$CLEANUP_TIMEOUT" nsenter --target 1 --mount -- fusermount -u "$LXCFS_PATH" 2>/dev/null || true

# fusermount only detaches mounts it can talk to. A dead or wedged mount
# needs a lazy umount, which detaches it from the tree without waiting for
# the server or for anyone still stuck on it. Without this the container
# crash-loops on "Transport endpoint is not connected" until someone
# cleans the node up by hand.
if lxcfs_path_is_mounted && ! lxcfs_path_readable; then
  echo "WARN: ${LXCFS_PATH} is mounted but not usable (stale mount from a previous daemon); detaching lazily" >&2
  run_bounded "$CLEANUP_TIMEOUT" umount -l "$LXCFS_PATH" 2>/dev/null || \
    run_bounded "$CLEANUP_TIMEOUT" nsenter --target 1 --mount -- umount -l "$LXCFS_PATH" 2>/dev/null || true

  if lxcfs_path_is_mounted && ! lxcfs_path_readable; then
    echo "ERROR: ${LXCFS_PATH} is still mounted and unusable after a lazy umount." >&2
    echo "       A previous lxcfs daemon is probably still holding it with" >&2
    echo "       readers stuck in uninterruptible sleep. Abort its FUSE" >&2
    echo "       connection on the node before retrying -- see" >&2
    echo "       charts/lxcfs-admission-webhook/MIGRATION.md (Recovery)." >&2
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

cat /lxcfs/lxcfs-mount.sh > "${LXCFS_SCRIPT_PATH}/lxcfs-mount.sh"
chmod +x "${LXCFS_SCRIPT_PATH}/lxcfs-mount.sh"

# Run lxcfs with whatever args were passed (CMD or container.args). Falls
# back to the historical default when invoked with no args, so the image
# still works when run standalone.
if [[ $# -eq 0 ]]; then
  set -- --foreground --enable-loadavg --enable-cfs
fi

echo /usr/bin/lxcfs "$@" "$LXCFS_PATH"
exec /usr/bin/lxcfs "$@" "$LXCFS_PATH"
