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

# --- 0. ensure the file size is 512-byte (sector) aligned ------------------
# Longhorn backing images expect a sector-aligned file size; an unaligned
# `size=` upload can be rejected or import short. qcow2 output from
# `qemu-img convert` is always 512-aligned so this is a no-op for our build,
# but a raw or hand-truncated image may not be — pad up to the next boundary
# with zero bytes (trailing bytes are ignored by both qcow2 and raw readers).
rem=$(( SIZE % 512 ))
if (( rem != 0 )); then
    pad=$(( 512 - rem ))
    log "Image size $SIZE is not 512-aligned; padding $pad zero byte(s)."
    truncate -s "$(( SIZE + pad ))" "$IMG"   # extend with a zero-filled hole
    SIZE="$(stat -c%s "$IMG")"
fi

# --- 1. (re)create the image object ----------------------------------------
# A Harvester backing image is IMMUTABLE once it reaches Imported=True: you
# cannot stream a new file into an already-imported object — the upload action
# hangs and the ingress eventually returns 504. So if the object already exists
# (e.g. from a previous build) we DELETE it and recreate it empty, giving the
# upload a fresh backing image to fill. (Caller is responsible for ensuring no
# VM/PVC still references the old image before rebuilding.)
log "Registering VirtualMachineImage $NS/$NAME on $SERVER"
if curl -fsS "${K[@]}" "${AUTH[@]}" "$OBJ" >/dev/null 2>&1; then
    log "Image object already exists — deleting it so the upload gets a fresh, empty backing image."
    curl -fsS "${K[@]}" "${AUTH[@]}" -X DELETE "$OBJ" >/dev/null 2>&1 || true
    # Wait for the delete to finalize (finalizers clean up the Longhorn backing
    # image); recreating with the same name before it's gone would 409/conflict.
    for _ in $(seq 1 60); do
        curl -fsS "${K[@]}" "${AUTH[@]}" "$OBJ" >/dev/null 2>&1 || break
        sleep 2
    done
    if curl -fsS "${K[@]}" "${AUTH[@]}" "$OBJ" >/dev/null 2>&1; then
        echo "ERROR: existing image $NS/$NAME did not delete within 120s." >&2
        exit 1
    fi
fi
body="$(jq -nc \
    --arg ns "$NS" --arg name "$NAME" --arg disp "$HARVESTER_IMAGE_DISPLAY" \
    '{type:"harvesterhci.io.virtualmachineimage",
      metadata:{namespace:$ns,name:$name},
      spec:{displayName:$disp,sourceType:"upload"}}')"
curl -fsS "${K[@]}" "${AUTH[@]}" -H 'Content-Type: application/json' \
    -X POST "$COLL" -d "$body" >/dev/null
log "Created."

# Give Harvester a moment to provision the backing PVC before streaming bytes.
for _ in $(seq 1 30); do
    curl -fsS "${K[@]}" "${AUTH[@]}" "$OBJ" >/dev/null 2>&1 && break
    sleep 2
done

# --- 2. upload the file ----------------------------------------------------
log "Uploading $IMG ($SIZE bytes) — this can take a while..."
# Sent as multipart/form-data field "chunk" (NOT application/octet-stream,
# which the API rejects with HTTP 415). curl streams from disk.
# Force HTTP/1.1: streaming a multi-GB multipart body over HTTP/2 trips
# "curl (92): HTTP/2 stream not closed cleanly: PROTOCOL_ERROR" against the
# Harvester ingress. The small JSON calls above are fine on h2; only this
# large upload needs it.
curl -fsS --http1.1 "${K[@]}" "${AUTH[@]}" \
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
