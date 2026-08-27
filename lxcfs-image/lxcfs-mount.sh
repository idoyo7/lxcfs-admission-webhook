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
bounded_umount() {
  local container_pid=$1 path=$2

  echo nsenter -t "$container_pid" -m -p -- umount -v "$path"
  if run_bounded "$ACTION_TIMEOUT" \
       nsenter -t "$container_pid" -m -p -- umount -v "$path"; then
    return 0
  fi

  echo "WARN: umount of '$path' in pid $container_pid did not succeed;" \
       "retrying lazily (umount -l)" >&2
  run_bounded "$ACTION_TIMEOUT" \
    nsenter -t "$container_pid" -m -p -- umount -lv "$path"
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

  --umount            umount fuse.lxcfs filesystem mount in container
  --remount           umount fuse.lxcfs filesystem mount in container and remount it

Environment

  LXCFS_PROBE_TIMEOUT   seconds to wait for a single read of an LXCFS
                        file before declaring the mount wedged
                        (default: ${PROBE_TIMEOUT})
  LXCFS_ACTION_TIMEOUT  seconds to wait for a mount/umount to complete
                        (default: ${ACTION_TIMEOUT})

--remount exits non-zero if any probe times out, so a wedged mount shows
up as FailedPostStartHook instead of hanging the hook forever.

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
    containers=$(crictl ps --quiet --pod "$pod")
    for container in $containers; do
      pid=$(crictl inspect --output=json "$container" | python3 -c "import sys, json; print(json.load(sys.stdin)['info']['pid'])")
      echo "adjust lxcfs mount in container $container on $(hostname) with crictl"
      lxcfs_mount "$pid"
    done
  done
}

main() {
  pre_check

  if [[ $# -eq 1 ]]; then
    case $1 in
    --umount)
      UMOUNT=true
      ;;
    --remount)
      REMOUNT=true
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

  if ((${#WEDGED_PATHS[@]} > 0)); then
    {
      echo
      echo "==================================================================="
      echo "LXCFS FUSE mount is not answering on $(hostname)."
      echo
      echo "These probes timed out after ${PROBE_TIMEOUT}s each:"
      printf '  - %s\n' "${WEDGED_PATHS[@]}"
      echo
      echo "The lxcfs daemon accepted the mount but stopped answering reads."
      echo "Anything that reads those paths is now stuck in uninterruptible"
      echo "sleep and cannot be killed. Recover with:"
      echo
      echo "  mountpoint -q /sys/fs/fuse/connections ||"
      echo "    mount -t fusectl none /sys/fs/fuse/connections"
      echo "  grep -l '^[1-9]' /sys/fs/fuse/connections/*/waiting"
      echo "  echo 1 > /sys/fs/fuse/connections/<N>/abort"
      echo "  pkill -f '/usr/bin/lxcfs'"
      echo "  umount -l ${LXCFS_PATH}"
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
}

main "$@"
