#!/usr/bin/env bash
set -eo pipefail

LXC_PATH="/var/lib/lxc"
LXCFS_PATH="${LXC_PATH}/lxcfs"
LXCFS_SCRIPT_PATH="${LXC_PATH}/script"

# Cleanup any stale mount left by a previous Pod on this node.
nsenter --target 1 --mount -- fusermount -u "$LXCFS_PATH" 2>/dev/null || true
[[ -d "$LXCFS_PATH" ]] && rm -rf "${LXCFS_PATH:?}"/*

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

