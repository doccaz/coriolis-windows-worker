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

# emit_file <dest-path-on-host> <local-source> <mode>
emit_file() {
    local dest="$1" src="$2" mode="$3"
    {
        echo "  - path: $dest"
        echo "    permissions: '$mode'"
        echo "    encoding: b64"
        echo "    content: $(base64 -w0 "$src")"
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
  - curl
  - jq
  - util-linux

write_files:
HEADER

emit_file /opt/coriolis-worker/build/config.env                     "$HERE/build/config.env"                     '0644'
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
