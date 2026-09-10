# syntax=docker/dockerfile:1

# nginx-unprivileged listens on 8080 as uid 101 and keeps its pid file in /tmp,
# which is what allows the pod to run with runAsNonRoot and a read-only root
# filesystem without any entrypoint patching.
#
# The alpine-slim variant is deliberate, and it is a security decision rather
# than a size one: the full alpine image carries the perl, xslt and image-filter
# modules, which drag in libxslt, libexpat and libpng. This UI serves three
# static files, so none of them are used - but every CVE in them still counts
# against the image. Dropping to slim took the HIGH/CRITICAL count from 34 to 0
# and is what lets the Trivy gate in CI stay at exit-code 1.
#
# envsubst and the /docker-entrypoint.d scripts, which render the server block
# from BACKEND_ADDR at start-up, are present in the slim variant as well.
FROM nginxinc/nginx-unprivileged:1.31.5-alpine-slim@sha256:c94666682d7ecbfa0a1767fbe882cd1d82509333d15716c765f42bbef0d3809f

ARG VERSION=dev
ARG REVISION=unknown

LABEL org.opencontainers.image.title="aspecta-frontend" \
      org.opencontainers.image.description="Aspecta catalogue UI, static assets served by nginx" \
      org.opencontainers.image.source="https://github.com/zajone/aspecta-prod-env" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}"

# Address of the API upstream, substituted into the server block on start-up.
ENV BACKEND_ADDR="aspecta-backend:8080"

COPY nginx.conf.template /etc/nginx/templates/default.conf.template
COPY html/ /usr/share/nginx/html/

USER 101
EXPOSE 8080
