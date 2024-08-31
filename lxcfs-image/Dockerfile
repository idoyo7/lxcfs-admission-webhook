FROM alpine:3

LABEL maintainer="ymping <ympiing@gmail.com>"

ADD . /lxcfs


ARG LXCFS_VERSION=6.0.1-r0
ENV LXCFS_VERSION=${LXCFS_VERSION}

RUN chmod +x /lxcfs/entrypoint.sh && \
        echo https://dl-cdn.alpinelinux.org/alpine/edge/community >> /etc/apk/repositories && \
    apk add --no-cache dumb-init bash lxcfs=${LXCFS_VERSION}

ENTRYPOINT ["/usr/bin/dumb-init", "--"]

CMD ["/lxcfs/entrypoint.sh"]

