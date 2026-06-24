#!/usr/bin/env bash
# upload-to-harvester.sh — register the finished worker qcow2 in Harvester as a
# VirtualMachineImage (sourceType: upload), via the Harvester (Steve) REST API.
#
# No kubectl needed — only curl + jq, which the build host already has. Drives
# the same API the dashboard uses:
#   1. POST the VirtualMachineImage object (sourceType: upload).
#   2. POST the file to ?action=upload&size=<bytes> as a multipart "chunk".
#   3. Poll .status.progress until the import reaches 100%.
#
# Required: HARVESTER_SERVER, HARVESTER_TOKEN  (see build/config.env).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.env
source "$HERE/config.env"

IMG="${1:-$OUTPUT_DIR/$WORKER_IMAGE_NAME}"

# --- preflight -------------------------------------------------------------
command -v jq   >/dev/null || { echo "Missing 'jq'" >&2; exit 1; }
command -v curl >/dev/null || { echo "Missing 'curl'" >&2; exit 1; }
[[ -f "$IMG" ]]            || { echo "Image not found: $IMG" >&2; exit 1; }
[[ -n "$HARVESTER_SERVER" ]] || { echo "HARVESTER_SERVER is not set" >&2; exit 1; }
[[ -n "$HARVESTER_TOKEN"  ]] || { echo "HARVESTER_TOKEN is not set"  >&2; exit 1; }

SERVER="${HARVESTER_SERVER%/}"
NS="$HARVESTER_NAMESPACE"
NAME="$HARVESTER_IMAGE_NAME"
SIZE="$(stat -c%s "$IMG")"
K=(); [[ "$HARVESTER_INSECURE" == "true" ]] && K=(-k)
AUTH=(-H "Authorization: Bearer $HARVESTER_TOKEN")
COLL="$SERVER/v1/harvester/harvesterhci.io.virtualmachineimages"
OBJ="$COLL/$NS/$NAME"

log() { echo "[upload] $*"; }

# --- 1. create the image object (idempotent) -------------------------------
log "Registering VirtualMachineImage $NS/$NAME on $SERVER"
if curl -fsS "${K[@]}" "${AUTH[@]}" "$OBJ" >/dev/null 2>&1; then
    log "Image object already exists — reusing it."
else
    body="$(jq -nc \
        --arg ns "$NS" --arg name "$NAME" --arg disp "$HARVESTER_IMAGE_DISPLAY" \
        '{type:"harvesterhci.io.virtualmachineimage",
          metadata:{namespace:$ns,name:$name},
          spec:{displayName:$disp,sourceType:"upload"}}')"
    curl -fsS "${K[@]}" "${AUTH[@]}" -H 'Content-Type: application/json' \
        -X POST "$COLL" -d "$body" >/dev/null
    log "Created."
fi

# Give Harvester a moment to provision the backing PVC before streaming bytes.
for _ in $(seq 1 30); do
    curl -fsS "${K[@]}" "${AUTH[@]}" "$OBJ" >/dev/null 2>&1 && break
    sleep 2
done

# --- 2. upload the file ----------------------------------------------------
log "Uploading $IMG ($SIZE bytes) — this can take a while..."
# Sent as multipart/form-data field "chunk" (NOT application/octet-stream,
# which the API rejects with HTTP 415). curl streams from disk.
curl -fsS "${K[@]}" "${AUTH[@]}" \
    -F "chunk=@${IMG}" \
    "$OBJ?action=upload&size=$SIZE"
echo
log "Upload transfer complete; waiting for Harvester to finish importing."

# --- 3. poll import progress ----------------------------------------------
deadline=$(( $(date +%s) + 30*60 ))
while true; do
    json="$(curl -fsS "${K[@]}" "${AUTH[@]}" "$OBJ" 2>/dev/null || echo '{}')"
    progress="$(jq -r '.status.progress // 0' <<<"$json")"
    failed="$(jq -r '[.status.conditions[]? | select(.type=="Imported" and .status=="False" and (.reason//"")!="" and (.reason//"")!="Importing")] | length' <<<"$json")"
    log "import progress: ${progress}%"
    if [[ "$progress" == "100" ]]; then
        log "Image imported successfully: $NS/$NAME"
        break
    fi
    if [[ "$failed" != "0" && "$failed" != "" ]]; then
        echo "ERROR: Harvester reported an import failure:" >&2
        jq -r '.status.conditions' <<<"$json" >&2
        exit 1
    fi
    if (( $(date +%s) > deadline )); then
        echo "ERROR: timed out waiting for import (last progress ${progress}%)." >&2
        exit 1
    fi
    sleep 10
done
