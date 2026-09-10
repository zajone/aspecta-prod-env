#!/usr/bin/env bash
# Builds the two container images and loads them into the kind cluster.
#
# The tag is the chart's appVersion, which is also what the chart asks for by
# default, so the cluster runs the code in the working tree without any values
# override. In the GitOps flow the same tag is produced by CI and pushed to
# GHCR; loading the image directly is what lets the environment come up on a
# fresh machine with no registry credentials at all.

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHART_FILE="${REPO_ROOT}/charts/aspecta/Chart.yaml"
LOAD_INTO_CLUSTER="${LOAD_INTO_CLUSTER:-true}"

have yq || die "yq is missing. Run scripts/install-tools.sh first."

VERSION="$(yq '.appVersion' "${CHART_FILE}")"
if [ -z "${VERSION}" ] || [ "${VERSION}" = "null" ]; then
  die "could not read appVersion from ${CHART_FILE}"
fi

REGISTRY="$(yq '.global.image.registry' "${REPO_ROOT}/charts/aspecta/values.yaml")"
OWNER="${IMAGE_OWNER:-$(github_owner || yq '.global.image.owner' "${REPO_ROOT}/charts/aspecta/values.yaml")}"
REVISION="$(git -C "${REPO_ROOT}" rev-parse --short HEAD 2>/dev/null || echo unknown)"

log "building images ${REGISTRY}/${OWNER}/aspecta-{backend,frontend}:${VERSION} (revision ${REVISION})"

build_one() {
  local component="$1"
  local image="${REGISTRY}/${OWNER}/aspecta-${component}:${VERSION}"
  DOCKER_BUILDKIT=1 docker build \
    --build-arg "VERSION=${VERSION}" \
    --build-arg "REVISION=${REVISION}" \
    --tag "${image}" \
    --file "${REPO_ROOT}/apps/${component}/Dockerfile" \
    "${REPO_ROOT}/apps/${component}" >/dev/null
  ok "${image} ($(docker image inspect "${image}" --format '{{.Size}}' | awk '{printf "%.1f MB", $1 / 1048576}'))"
}

build_one backend
build_one frontend

if [ "${LOAD_INTO_CLUSTER}" != "true" ]; then
  exit 0
fi

if ! kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  warn "kind cluster '${CLUSTER_NAME}' does not exist, images were built but not loaded"
  exit 0
fi

log "loading images into the ${CLUSTER_NAME} cluster"
for component in backend frontend; do
  kind load docker-image "${REGISTRY}/${OWNER}/aspecta-${component}:${VERSION}" --name "${CLUSTER_NAME}" >/dev/null
  ok "loaded aspecta-${component}:${VERSION}"
done
