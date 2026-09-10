# syntax=docker/dockerfile:1

# --- build stage -------------------------------------------------------------
# The builder is pinned to a minor version so a rebuild of an old commit still
# produces a comparable binary.
FROM golang:1.27-alpine@sha256:cf6fca6641884b8433441b2b0652976f975e1d0fdd26d177eaaf8596087f3125 AS build

# TARGETOS/TARGETARCH are supplied by buildx and make the same Dockerfile
# produce amd64 (WSL, CI runners) and arm64 (Apple silicon) images.
ARG TARGETOS=linux
ARG TARGETARCH=amd64
ARG VERSION=dev
ARG REVISION=unknown

WORKDIR /src

# Dependencies are copied first so the module cache layer survives source edits.
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download

COPY . .
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build -trimpath \
      -ldflags="-s -w -X main.version=${VERSION} -X main.revision=${REVISION}" \
      -o /out/aspecta-backend .

# --- runtime stage -----------------------------------------------------------
# distroless/static holds no shell, no package manager and no libc, which
# removes nearly the whole attack surface of a base image. The nonroot tag
# already runs as uid 65532, so the image cannot be started as root by accident.
FROM gcr.io/distroless/static-debian12:nonroot@sha256:afa5c872c891853ca7fcf1f12c3edb23f7eeef36189728842dd51042ff57f7ab

ARG VERSION=dev
ARG REVISION=unknown

LABEL org.opencontainers.image.title="aspecta-backend" \
      org.opencontainers.image.description="Aspecta deep-sky catalogue API" \
      org.opencontainers.image.source="https://github.com/zajone/aspecta-prod-env" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}"

COPY --from=build /out/aspecta-backend /usr/local/bin/aspecta-backend

USER 65532:65532
EXPOSE 8080 9090

ENTRYPOINT ["/usr/local/bin/aspecta-backend"]
