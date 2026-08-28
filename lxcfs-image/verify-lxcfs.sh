#!/usr/bin/env bash
#
# Verify that an LXCFS image actually answers reads on its cpuview-backed
# files, or that a running cluster's LXCFS DaemonSet does.
#
# Why this exists: LXCFS 7.0.0 built against musl hangs forever on
# /proc/cpuinfo, /proc/stat and /sys/devices/system/cpu/online while
# /proc/meminfo answers instantly, because get_min_cpu_count_cfs() walks
# the cgroup hierarchy with dirname() and never terminates when dirname()
# does not truncate in place (https://github.com/lxc/lxcfs/issues/730).
# A daemon that starts, prints its api_extensions and FUSE-mounts
# successfully therefore proves nothing -- only reading a cpuview-backed
# file does.
#
#   ./verify-lxcfs.sh image ghcr.io/idoyo7/lxcfs:7.0.0-2
#   ./verify-lxcfs.sh cluster -n lxcfs
#
# See charts/lxcfs-admission-webhook/MIGRATION.md.

set -uo pipefail

MOUNT_PATH="/var/lib/lxc/lxcfs"
READ_TIMEOUT="${LXCFS_READ_TIMEOUT:-5}"

# The files that go through max_cpu_count() -> get_min_cpu_count_cfs(),
# i.e. the ones that hang. /proc/meminfo is checked too, as a control: if
# meminfo works and these do not, it is this bug and not a dead daemon.
CPUVIEW_FILES=(
  "proc/cpuinfo"
  "proc/stat"
  "sys/devices/system/cpu/online"
)
CONTROL_FILES=(
  "proc/meminfo"
  "proc/loadavg"
  "proc/uptime"
)

die() { echo "ERROR: $*" >&2; exit 1; }

usage() {
  cat <<EOF
usage: ${0##*/} image <image-ref> [--runtime docker|podman|nerdctl]
       ${0##*/} cluster [-n NAMESPACE] [--label app.kubernetes.io/name=lxcfs-admission-webhook]

  image    Run <image-ref> as a privileged container, read every
           virtualized file through its own FUSE mount, and check that the
           staged busybox can bind one of them into a root that contains
           no other executable and no dynamic loader. Requires a container
           runtime on this machine.

  cluster  Run a throwaway probe Pod in NAMESPACE and read the LXCFS
           files a mutated Pod would see. Requires kubectl and a
           namespace labelled 'lxcfs-admission-webhook=enabled'.

Environment:
  LXCFS_READ_TIMEOUT   seconds to allow per read (default ${READ_TIMEOUT})
EOF
  exit "${1:-0}"
}

# The read loop that runs inside the container/Pod. Emitted as a here-doc
# so both modes execute byte-identical checks.
#
# Every read is wrapped in timeout(1). That bounds the *reported* result;
# it does not kill a wedged reader, because a blocked FUSE read sits in
# uninterruptible sleep and cannot be signalled. That is why both modes
# below also impose an outer deadline from the outside and treat "no
# verdict" as failure.
read_probe_script() {
  local base=$1
  cat <<EOF
fail=0
for f in ${CONTROL_FILES[*]}; do
  out=\$(timeout ${READ_TIMEOUT} head -c 60 "${base}/\$f" 2>&1 | head -1)
  rc=\$?
  if [ \$rc -eq 0 ]; then echo "  ok      \$f  |\$out|"
  else echo "  FAIL    \$f  rc=\$rc  |\$out|"; fail=1; fi
done
for f in ${CPUVIEW_FILES[*]}; do
  out=\$(timeout ${READ_TIMEOUT} head -c 60 "${base}/\$f" 2>&1 | head -1)
  rc=\$?
  if [ \$rc -eq 0 ]; then echo "  ok      \$f  |\$out|"
  else echo "  FAIL    \$f  rc=\$rc  |\$out|  <-- cpuview-backed"; fail=1; fi
done
if [ \$fail -eq 0 ]; then echo "VERDICT: PASS"; else echo "VERDICT: FAIL"; fi
EOF
}

# The distroless-bind check that runs inside the container. Emitted as a
# here-doc for the same reason as read_probe_script.
#
# What this gates, and why it is shaped like this
# -----------------------------------------------
# Chart 0.4.0's postStart hook could not restore bind mounts in a
# container whose image ships no mount/umount: `nsenter -t <pid> -m --
# mount` resolves the binary inside the target, so it never ran, and the
# resulting exit status was read as "nothing to do". 0.4.1 executes a
# statically linked busybox staged at /var/lib/lxc/script/busybox instead.
#
# The full end-to-end proof needs two containers sharing the FUSE mount
# through the node, which needs mount propagation set up on the host --
# out of reach for a build-time gate that only has a container runtime.
# What image mode *can* prove, without leaving the container, is every
# property whose loss caused the bug:
#
#   - the staged busybox exists and is statically linked
#   - it executes with no dynamic loader reachable (chroot into a root
#     that has no /lib), which is exactly the distroless condition
#   - it accepts the two invocations lxcfs-mount.sh uses. This is the
#     check that would have caught 0.4.0's second failure: `mount -B` is
#     util-linux-only, so it also broke every Alpine-based container,
#     whose busybox mount rejects the flag.
#   - the two-step bind yields a read-only fuse.lxcfs mount, and reading
#     through it returns LXCFS data
#
# Cluster mode covers the rest: there, a real DaemonSet roll drives the
# real hooks against real Pods.
distroless_bind_script() {
  local base=$1
  cat <<EOF
set -u
bb=/var/lib/lxc/script/busybox
root=/tmp/lxcfs-nolibc
src=${base}/proc/meminfo
fail=0

step() { printf '  %-7s %s\n' "\$1" "\$2"; [ "\$1" = FAIL ] && fail=1; return 0; }

if [ -x "\$bb" ]; then step ok "staged busybox present: \$bb (\$(wc -c <"\$bb") bytes)"
else step FAIL "no staged busybox at \$bb"; echo "VERDICT: FAIL"; exit 0; fi

if ldd "\$bb" 2>&1 | grep -Eq 'not a dynamic executable|statically linked'; then
  step ok "statically linked"
else
  step FAIL "dynamically linked: \$(ldd "\$bb" 2>&1 | head -1)"
fi

# A root with nothing in it but the node's /var/lib/lxc. No /lib, so no
# dynamic loader; no /bin, so no mount, umount, test or sh.
rm -rf "\$root"
mkdir -p "\$root/var/lib/lxc" "\$root/proc" || step FAIL "cannot build \$root"
: > "\$root/proc/meminfo"
mount -o rbind /var/lib/lxc "\$root/var/lib/lxc" || step FAIL "cannot rbind /var/lib/lxc into \$root"
step ok "built an executable-free root at \$root (\$(ls -A "\$root" | tr '\n' ' '))"

if chroot "\$root" "\$bb" mount -o bind "\$src" /proc/meminfo; then
  step ok "chroot \$bb mount -o bind \$src /proc/meminfo"
else
  step FAIL "chroot \$bb mount -o bind failed (rc=\$?)"
fi

if chroot "\$root" "\$bb" mount -o remount,bind,ro,nosuid,nodev /proc/meminfo /proc/meminfo; then
  step ok "chroot \$bb mount -o remount,bind,ro,nosuid,nodev"
else
  step FAIL "chroot \$bb read-only remount failed (rc=\$?)"
fi

opts=\$(awk -v p="\$root/proc/meminfo" '
  { fstype = ""
    for (i = 7; i <= NF; i++) if (\$i == "-") { fstype = \$(i + 1); break }
    if (\$5 == p) print \$6 " " fstype }' /proc/self/mountinfo)
case "\$opts" in
  *fuse.lxcfs*) step ok "mount table says: \$opts" ;;
  '')           step FAIL "\$root/proc/meminfo is not in the mount table at all" ;;
  *)            step FAIL "not a fuse.lxcfs mount: \$opts" ;;
esac
case "\$opts" in
  ro,*|*,ro,*|*,ro) : ;;
  *) step FAIL "bind is not read-only: \$opts" ;;
esac

out=\$(timeout ${READ_TIMEOUT} head -1 "\$root/proc/meminfo" 2>&1)
case "\$out" in
  MemTotal:*) step ok "read through the bind: |\$out|" ;;
  *)          step FAIL "read through the bind returned |\$out|" ;;
esac

if chroot "\$root" "\$bb" umount /proc/meminfo; then
  step ok "chroot \$bb umount /proc/meminfo"
else
  step FAIL "chroot \$bb umount failed (rc=\$?)"
fi

umount -R "\$root/var/lib/lxc" 2>/dev/null
rm -rf "\$root"

if [ \$fail -eq 0 ]; then echo "VERDICT: PASS"; else echo "VERDICT: FAIL"; fi
EOF
}

verify_image() {
  local image="" runtime=""
  while (($#)); do
    case $1 in
      --runtime) runtime=$2; shift 2 ;;
      -h|--help) usage 0 ;;
      -*) die "unknown flag: $1" ;;
      *) image=$1; shift ;;
    esac
  done
  [[ -n $image ]] || usage 1

  if [[ -z $runtime ]]; then
    for r in docker podman nerdctl; do
      command -v "$r" >/dev/null && { runtime=$r; break; }
    done
  fi
  [[ -n $runtime ]] || die "no container runtime found (docker, podman or nerdctl)"
  command -v "$runtime" >/dev/null || die "$runtime not found"

  echo "runtime: $runtime"
  echo "image:   $image"
  echo

  local name="lxcfs-verify-$$"
  # --cgroupns=host is load-bearing: it gives the reading process a
  # multi-component cgroup path (/docker/<id>), which is what the broken
  # hierarchy walk needs to spin. With the default private cgroup
  # namespace the path is just "/", the walk terminates on its first
  # iteration, and a broken build passes.
  "$runtime" run -d --name "$name" --privileged --cgroupns=host \
    -v /sys/fs/cgroup:/sys/fs/cgroup \
    "$image" --foreground --enable-loadavg --enable-cfs >/dev/null \
    || die "failed to start $image"

  # shellcheck disable=SC2064
  trap "cleanup_image '$runtime' '$name'" EXIT

  sleep 5
  if ! "$runtime" exec "$name" sh -c "test -d '$MOUNT_PATH/proc'" 2>/dev/null; then
    echo "daemon log:"; "$runtime" logs "$name" 2>&1 | sed 's/^/  /'
    die "$MOUNT_PATH was never mounted"
  fi

  echo "reading virtualized files through $MOUNT_PATH:"
  local out
  out=$(run_with_deadline $((READ_TIMEOUT * 8 + 20)) \
        "$runtime" exec "$name" sh -c "$(read_probe_script "$MOUNT_PATH")")
  local rc=$?
  echo "$out"

  if ((rc == 124)); then
    echo
    echo "VERDICT: FAIL - the probe never returned."
    echo "A read is stuck in uninterruptible sleep, which is the LXCFS"
    echo "7.0.0 musl hang (https://github.com/lxc/lxcfs/issues/730)."
    return 1
  fi
  [[ $out == *"VERDICT: PASS"* ]] || return 1

  echo
  echo "binding a virtualized file into a root with no executables and no loader:"
  local dl_out
  dl_out=$(run_with_deadline $((READ_TIMEOUT * 4 + 20)) \
           "$runtime" exec "$name" sh -c "$(distroless_bind_script "$MOUNT_PATH")")
  local dl_rc=$?
  echo "$dl_out"

  if ((dl_rc == 124)); then
    echo
    echo "VERDICT: FAIL - the distroless bind check never returned."
    return 1
  fi
  if [[ $dl_out != *"VERDICT: PASS"* ]]; then
    echo
    echo "VERDICT: FAIL - this image cannot restore bind mounts in a container"
    echo "that ships no mount/umount of its own. Chart 0.4.0 shipped exactly"
    echo "that defect and skipped such containers in silence; see"
    echo "charts/lxcfs-admission-webhook/MIGRATION.md (0.4.0 -> 0.4.1)."
    return 1
  fi
  return 0
}

cleanup_image() {
  local runtime=$1 name=$2
  echo
  echo "cleaning up container $name"
  # A wedged mount can leave unkillable readers holding the FUSE
  # connection, so abort it before trying to remove the container.
  "$runtime" exec "$name" sh -c '
    mkdir -p /tmp/fusectl 2>/dev/null
    mount -t fusectl none /tmp/fusectl 2>/dev/null
    for c in /tmp/fusectl/*; do
      w=$(cat "$c/waiting" 2>/dev/null || echo 0)
      [ "${w:-0}" -gt 0 ] && echo 1 > "$c/abort"
    done
    umount /tmp/fusectl 2>/dev/null
    true' >/dev/null 2>&1
  "$runtime" rm -f "$name" >/dev/null 2>&1
}

verify_cluster() {
  local ns="default" label=""
  while (($#)); do
    case $1 in
      -n|--namespace) ns=$2; shift 2 ;;
      --label) label=$2; shift 2 ;;
      -h|--help) usage 0 ;;
      *) die "unknown argument: $1" ;;
    esac
  done

  command -v kubectl >/dev/null || die "kubectl not found"

  echo "namespace: $ns"
  if ! kubectl get ns "$ns" -o jsonpath='{.metadata.labels}' 2>/dev/null \
       | grep -q 'lxcfs-admission-webhook.*enabled'; then
    echo "WARN: namespace '$ns' does not carry lxcfs-admission-webhook=enabled;" >&2
    echo "      the probe Pod will not be mutated and this check proves nothing." >&2
  fi
  [[ -n $label ]] && echo "label:     $label"
  echo

  local pod="lxcfs-verify-$$"
  local deadline=$((READ_TIMEOUT * 8 + 30))

  # activeDeadlineSeconds is the outer bound: if a read wedges, the
  # container cannot be killed but the Pod is failed by the API server,
  # so this check still terminates.
  kubectl -n "$ns" run "$pod" \
    --restart=Never \
    --image=busybox:1.36 \
    --overrides="{\"spec\":{\"activeDeadlineSeconds\":${deadline}}}" \
    --command -- sh -c "$(read_probe_script "")" >/dev/null 2>&1 \
    || die "failed to create probe Pod"

  # shellcheck disable=SC2064
  trap "kubectl -n '$ns' delete pod '$pod' --force --grace-period=0 >/dev/null 2>&1" EXIT

  local waited=0 phase=""
  while ((waited < deadline + 15)); do
    phase=$(kubectl -n "$ns" get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null)
    [[ $phase == Succeeded || $phase == Failed ]] && break
    sleep 2
    waited=$((waited + 2))
  done

  echo "probe Pod phase: ${phase:-unknown}"
  echo "output:"
  kubectl -n "$ns" logs "$pod" 2>&1 | sed 's/^/  /'

  if kubectl -n "$ns" logs "$pod" 2>/dev/null | grep -q "VERDICT: PASS"; then
    return 0
  fi
  echo
  echo "VERDICT: FAIL - the probe did not report PASS."
  echo "If it produced no output at all, a read is stuck in uninterruptible"
  echo "sleep: see MIGRATION.md (Recovery) before rolling further nodes."
  return 1
}

# Run a command with a hard wall-clock deadline, returning 124 if it does
# not finish. Not timeout(1): the command may be blocked on a wedged FUSE
# mount and therefore unkillable, and timeout(1) would block in wait().
run_with_deadline() {
  local seconds=$1
  shift
  local tmp child waited=0
  tmp=$(mktemp)
  "$@" >"$tmp" 2>&1 &
  child=$!
  while kill -0 "$child" 2>/dev/null; do
    if ((waited >= seconds)); then
      cat "$tmp"; rm -f "$tmp"
      return 124
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$child"
  cat "$tmp"
  rm -f "$tmp"
  return 0
}

main() {
  (($#)) || usage 1
  case $1 in
    image)   shift; verify_image "$@" ;;
    cluster) shift; verify_cluster "$@" ;;
    -h|--help) usage 0 ;;
    *) die "unknown mode: $1 (expected 'image' or 'cluster')" ;;
  esac
}

main "$@"
