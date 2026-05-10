FROM alpine:edge

LABEL maintainer="idoyo7 <idoyo7@gmail.com>"
LABEL org.opencontainers.image.source="https://github.com/idoyo7/lxcfs-admission-webhook"

ADD . /lxcfs


ARG LXCFS_VERSION=6.0.1-r1
ENV LXCFS_VERSION=${LXCFS_VERSION}

# alpine:edge so lxcfs and its libfuse3 ABI track upstream together.
# When LXCFS 7.x lands in edge/community Renovate will open a single
# PR bumping LXCFS_VERSION here and the chart's default tag.
RUN chmod +x /lxcfs/entrypoint.sh && \
    apk add --no-cache dumb-init bash lxcfs=${LXCFS_VERSION}

# dumb-init reaps zombies; entrypoint.sh prepares state then execs lxcfs
# with whatever flags were passed. CMD is overridable via the
# Kubernetes container.args field, which is how the chart exposes
# `lxcfs.args` to operators (handy when LXCFS picks up new flags
# like --enable-psi-poll in 7.x without rebuilding the image).
ENTRYPOINT ["/usr/bin/dumb-init", "--", "/lxcfs/entrypoint.sh"]

CMD ["--foreground", "--enable-loadavg", "--enable-cfs"]

