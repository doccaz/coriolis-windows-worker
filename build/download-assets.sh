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

fetch() {  # url dest [expected-sha256]
    local url="$1" dest="$2" want="${3,,}"
    # If the file is already there and matches its checksum, don't touch it —
    # this also avoids the case below where a qemu-owned leftover can't be
    # opened for the resume write.
    if [[ -f "$dest" && -n "$want" ]] && \
       echo "$want  $dest" | sha256sum -c --status - 2>/dev/null; then
        echo ">> $(basename "$dest") already present and verified — skipping download"
        return 0
    fi
    # A previous local build may have left this owned by qemu (libvirt DAC
    # dynamic ownership), so we — as a different, non-owning user — can't open it
    # for the `-C -` resume write (EACCES). We *can* still unlink it because
    # ASSETS_DIR is ours; drop the non-writable leftover so curl recreates it.
    if [[ -e "$dest" && ! -w "$dest" ]]; then
        echo ">> $(basename "$dest") exists but isn't writable (owner $(stat -c%U "$dest")); removing to re-fetch"
        rm -f "$dest"
    fi
    echo ">> Downloading $(basename "$dest")"
    # -q ignores ~/.curlrc (must be first) so a stray user/root config can't
    # break the build; -C - resumes; --retry rides out flaky mirrors;
    # -L follows redirects.
    curl -q -fL --retry 5 --retry-delay 5 -C - -o "$dest" "$url"
}

verify() {  # dest expected-sha256
    local dest="$1" want="${2,,}"   # lower-case the expected hash
    if [[ -z "$want" ]]; then
        echo "   (no SHA256 configured for $(basename "$dest") — skipping verify)"
        return 0
    fi
    echo ">> Verifying $(basename "$dest")"
    local got
    got="$(sha256sum "$dest" | awk '{print $1}')"
    if [[ "$got" != "$want" ]]; then
        echo "CHECKSUM MISMATCH for $dest" >&2
        echo "  expected: $want" >&2
        echo "  got:      $got" >&2
        echo "Delete the file and re-run, or fix the *_SHA256 value in config.env." >&2
        exit 1
    fi
    echo "   OK ($got)"
}

fetch  "$WIN_ISO_URL"        "$WIN_ISO"   "${WIN_ISO_SHA256:-}"
verify "$WIN_ISO"            "${WIN_ISO_SHA256:-}"
fetch  "$VIRTIO_VMDP_URL"    "$VMDP_ISO"  "${VIRTIO_VMDP_SHA256:-}"
verify "$VMDP_ISO"           "${VIRTIO_VMDP_SHA256:-}"
fetch  "$CLOUDBASE_INIT_URL" "$CB_MSI"    "${CLOUDBASE_INIT_SHA256:-}"
verify "$CB_MSI"             "${CLOUDBASE_INIT_SHA256:-}"

echo
echo "Assets ready in $ASSETS_DIR:"
ls -lh "$WIN_ISO" "$VMDP_ISO" "$CB_MSI"
