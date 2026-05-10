FROM --platform=$BUILDPLATFORM golang:1.24-alpine3.21 AS build
ARG TARGETOS TARGETARCH

WORKDIR /src

ADD . .

# Build runs on the runner's native arch (BUILDPLATFORM) and Go
# cross-compiles for TARGETOS/TARGETARCH, so multi-arch publishes
# don't pay the QEMU emulation tax for compilation.
# CGO_ENABLED=0 keeps the binary fully static and arch-portable.
RUN apk add --no-cache make git && \
    GOOS=$TARGETOS GOARCH=$TARGETARCH CGO_ENABLED=0 make build

FROM alpine:3.21

LABEL maintainer="idoyo7 <idoyo7@gmail.com>"
LABEL org.opencontainers.image.source="https://github.com/idoyo7/lxcfs-admission-webhook"

WORKDIR /lxcfs

COPY --from=build /src/build/lxcfs-admission-webhook /lxcfs/lxcfs-admission-webhook

EXPOSE 8443

ENTRYPOINT ["/lxcfs/lxcfs-admission-webhook"]
