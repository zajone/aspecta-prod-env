#!/usr/bin/env bash
# Removes the cluster and everything in it. The images stay in the local docker
# cache so the next bootstrap is fast.

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if ! kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  ok "cluster '${CLUSTER_NAME}' does not exist, nothing to do"
  exit 0
fi

log "deleting the kind cluster '${CLUSTER_NAME}'"
kind delete cluster --name "${CLUSTER_NAME}"
# kind removes the entries it named itself; these were renamed after creation,
# so it cannot find them and would leave a dead context behind.
forget_kube_entries
# The CA is regenerated with the next cluster, so a copy of the old one on disk
# is worse than none: curl would trust the wrong root and fail confusingly.
rm -f "${CA_CERT_FILE}"
ok "cluster deleted"
dim "      container images are kept; run 'make clean-images' to remove them too"
