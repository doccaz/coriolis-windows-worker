#!/usr/bin/env bash
# build-worker.sh — end-to-end build of the Coriolis Windows migration worker
# image, run on the openSUSE Leap build host (bare-metal or a Harvester VM with
# nested virtualization).
#
#   1. download assets (Windows ISO, VMDP ISO, cloudbase-init MSI)
#   2. build the config CD (answer file + toolkit + virtio drivers)
#   3. boot a throwaway Windows VM that installs + configures itself unattended
#   4. wait for sysprep to power it off
#   5. compress/capture the disk as the finished worker qcow2
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.env
source "$HERE/config.env"

# Mirror everything to a persistent log under WORKDIR (user-writable, off the
# root partition) so manual runs and the systemd service share one tail-able
# file without needing /var/log or sudo. The journal still captures it too.
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

log() { echo -e "\n=== $* ===" ; }

# --- preflight -------------------------------------------------------------
# Runs as a regular user — no sudo. All it needs is access to the system
# libvirt daemon (be in the 'libvirt' group) and /dev/kvm (the 'kvm' group).
#
# Check EVERY tool the pipeline uses up front — download (sha256sum), config ISO
# (genisoimage/xorrisofs), build (qemu-img/virsh/bsdtar) and the optional
# Harvester upload (jq) — so a missing one fails now, not 20 min into the build.
for bin in qemu-img virsh curl bsdtar sha256sum; do
    command -v "$bin" >/dev/null || { echo "Missing required tool: $bin" >&2; exit 1; }
done
# make-config-iso.sh needs one of these to author the config CD.
command -v genisoimage >/dev/null || command -v xorrisofs >/dev/null || {
    echo "Missing required tool: genisoimage or xorrisofs (install xorriso)." >&2; exit 1; }
# jq is only needed for the optional Harvester upload at the end.
if [[ "${UPLOAD_TO_HARVESTER:-false}" == "true" ]]; then
    command -v jq >/dev/null || { echo "Missing required tool: jq (needed for UPLOAD_TO_HARVESTER)" >&2; exit 1; }
fi
[[ -e /dev/kvm ]] || { echo "/dev/kvm not present — enable nested virtualization on the Harvester node." >&2; exit 1; }
# Confirm we can drive system libvirt without root. LIBVIRT_DEFAULT_URI is
# exported from config.env (qemu:///system); if this fails, add yourself to the
# 'libvirt' group: sudo usermod -aG libvirt "$USER" && newgrp libvirt
virsh list --all >/dev/null 2>&1 || {
    echo "Cannot reach libvirt at ${LIBVIRT_DEFAULT_URI} as $(id -un)." >&2
    echo "Add yourself to the 'libvirt' group: sudo usermod -aG libvirt \"\$USER\" && newgrp libvirt" >&2
    exit 1
}

mkdir -p "$ASSETS_DIR" "$OUTPUT_DIR"

# qemu:///system runs QEMU as the 'qemu' user (uid 107), not as us. WORKDIR
# lives under $HOME, which is mode 0700, so that user can't even traverse into
# it to open the disk images — libvirt aborts with "Cannot access storage file
# ... (as uid:107, gid:107): Permission denied". Grant search (o+x) on every
# directory on the path so qemu can reach the files. The images themselves stay
# 0644 (world-readable), so o+x on the path is enough and we never expose
# directory *listings* to other local users.
#
# Walk each ancestor up to '/' rather than assuming WORKDIR is exactly one level
# below $HOME — a custom WORKDIR (e.g. /mnt/big/builds/...) can nest arbitrarily,
# and any single un-traversable component on the chain blocks qemu. chmod fails
# silently on components we don't own (already o+x for system dirs anyway).
grant_traverse() {
    local d; d="$(cd "$1" && pwd)" || return 0   # canonicalize; skip if gone
    while [[ "$d" != "/" && -n "$d" ]]; do
        chmod o+x "$d" 2>/dev/null || true
        d="$(dirname "$d")"
    done
}
for d in "$WORKDIR" "$ASSETS_DIR" "$OUTPUT_DIR"; do
    grant_traverse "$d"
done

# --- 1. assets -------------------------------------------------------------
log "Step 1/5: downloading assets"
bash "$HERE/download-assets.sh"

# --- 2. config CD ----------------------------------------------------------
log "Step 2/5: building config CD"
bash "$HERE/make-config-iso.sh"

WIN_ISO="$ASSETS_DIR/windows-server-eval.iso"
VMDP_ISO="$ASSETS_DIR/vmdp.iso"
CONFIG_ISO="$ASSETS_DIR/config.iso"
WORKER_DISK="$ASSETS_DIR/worker.qcow2"
SCRATCH_BLK="$ASSETS_DIR/scratch-blk.qcow2"
SCRATCH_SCSI="$ASSETS_DIR/scratch-scsi.qcow2"
OUTPUT="$OUTPUT_DIR/$WORKER_IMAGE_NAME"

# --- 3. throwaway installer VM --------------------------------------------
log "Step 3/5: creating $BUILD_VM_NAME and starting the unattended install"

# The VM uses qemu user-mode networking (<interface type='user'>), so it needs
# no libvirt-managed network — nothing to net-start here.

# Clean any stale domain/disk from a previous run.
virsh destroy "$BUILD_VM_NAME" 2>/dev/null || true
virsh undefine "$BUILD_VM_NAME" --nvram 2>/dev/null || true
rm -f "$WORKER_DISK" "$SCRATCH_BLK" "$SCRATCH_SCSI"
qemu-img create -f qcow2 "$WORKER_DISK" "$WORKER_DISK_SIZE"
# Throwaway disks that make the virtio-blk + virtio-scsi devices present during
# the build, so Windows binds the real VMDP driver and we can pin its service
# name into the CriticalDeviceDatabase (prevents 0x7B on first virtio boot).
qemu-img create -f qcow2 "$SCRATCH_BLK"  1G
qemu-img create -f qcow2 "$SCRATCH_SCSI" 1G

# Generate the domain. We hand-roll the XML (instead of letting virt-install
# drive the install) so the three CDs stay attached for the whole build and the
# guest's own ACPI reboots/sysprep-shutdown are handled deterministically:
#   on_reboot=restart  (Windows setup reboots several times)
#   on_poweroff=destroy (sysprep /shutdown ends the build)
DOMAIN_XML="$(mktemp)"
cat > "$DOMAIN_XML" <<XML
<domain type='kvm'>
  <name>${BUILD_VM_NAME}</name>
  <memory unit='MiB'>${BUILD_VM_RAM_MB}</memory>
  <vcpu>${BUILD_VM_VCPUS}</vcpu>
  <os>
    <type arch='x86_64' machine='q35'>hvm</type>
    <bootmenu enable='no'/>
  </os>
  <features><acpi/><apic/></features>
  <cpu mode='host-passthrough' check='none'/>
  <clock offset='utc'>
    <timer name='rtc' tickpolicy='catchup'/>
    <timer name='pit' tickpolicy='delay'/>
    <timer name='hpet' present='no'/>
  </clock>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>destroy</on_crash>
  <devices>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2' cache='none' discard='unmap'/>
      <source file='${WORKER_DISK}'/>
      <target dev='sda' bus='sata'/>
      <boot order='2'/>
    </disk>
    <!-- relabel='no' on the read-only CDROMs: by default libvirt's DAC security
         driver chowns every disk source to qemu:qemu on start and restores it on
         a managed stop. But this domain self-destroys via on_poweroff=destroy
         (sysprep /shutdown), which skips libvirt's restore — so the ISOs would be
         left owned by qemu and a later unprivileged run couldn't overwrite them
         (config.iso regen, asset re-download). These ISOs are 0644 and the path
         has o+x (grant_traverse above), so qemu reads them in place; tell libvirt
         to leave their ownership alone. (The writable disks are recreated with
         `rm -f` each run, so dynamic ownership on them is harmless.) -->
    <disk type='file' device='cdrom'>
      <driver name='qemu' type='raw'/>
      <source file='${WIN_ISO}'/>
      <target dev='sdb' bus='sata'/>
      <boot order='1'/>
      <readonly/>
      <seclabel model='dac' relabel='no'/>
    </disk>
    <disk type='file' device='cdrom'>
      <driver name='qemu' type='raw'/>
      <source file='${CONFIG_ISO}'/>
      <target dev='sdc' bus='sata'/>
      <readonly/>
      <seclabel model='dac' relabel='no'/>
    </disk>
    <disk type='file' device='cdrom'>
      <driver name='qemu' type='raw'/>
      <source file='${VMDP_ISO}'/>
      <target dev='sdd' bus='sata'/>
      <readonly/>
      <seclabel model='dac' relabel='no'/>
    </disk>
    <!-- Scratch disks: make virtio-blk + virtio-scsi devices present so the
         VMDP driver binds and its real service name can be pinned. Not booted
         (no <boot> element) and discarded after capture. -->
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='${SCRATCH_BLK}'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='${SCRATCH_SCSI}'/>
      <target dev='sde' bus='scsi'/>
    </disk>
    <controller type='scsi' model='virtio-scsi' index='0'/>
    <controller type='sata' index='0'/>
    <interface type='user'>
      <model type='e1000e'/>
    </interface>
    <input type='tablet' bus='usb'/>
    <graphics type='vnc' port='-1' listen='0.0.0.0'/>
    <video><model type='vga'/></video>
    <serial type='pty'><target port='0'/></serial>
    <console type='pty'><target type='serial' port='0'/></console>
    <channel type='unix'>
      <target type='virtio' name='org.qemu.guest_agent.0'/>
    </channel>
  </devices>
</domain>
XML

# Transient domain: when sysprep powers it off it disappears, leaving only the
# qcow2 we want.
virsh create "$DOMAIN_XML"
rm -f "$DOMAIN_XML"
echo "VNC console: connect with 'virsh vncdisplay $BUILD_VM_NAME'"

# Defeat the "Press any key to boot from CD or DVD" prompt: tap ENTER for a
# while right after power-on (keycode 28 = KEY_ENTER on the linux codeset).
log "Auto-pressing ENTER for ${CD_BOOT_KEYSPAM_SECONDS}s so Windows boots from CD"
end=$(( SECONDS + CD_BOOT_KEYSPAM_SECONDS ))
while (( SECONDS < end )); do
    virsh send-key "$BUILD_VM_NAME" --codeset linux 28 >/dev/null 2>&1 || true
    sleep 4
done

# --- 4. wait for the build to finish (sysprep -> power off) ----------------
log "Step 4/5: waiting up to ${BUILD_TIMEOUT_MINUTES} min for install + sysprep"
deadline=$(( $(date +%s) + BUILD_TIMEOUT_MINUTES * 60 ))
while true; do
    # NB: for a missing (already-destroyed transient) domain, virsh prints the
    # error to stderr but still emits a blank line on stdout, so a naive
    # `|| echo gone` yields $'\ngone' which never equals "gone". Capture, then
    # strip ALL whitespace so "shut off" -> "shutoff" and empty/missing -> gone.
    if state="$(virsh domstate "$BUILD_VM_NAME" 2>/dev/null)"; then
        state="${state//[$' \t\r\n']/}"
    else
        state="gone"
    fi
    [[ -z "$state" ]] && state="gone"
    if [[ "$state" == "gone" || "$state" == "shutoff" ]]; then
        echo "Installer VM powered off — build phase complete."
        break
    fi
    if (( $(date +%s) > deadline )); then
        echo "ERROR: timed out after ${BUILD_TIMEOUT_MINUTES} min (state=$state)." >&2
        echo "Inspect the VM via VNC; it is left running for debugging." >&2
        exit 1
    fi
    sleep 20
done
virsh destroy "$BUILD_VM_NAME" 2>/dev/null || true

# --- 5. capture ------------------------------------------------------------
log "Step 5/6: capturing + compressing the worker image"
# Compress and drop the backing/CD context into a clean, sparse qcow2.
qemu-img convert -p -c -O qcow2 "$WORKER_DISK" "$OUTPUT"
qemu-img info "$OUTPUT"
rm -f "$SCRATCH_BLK" "$SCRATCH_SCSI"   # throwaway driver-binding disks

# --- 6. optional: register the image in Harvester --------------------------
if [[ "${UPLOAD_TO_HARVESTER:-false}" == "true" ]]; then
    log "Step 6/6: uploading the image into Harvester"
    bash "$HERE/upload-to-harvester.sh" "$OUTPUT"
else
    log "Step 6/6: skipped Harvester upload (set UPLOAD_TO_HARVESTER=true to enable)"
fi

echo
echo "============================================================"
echo " Coriolis Windows worker image ready:"
echo "   $OUTPUT"
echo
if [[ "${UPLOAD_TO_HARVESTER:-false}" == "true" ]]; then
    echo " Registered in Harvester as VM image:"
    echo "   $HARVESTER_NAMESPACE/$HARVESTER_IMAGE_NAME"
else
    echo " Next: register it as a Harvester VM image, e.g."
    echo "   - set UPLOAD_TO_HARVESTER=true (+ HARVESTER_SERVER/TOKEN), or"
    echo "   - Images > Create > Upload in the UI."
fi
echo " Then point your Coriolis Harvester/KubeVirt endpoint's"
echo " 'temporary worker image' at it (boot bus virtio-scsi/virtio)."
echo "============================================================"
