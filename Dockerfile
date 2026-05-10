FROM golang:1.24-alpine3.21 AS build

WORKDIR /src

ADD . .

RUN apk add --no-cache make git && make build

FROM alpine:3.21

LABEL maintainer="ymping <ympiing@gmail.com>"

WORKDIR /lxcfs

COPY --from=build /src/build/lxcfs-admission-webhook /lxcfs/lxcfs-admission-webhook

EXPOSE 8443

ENTRYPOINT ["/lxcfs/lxcfs-admission-webhook"]
