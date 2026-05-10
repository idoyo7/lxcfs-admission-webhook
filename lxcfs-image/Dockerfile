FROM alpine:3.21

LABEL maintainer="idoyo7 <idoyo7@gmail.com>"
LABEL org.opencontainers.image.source="https://github.com/idoyo7/lxcfs-admission-webhook"

ADD . /lxcfs


ARG LXCFS_VERSION=6.0.1-r0
ENV LXCFS_VERSION=${LXCFS_VERSION}

# lxcfs lives in alpine:3.21's community repo (already enabled). The
# edge override is intentionally dropped: edge's lxcfs builds against
# libfuse3.so.4, which alpine:3.21 main does not provide.
RUN chmod +x /lxcfs/entrypoint.sh && \
    apk add --no-cache dumb-init bash lxcfs=${LXCFS_VERSION}

ENTRYPOINT ["/usr/bin/dumb-init", "--"]

CMD ["/lxcfs/entrypoint.sh"]

