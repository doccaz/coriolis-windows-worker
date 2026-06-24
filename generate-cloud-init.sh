#!/usr/bin/env bash
# generate-cloud-init.sh — assemble a single, self-contained Harvester
# cloud-init (NoCloud user-data) from the authoritative files in build/ and
# windows/. The repo files are the source of truth; this just embeds them
# (base64) into write_files so the Leap build host needs no external fetch.
#
# Output: cloud-init/user-data.yaml
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$HERE/cloud-init/user-data.yaml"
mkdir -p "$HERE/cloud-init"

# Pick which config.env to embed on the build host. A local build/config.env
# (the real, git-ignored one with your Harvester token) takes precedence; if
# you haven't created one, fall back to the committed example so a fresh clone
# still generates a valid — if upload-disabled — cloud-init.
CONFIG_SRC="$HERE/build/config.env"
if [[ ! -f "$CONFIG_SRC" ]]; then
    CONFIG_SRC="$HERE/build/config.env.example"
    echo "note: build/config.env not found — embedding config.env.example (safe defaults, Harvester upload off)." >&2
    echo "      copy build/config.env.example -> build/config.env and fill it in to embed real settings." >&2
fi

# emit_file <dest-path-on-host> <local-source> <mode>
emit_file() {
    local dest="$1" src="$2" mode="$3"
    [[ -f "$src" ]] || { echo "ERROR: source file not found: $src" >&2; exit 1; }
    local b64
    # Assign separately so base64's exit status isn't masked by `local`.
    b64="$(base64 -w0 "$src")"
    {
        echo "  - path: $dest"
        echo "    permissions: '$mode'"
        echo "    encoding: b64"
        echo "    content: $b64"
    } >> "$OUT"
}

cat > "$OUT" <<'HEADER'
#cloud-config
# =============================================================================
# Harvester cloud-init for the Coriolis Windows-worker BUILD HOST.
# Deploy this as the user-data of an openSUSE Leap 16.0 VM (nested virt ON).
# On first boot it installs KVM/libvirt, drops in the builder, and kicks off a
# one-shot service that produces /var/lib/coriolis-worker-build/output/
# coriolis-windows-worker.qcow2.
#
# GENERATED FILE — edit build/*.sh, windows/* or generate-cloud-init.sh instead.
# =============================================================================
hostname: coriolis-worker-builder
ssh_pwauth: true

package_update: true
packages:
  - qemu-kvm
  - libvirt
  - libvirt-client
  - virt-install
  - qemu-tools
  - xorriso
  - bsdtar
  - curl
  - jq
  - util-linux

write_files:
HEADER

emit_file /opt/coriolis-worker/build/config.env                     "$CONFIG_SRC"                                '0644'
# Secrets overlay: embed build/config.secret.env if you've created one, so the
# build host has the Harvester token for unattended auto-upload. Mode 0600.
# Skipped (upload simply won't run) if absent.
if [[ -f "$HERE/build/config.secret.env" ]]; then
    emit_file /opt/coriolis-worker/build/config.secret.env          "$HERE/build/config.secret.env"             '0600'
    echo "note: embedding build/config.secret.env (mode 0600) for unattended Harvester upload." >&2
fi
emit_file /opt/coriolis-worker/build/download-assets.sh             "$HERE/build/download-assets.sh"             '0755'
emit_file /opt/coriolis-worker/build/make-config-iso.sh             "$HERE/build/make-config-iso.sh"             '0755'
emit_file /opt/coriolis-worker/build/build-worker.sh                "$HERE/build/build-worker.sh"                '0755'
emit_file /opt/coriolis-worker/build/upload-to-harvester.sh         "$HERE/build/upload-to-harvester.sh"         '0755'
emit_file /etc/systemd/system/coriolis-build.service                "$HERE/build/coriolis-build.service"         '0644'
emit_file /opt/coriolis-worker/windows/autounattend.xml             "$HERE/windows/autounattend.xml"             '0644'
emit_file /opt/coriolis-worker/windows/configure-worker.ps1         "$HERE/windows/configure-worker.ps1"         '0644'
emit_file /opt/coriolis-worker/windows/cloudbase-init.conf          "$HERE/windows/cloudbase-init.conf"          '0644'
emit_file /opt/coriolis-worker/windows/cloudbase-init-unattend.conf "$HERE/windows/cloudbase-init-unattend.conf" '0644'

cat >> "$OUT" <<'FOOTER'

runcmd:
  - [ systemctl, enable, --now, libvirtd ]
  - [ bash, -c, "virsh net-autostart default 2>/dev/null; virsh net-start default 2>/dev/null || true" ]
  - [ systemctl, daemon-reload ]
  # Auto-start the build. Comment this out to build manually with
  #   sudo /opt/coriolis-worker/build/build-worker.sh
  - [ systemctl, enable, --now, coriolis-build.service ]

final_message: "Coriolis worker build host ready. Tail /var/log/coriolis-build.log for progress."
FOOTER

echo "Wrote $OUT"
