#!/usr/bin/env bash
# make-config-iso.sh — build the small "config" CD that drives the unattended
# Windows install. It carries:
#   /autounattend.xml                    (token-substituted answer file)
#   /toolkit/*                           (configure-worker.ps1, cloudbase confs,
#                                         cloudbase-init MSI, qemu-ga binaries)
#   /drivers/*                           (every virtio .inf extracted from VMDP)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.env
source "$HERE/config.env"

VMDP_ISO="$ASSETS_DIR/vmdp.iso"
CB_MSI="$ASSETS_DIR/CloudbaseInitSetup_x64.msi"
CONFIG_ISO="$ASSETS_DIR/config.iso"
STAGE="$(mktemp -d)"
trap 'chmod -R u+w "$STAGE" 2>/dev/null; rm -rf "$STAGE"' EXIT

[[ -f "$VMDP_ISO" ]] || { echo "Missing $VMDP_ISO — run download-assets.sh first" >&2; exit 1; }
[[ -f "$CB_MSI"   ]] || { echo "Missing $CB_MSI — run download-assets.sh first"   >&2; exit 1; }

echo ">> Staging answer file (index=$WIN_IMAGE_INDEX)"
mkdir -p "$STAGE/toolkit" "$STAGE/drivers"
sed -e "s/@WIN_IMAGE_INDEX@/$WIN_IMAGE_INDEX/g" \
    -e "s/@BUILD_ADMIN_PASSWORD@/$BUILD_ADMIN_PASSWORD/g" \
    "$WINDOWS_SRC_DIR/autounattend.xml" > "$STAGE/autounattend.xml"

echo ">> Staging toolkit"
cp "$WINDOWS_SRC_DIR/configure-worker.ps1"          "$STAGE/toolkit/"
cp "$WINDOWS_SRC_DIR/cloudbase-init.conf"           "$STAGE/toolkit/"
cp "$WINDOWS_SRC_DIR/cloudbase-init-unattend.conf"  "$STAGE/toolkit/"
cp "$CB_MSI"                                        "$STAGE/toolkit/CloudbaseInitSetup_x64.msi"

# The specialize-pass xcopy in autounattend.xml expects everything under
# \toolkit, so mirror the drivers there too (configure-worker.ps1 reads
# C:\coriolis-build\drivers).
echo ">> Extracting virtio .inf drivers from VMDP ISO"
# Extract with bsdtar (libarchive) instead of a loopback mount, so no root is
# needed. bsdtar reads ISO9660/Joliet/Rock-Ridge directly into a temp dir.
VMDP_MNT="$(mktemp -d)"
cleanup_mnt() { chmod -R u+w "$VMDP_MNT" 2>/dev/null; rm -rf "$VMDP_MNT" 2>/dev/null || true; }
trap 'cleanup_mnt; chmod -R u+w "$STAGE" 2>/dev/null; rm -rf "$STAGE"' EXIT
bsdtar -xf "$VMDP_ISO" -C "$VMDP_MNT"

inf_found=0
# Copy the parent directory of every .inf so its .sys/.cat siblings come along.
while IFS= read -r -d '' inf; do
    d="$(dirname "$inf")"
    rel="${d#"$VMDP_MNT"/}"
    mkdir -p "$STAGE/drivers/$rel"
    cp -a "$d/." "$STAGE/drivers/$rel/" 2>/dev/null || true
    inf_found=$((inf_found+1))
done < <(find "$VMDP_MNT" -iname '*.inf' -print0)

if [[ "$inf_found" -eq 0 ]]; then
    echo "!! No loose .inf files on the VMDP ISO — copying the whole ISO so the"
    echo "!! Windows side can run the VMDP installer/extractor as a fallback."
    cp -a "$VMDP_MNT/." "$STAGE/drivers/vmdp-iso/"
fi
# Put a copy of the drivers under \toolkit so xcopy carries them to C:.
cp -a "$STAGE/drivers" "$STAGE/toolkit/drivers"

# Stage the QEMU guest agent (VMDP ships it as loose binaries, not an MSI). With
# it installed, Harvester/KubeVirt can report the guest's IP; without it the
# agent channel stays silent. configure-worker.ps1 installs it from C:\coriolis-
# build\qemu-ga. qemu-ga.exe (x64) is linked against the mingw 64-bit runtime
# DLLs shipped beside it, so place those next to the exe.
if [[ -f "$VMDP_MNT/qemu-ga/x64/qemu-ga.exe" ]]; then
    echo ">> Staging QEMU guest agent (x64 + mingw64 runtime) from VMDP ISO"
    mkdir -p "$STAGE/toolkit/qemu-ga"
    cp -a "$VMDP_MNT/qemu-ga/x64/."     "$STAGE/toolkit/qemu-ga/"
    cp -a "$VMDP_MNT/qemu-ga/mingw64/." "$STAGE/toolkit/qemu-ga/" 2>/dev/null || true
else
    echo "!! qemu-ga not found on VMDP ISO — Harvester won't report the guest IP."
fi
cleanup_mnt
trap 'chmod -R u+w "$STAGE" 2>/dev/null; rm -rf "$STAGE"' EXIT
echo ">> Bundled $inf_found virtio .inf driver folder(s)."

echo ">> Building $CONFIG_ISO"
# -J Joliet, -r Rock Ridge, -V volume label. genisoimage or its xorriso alias.
if command -v genisoimage >/dev/null; then MKISO=genisoimage; else MKISO="xorrisofs"; fi
"$MKISO" -J -r -V CORIOLIS -o "$CONFIG_ISO" "$STAGE"
echo ">> Config ISO ready: $CONFIG_ISO"
