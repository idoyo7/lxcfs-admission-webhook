FROM alpine:3.22 AS build

# Alpine's distro package trails upstream LXCFS releases by design.
# Build the upstream release tarball from source instead, so the
# image can move as soon as a new LXCFS version ships, independent of
# Alpine's packaging schedule.
RUN apk add --no-cache \
        build-base \
        meson \
        ninja \
        pkgconf \
        fuse3-dev \
        linux-headers \
        py3-jinja2 \
        curl

ARG LXCFS_VERSION=7.0.0

RUN curl -fsSL -o /tmp/lxcfs.tar.gz \
        "https://github.com/lxc/lxcfs/archive/refs/tags/v${LXCFS_VERSION}.tar.gz" && \
    mkdir -p /usr/src/lxcfs && \
    tar xzf /tmp/lxcfs.tar.gz -C /usr/src/lxcfs --strip-components=1 && \
    rm -f /tmp/lxcfs.tar.gz

WORKDIR /usr/src/lxcfs

# tests/docs are off (docs=false also drops the help2man build dep);
# init-script=[] skips the systemd/openrc/sysvinit unit install since
# this image only ever runs lxcfs directly under dumb-init.
RUN meson setup build --prefix=/usr --localstatedir=/var \
        -Dtests=false \
        -Ddocs=false \
        -Dinit-script='[]' && \
    meson compile -C build && \
    DESTDIR=/out meson install -C build

FROM alpine:3.22

LABEL maintainer="idoyo7 <idoyo7@gmail.com>"
LABEL org.opencontainers.image.source="https://github.com/idoyo7/lxcfs-admission-webhook"

ADD . /lxcfs

ARG LXCFS_VERSION=7.0.0
ENV LXCFS_VERSION=${LXCFS_VERSION}

# fuse3 provides fusermount3 (no fusermount alias on Alpine) and the
# libfuse3 runtime lxcfs links against; util-linux provides nsenter,
# both of which entrypoint.sh shells out to. libgcc supplies
# libgcc_s.so.1 (unwinder), which the musl-built lxcfs binary and
# liblxcfs.so both link against.
RUN chmod +x /lxcfs/entrypoint.sh && \
    apk add --no-cache dumb-init bash fuse3 util-linux libgcc

COPY --from=build /out/usr/bin/lxcfs /usr/bin/lxcfs
COPY --from=build /out/usr/lib/lxcfs /usr/lib/lxcfs

# dumb-init reaps zombies; entrypoint.sh prepares state then execs lxcfs
# with whatever flags were passed. CMD is overridable via the
# Kubernetes container.args field, which is how the chart exposes
# `lxcfs.args` to operators (handy when LXCFS picks up new flags
# without rebuilding the image).
ENTRYPOINT ["/usr/bin/dumb-init", "--", "/lxcfs/entrypoint.sh"]

CMD ["--foreground", "--enable-loadavg", "--enable-cfs"]
