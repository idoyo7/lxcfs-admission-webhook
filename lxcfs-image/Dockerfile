# Build LXCFS from the upstream release tarball on a glibc base.
#
# Why glibc and not Alpine/musl (chart 0.3.0 shipped an alpine:3.22 build
# and it hung nodes in production):
#
#   * Upstream develops and CI-tests LXCFS exclusively on glibc — its
#     .github/workflows/tests.yml matrix is ubuntu-22.04/24.04 on x86_64
#     and arm64. There is no musl job, so musl regressions ship unnoticed.
#   * v7.0.0 shipped exactly such a regression: get_min_cpu_count_cfs()
#     walks a cgroup path with dirname() and re-tests the input buffer,
#     which only terminates if dirname() truncated in place. glibc does;
#     musl returns a static "/" for single-component absolute paths and
#     leaves the buffer alone, so the loop never ends. Every read of
#     /proc/cpuinfo, /proc/stat and (with --enable-cfs)
#     /sys/devices/system/cpu/online spins a FUSE worker at 100% CPU and
#     never answers, wedging readers in uninterruptible sleep.
#     https://github.com/lxc/lxcfs/issues/730
#
# patches/ additionally carries that upstream fix, so the image is correct
# even if it is ever rebased onto a musl base again. Both belt and braces
# are deliberate: the base choice tracks what upstream tests, the patch
# fixes the actual defect.
FROM debian:bookworm-slim AS build

ARG DEBIAN_FRONTEND=noninteractive

# build-essential/meson/ninja-build/pkg-config: the meson toolchain.
# libfuse3-dev: LXCFS 7.x is libfuse3-only (upstream removed libfuse2).
# python3-jinja2: used by meson to render the generated sources.
# ca-certificates + curl: fetch the release tarball. patch: patches/.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        build-essential \
        meson \
        ninja-build \
        pkg-config \
        libfuse3-dev \
        python3-jinja2 \
        ca-certificates \
        curl \
        patch && \
    rm -rf /var/lib/apt/lists/*

ARG LXCFS_VERSION=7.0.0

RUN curl -fsSL -o /tmp/lxcfs.tar.gz \
        "https://github.com/lxc/lxcfs/archive/refs/tags/v${LXCFS_VERSION}.tar.gz" && \
    mkdir -p /usr/src/lxcfs && \
    tar xzf /tmp/lxcfs.tar.gz -C /usr/src/lxcfs --strip-components=1 && \
    rm -f /tmp/lxcfs.tar.gz

WORKDIR /usr/src/lxcfs

# Apply carried patches -- version-aware, not unconditional.
#
# This pipeline builds multiple LXCFS release lines (LXCFS_VERSION is a
# one-line .env change), and a patch that fixes a bug introduced in one
# release is often simply inapplicable to another: the buggy code may not
# exist yet (older release, predates the bug) or may no longer exist
# (newer release, upstream fixed it itself). Gate each patch on whether
# the code it targets is actually present, rather than on LXCFS_VERSION,
# so the check keeps working if the applicable version range ever changes:
#   - pattern present -> the patch MUST apply; hard-fail the build if it
#     does not (this is the "silently ships a broken image" case that
#     must never happen).
#   - pattern absent  -> this release doesn't have the bug; skip the
#     patch and say why, and keep going.
#
# Every patch must have a case below. An unrecognised patch file fails
# the build loudly instead of being silently applied or silently skipped.
COPY patches/ /usr/src/lxcfs-patches/
RUN set -eu; \
    for p in /usr/src/lxcfs-patches/*.patch; do \
        name=$(basename "$p"); \
        case "$name" in \
          0001-cpuview-*) \
            # Targets get_min_cpu_count_cfs() in src/proc_cpuview.c,
            # added by lxc/lxcfs#690 and first shipped in v7.0.0. Releases
            # before that (e.g. 6.0.6) lack the function entirely. \
            target=src/proc_cpuview.c; pattern=get_min_cpu_count_cfs; required_from_major=7 ;; \
          *) \
            echo "ERROR: $name has no applicability check registered in this Dockerfile" >&2; \
            exit 1 ;; \
        esac; \
        if [ -f "$target" ] && grep -q "$pattern" "$target"; then \
            echo "applying $name (found '$pattern' in $target)"; \
            patch -p1 --no-backup-if-mismatch < "$p"; \
        else \
            major=${LXCFS_VERSION%%.*}; \
            case "$major" in \
              ''|*[!0-9]*) \
                echo "ERROR: cannot parse a major version from LXCFS_VERSION='${LXCFS_VERSION}'" >&2; \
                exit 1 ;; \
            esac; \
            if [ "$major" -ge "$required_from_major" ]; then \
                echo "ERROR: $name expects '$pattern' in $target for LXCFS_VERSION ${required_from_major}.x and newer," >&2; \
                echo "       but it is absent in ${LXCFS_VERSION}. Either upstream fixed the defect (delete the" >&2; \
                echo "       patch and this case), or it renamed/moved the code while keeping the bug -- in which" >&2; \
                echo "       case retarget the patch. Do NOT relax this check: skipping here ships an image that" >&2; \
                echo "       can spin a FUSE worker forever and wedge a node. See lxc/lxcfs#730." >&2; \
                exit 1; \
            fi; \
            echo "skipping $name ('$pattern' not found in $target; not applicable to LXCFS_VERSION=${LXCFS_VERSION})"; \
        fi; \
    done

# tests/docs are off (docs=false also drops the help2man build dep);
# init-script=[] skips the systemd/openrc/sysvinit unit install since
# this image only ever runs lxcfs directly under dumb-init.
#
# --libdir=lib is load-bearing on Debian: meson would otherwise default
# to the multiarch libdir (lib/aarch64-linux-gnu, lib/x86_64-linux-gnu),
# and meson bakes that path into the binary as LIBDIR, which lxcfs.c uses
# to dlopen "$LIBDIR/lxcfs/liblxcfs.so". Pinning it keeps the install
# layout — and therefore the COPY lines below — identical on amd64 and
# arm64 instead of arch-dependent.
RUN meson setup build --prefix=/usr --libdir=lib --localstatedir=/var \
        -Dtests=false \
        -Ddocs=false \
        -Dinit-script='[]' && \
    meson compile -C build && \
    DESTDIR=/out meson install -C build

FROM debian:bookworm-slim

LABEL maintainer="idoyo7 <idoyo7@gmail.com>"
LABEL org.opencontainers.image.source="https://github.com/idoyo7/lxcfs-admission-webhook"

ARG DEBIAN_FRONTEND=noninteractive

ADD . /lxcfs

ARG LXCFS_VERSION=7.0.0
ENV LXCFS_VERSION=${LXCFS_VERSION}

# fuse3 provides both fusermount3 and fusermount (Alpine ships only the
# former, which is why entrypoint.sh tries both names); libfuse3-3 is the
# runtime library lxcfs links against; dumb-init reaps zombies. bash,
# nsenter/umount (util-linux), awk, cmp, stat and coreutils' timeout
# already ship in debian:bookworm-slim.
#
# busybox-static is not for this container's own use. entrypoint.sh stages
# it onto the node at /var/lib/lxc/script/busybox, from where
# lxcfs-mount.sh exec's it inside each mutated container to run the one
# thing that cannot be done from the host: mount(2) and umount2(2) act on
# the caller's mount namespace. `nsenter -t <pid> -m -- mount` resolves the
# binary in the *target's* filesystem, so it fails outright in a distroless
# image -- oauth2-proxy, istio-proxy, anything on gcr.io/distroless or a
# Chainguard base -- which ships no mount, no umount, no test and no shell.
# The webhook already bind-mounts /var/lib/lxc/ into every Pod it mutates
# (cmd/volume.go), so a binary dropped there is reachable inside all of
# them with no cooperation from the workload's image. Static because those
# images have no dynamic loader either.
#
# The loop is a build-time contract, not decoration: entrypoint.sh,
# lxcfs-mount.sh and verify-lxcfs.sh shell out to every one of these, and
# a silently missing binary here would only show up as a broken hook on a
# node. Fail the build instead.
RUN chmod +x /lxcfs/entrypoint.sh /lxcfs/verify-lxcfs.sh && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        dumb-init \
        fuse3 \
        libfuse3-3 \
        busybox-static && \
    rm -rf /var/lib/apt/lists/* && \
    for b in bash nsenter mount umount chroot awk cmp stat timeout fusermount3 fusermount dumb-init busybox; do \
        command -v "$b" >/dev/null || { echo "missing required binary: $b" >&2; exit 1; }; \
    done && \
    # Prove the staged busybox is what the distroless path needs. A
    # dynamically linked one would fail to exec in exactly the containers
    # this exists for, and an applet compiled out would fail at the mount.
    if ! ldd /bin/busybox 2>&1 | grep -Eq 'not a dynamic executable|statically linked'; then \
        echo "ERROR: /bin/busybox is not statically linked" >&2; \
        ldd /bin/busybox >&2 || true; \
        exit 1; \
    fi && \
    for a in mount umount; do \
        busybox --list | grep -qx "$a" || \
            { echo "ERROR: busybox has no '$a' applet" >&2; exit 1; }; \
    done

COPY --from=build /out/usr/bin/lxcfs /usr/bin/lxcfs
COPY --from=build /out/usr/lib/lxcfs /usr/lib/lxcfs

# dumb-init reaps zombies; entrypoint.sh prepares state then execs lxcfs
# with whatever flags were passed. CMD is overridable via the
# Kubernetes container.args field, which is how the chart exposes
# `lxcfs.args` to operators (handy when LXCFS picks up new flags
# without rebuilding the image).
ENTRYPOINT ["/usr/bin/dumb-init", "--", "/lxcfs/entrypoint.sh"]

CMD ["--foreground", "--enable-loadavg", "--enable-cfs"]
