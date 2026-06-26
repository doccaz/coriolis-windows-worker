#!/usr/bin/env bash
# =============================================================================
# Apply a Harvester manifest after substituting the real per-image storage class
# into the __IMAGE_STORAGECLASS__ placeholder.
#
# Harvester generates a storage class per VM image with an auto-generated name
# (lh-<uuid>) and only once the image has finished importing. The name is not
# longhorn-<image name> — it must be read from the image's status.
#
# Usage:
#   apply-with-storageclass.sh <image-namespace> <image-name> <manifest.yaml>
# =============================================================================
set -euo pipefail

IMG_NS=${1:?image namespace required}
IMG_NAME=${2:?image name required}
MANIFEST=${3:?manifest path required}

TIMEOUT=${IMAGE_IMPORT_TIMEOUT:-600}   # seconds to wait for the image to import

# Pick up BUILD_NETWORK (the Multus NAD the VM attaches to) from config.env so
# the network is configurable in one place. Env overrides the file; fall back to
# the lab LAN bridge if neither is set.
_CONFIG_ENV="$(cd "$(dirname "${BASH_SOURCE[0]}")/../build" && pwd)/config.env"
[[ -f "$_CONFIG_ENV" ]] && source "$_CONFIG_ENV"
BUILD_NETWORK="${BUILD_NETWORK:-default/local-network}"

echo "Waiting (up to ${TIMEOUT}s) for image ${IMG_NS}/${IMG_NAME} storage class..."
deadline=$(( $(date +%s) + TIMEOUT ))
sc=""
while :; do
  sc=$(kubectl -n "$IMG_NS" get virtualmachineimage "$IMG_NAME" \
        -o jsonpath='{.status.storageClassName}' 2>/dev/null || true)
  [ -n "$sc" ] && break
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "ERROR: image ${IMG_NS}/${IMG_NAME} has no .status.storageClassName after ${TIMEOUT}s." >&2
    echo "       Check the import:  kubectl -n ${IMG_NS} get virtualmachineimage ${IMG_NAME}" >&2
    exit 1
  fi
  sleep 5
done

echo "Resolved storage class: ${sc}"
echo "Attaching VM to network: ${BUILD_NETWORK}"
sed -e "s/__IMAGE_STORAGECLASS__/${sc}/g" \
    -e "s#__BUILD_NETWORK__#${BUILD_NETWORK}#g" \
    "$MANIFEST" | kubectl apply -f -
