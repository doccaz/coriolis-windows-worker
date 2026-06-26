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

# Resolve an SSH public key to authorize for the 'builder' user, so `make logs`
# can log in over `virtctl ssh` non-interactively (no password prompt). Honour an
# explicit BUILD_SSH_PUBKEY, else auto-detect the operator's default key. Absent
# = key login disabled; the builder/builder password still works on the console.
PUBKEY=""
if [[ -n "${BUILD_SSH_PUBKEY:-}" ]]; then
    [[ -f "$BUILD_SSH_PUBKEY" ]] || { echo "ERROR: BUILD_SSH_PUBKEY not found: $BUILD_SSH_PUBKEY" >&2; exit 1; }
    PUBKEY="$(< "$BUILD_SSH_PUBKEY")"
else
    for cand in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub"; do
        [[ -f "$cand" ]] && { PUBKEY="$(< "$cand")"; echo "note: authorizing SSH key $cand for 'builder' (override with BUILD_SSH_PUBKEY)." >&2; break; }
    done
    [[ -z "$PUBKEY" ]] && echo "note: no SSH public key found — 'make logs' will need the builder/builder console password. Set BUILD_SSH_PUBKEY to enable key login." >&2
fi

cat > "$OUT" <<'HEADER'
#cloud-config
# =============================================================================
# Harvester cloud-init for the Coriolis Windows-worker BUILD HOST.
# Deploy this as the user-data of an openSUSE Leap 16.0 VM (nested virt ON).
# On first boot it installs KVM/libvirt, drops in the builder, and kicks off a
# one-shot service (running as the unprivileged 'builder' user) that produces
# /home/builder/coriolis-worker-build/output/coriolis-windows-worker.qcow2.
#
# GENERATED FILE — edit build/*.sh, windows/* or generate-cloud-init.sh instead.
# =============================================================================
hostname: coriolis-worker-builder
ssh_pwauth: true

# Unprivileged user the one-shot build service runs as. The build needs no root
# (system libvirt + /dev/kvm via group membership), so it owns its workdir under
# /home/builder — keeping the multi-GB assets/qcow2 and the log off the root
# partition and out of /var/lib /var/log.
users:
  - default
  - name: builder
    lock_passwd: false
    # 'builder' / change after first boot. Console/SSH access for watching the build.
    plain_text_passwd: builder
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
HEADER

# Authorize the resolved key (if any) for key-based `virtctl ssh` login.
if [[ -n "$PUBKEY" ]]; then
    {
        echo "    ssh_authorized_keys:"
        echo "      - $PUBKEY"
    } >> "$OUT"
fi

cat >> "$OUT" <<'HEADER'

# The Leap 16.0 Minimal-VM Cloud image ships with NO zypper repositories
# (/etc/zypp/repos.d is empty), so the package install below has nothing to pull
# from and cloud-init fails before the build can start. Seed the OSS + non-OSS
# repos here. cloud-init's zypper module runs in the config stage *before*
# package_update_upgrade_install, and the openSUSE Project signing key is already
# trusted in the image's rpm keyring, so gpgcheck passes without a prompt.
zypper:
  repos:
    - id: repo-oss
      name: openSUSE-Leap-16.0-OSS
      baseurl: https://download.opensuse.org/distribution/leap/16.0/repo/oss/
      enabled: 1
      autorefresh: 1
      gpgcheck: 1
    - id: repo-non-oss
      name: openSUSE-Leap-16.0-NON-OSS
      baseurl: https://download.opensuse.org/distribution/leap/16.0/repo/non-oss/
      enabled: 1
      autorefresh: 1
      gpgcheck: 1

package_update: true
packages:
  # The Leap 16.0 Minimal-VM Cloud image ships the stripped 'kernel-default-base'
  # flavor, which omits the KVM modules (kvm_amd/kvm_intel). Without them the
  # guest can't create /dev/kvm even though the host surfaces vmx/svm, so the
  # nested build can't run. Pull the full 'kernel-default' (carries the kvm
  # modules); the power_state reboot below boots into it so /dev/kvm appears.
  - kernel-default
  - qemu-kvm
  - libvirt
  - libvirt-client
  # libvirt's qemu:///system access driver is polkit. Without polkit installed,
  # root connects (uid 0 bypasses it) but the unprivileged 'builder' gets a
  # D-Bus "ServiceUnknown: not activatable" and the build can't reach libvirt —
  # even though it's in the 'libvirt' group. polkit ships the 50-libvirt.rules
  # that actually grants that group, so it must be present on this minimal image.
  - polkit
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
  # Let 'builder' drive system libvirt + KVM without root, and own the toolkit
  # so it can read the 0600 config.secret.env. (Groups exist now that the
  # libvirt/qemu packages are installed.)
  - [ bash, -c, "usermod -aG libvirt,kvm builder" ]
  - [ chown, -R, "builder:builder", /opt/coriolis-worker ]
  - [ systemctl, daemon-reload ]
  # Enable (don't --now) the build: the running kernel is still the stripped
  # 'kernel-default-base' with no /dev/kvm, so starting now would just fail fast.
  # power_state reboots into the freshly-installed full kernel-default below, and
  # the service (WantedBy=multi-user.target) starts on that boot with /dev/kvm
  # present. Comment this out to build manually:
  #   sudo -u builder /opt/coriolis-worker/build/build-worker.sh
  - [ systemctl, enable, coriolis-build.service ]

# Reboot once cloud-init finishes so the box comes up on the full kernel-default
# (with kvm_amd/kvm_intel) instead of kernel-default-base. The enabled
# coriolis-build.service then runs on the KVM-capable kernel.
power_state:
  mode: reboot
  message: "Rebooting into full kernel-default so /dev/kvm is available for the nested build"
  condition: true

final_message: "Coriolis worker build host rebooting into kernel-default; the build starts on next boot. Tail /home/builder/coriolis-worker-build/coriolis-build.log for progress."
FOOTER

echo "Wrote $OUT"
