#!/usr/bin/env bash
# download-assets.sh — fetch the Windows ISO, SUSE VMDP ISO and cloudbase-init
# MSI into $ASSETS_DIR. Resumable; skips files already complete.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.env
source "$HERE/config.env"

mkdir -p "$ASSETS_DIR"

WIN_ISO="$ASSETS_DIR/windows-server-eval.iso"
VMDP_ISO="$ASSETS_DIR/vmdp.iso"
CB_MSI="$ASSETS_DIR/CloudbaseInitSetup_x64.msi"

fetch() {  # url dest
    local url="$1" dest="$2"
    echo ">> Downloading $(basename "$dest")"
    # -q ignores ~/.curlrc (must be first) so a stray user/root config can't
    # break the build; -C - resumes; --retry rides out flaky mirrors;
    # -L follows redirects.
    curl -q -fL --retry 5 --retry-delay 5 -C - -o "$dest" "$url"
}

fetch "$WIN_ISO_URL"       "$WIN_ISO"
fetch "$VIRTIO_VMDP_URL"   "$VMDP_ISO"
fetch "$CLOUDBASE_INIT_URL" "$CB_MSI"

echo
echo "Assets ready in $ASSETS_DIR:"
ls -lh "$WIN_ISO" "$VMDP_ISO" "$CB_MSI"
