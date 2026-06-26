# Coriolis Windows migration worker — automated builder

Automates building the **Coriolis temporary Windows migration worker** image
(per [cloudbase.it/coriolis-temporary-migration-worker](https://cloudbase.it/coriolis-temporary-migration-worker/))
as a `qcow2` you can register in Harvester and point Coriolis at.

The whole thing is driven from an **openSUSE Leap 16.0** VM running inside
Harvester: cloud-init turns that VM into a build host, which then boots a
throwaway Windows Server VM that installs and configures *itself* unattended,
syspreps, and powers off. The build host captures the resulting disk.

```
Harvester node (nested virt ON)
└─ Leap 16.0 build-host VM  ← cloud-init/user-data.yaml
   └─ (KVM) throwaway Windows VM
        ├─ Windows Server eval ISO        ──┐ unattended install
        ├─ config.iso (autounattend + toolkit + virtio .inf)
        └─ VMDP ISO (qemu-ga / extra drivers)
        ⇒ installs VMDP virtio drivers (boot-critical)
        ⇒ installs + configures cloudbase-init
        ⇒ hardens WinRM (Basic over HTTPS :5986)
        ⇒ keeps built-in Administrator enabled
        ⇒ sysprep /generalize /oobe /shutdown
   ⇒ capture → output/coriolis-windows-worker.qcow2
```

## What the worker image ends up with

| Requirement (Cloudbase doc)            | How it's satisfied                                              |
|----------------------------------------|----------------------------------------------------------------|
| English-only Windows Server            | `autounattend.xml` forces `en-US` everywhere                   |
| virtio drivers / guest agent           | SUSE **VMDP** drivers via `pnputil` + `qemu-ga`; virtio-blk/virtio-scsi storage forced boot-critical |
| cloudbase-init installed & sysprepped  | MSI install + Coriolis-tuned `cloudbase-init.conf` + sysprep with its `Unattend.xml` |
| `Admin` account not disabled           | cloudbase-init default user `Admin`; built-in `Administrator` re-enabled |
| WinRM HTTPS reachable                  | Basic auth baked in; HTTPS listener + self-signed cert created per-boot by cloudbase-init |
| Boots on the target (Harvester/KubeVirt) | virtio-blk + virtio-scsi made boot-critical; the **actual** VMDP service name (`vrtioblk`/`virtio_blk`/`vtioscsi`) is discovered from live scratch disks and pinned into the CriticalDeviceDatabase |

## Files

```
windows-worker/
├── cloud-init/user-data.yaml         # GENERATED self-contained Harvester cloud-init
├── generate-cloud-init.sh            # regenerates the above from the files below
├── harvester/leap-image.yaml         # VMImage for the Leap build host (applied first)
├── harvester/leap-build-host.yaml    # PVC + VirtualMachine for the build host
├── harvester/apply-with-storageclass.sh  # resolves the image's real storage class, then applies
├── harvester/worker-vm.yaml          # smoke-test VM: boot the built image on virtio
├── build/
│   ├── config.env.example            # all tunables (URLs+checksums, sizes, image index)
│   ├── config.secret.env.example     # secrets template (Harvester token, build password)
│   ├── download-assets.sh            # fetch Windows ISO + VMDP ISO + cloudbase-init MSI (+ SHA256 verify)
│   ├── make-config-iso.sh            # build config.iso (answer file + toolkit + drivers)
│   ├── build-worker.sh               # orchestrate the throwaway VM → capture image
│   ├── upload-to-harvester.sh        # register the qcow2 in Harvester via the REST API
│   └── coriolis-build.service        # one-shot systemd unit that runs the build on boot
└── windows/
    ├── autounattend.xml              # unattended Windows Server install
    ├── configure-worker.ps1          # in-guest: drivers, cloudbase-init, WinRM, sysprep
    ├── cloudbase-init.conf           # main cloudbase-init config
    └── cloudbase-init-unattend.conf  # sysprep specialize-pass config
```

`windows/` and `build/` are the source of truth. `generate-cloud-init.sh`
embeds them (base64) into `cloud-init/user-data.yaml` — re-run it after editing.

## Run it on Harvester (fully automated)

> There are **two ways to build the same image** — this one (on Harvester) and
> [the local libvirt build](#run-it-on-any-libvirt-host-no-harvester) below.
> **Pick one; you don't need both.**

> **Shortcut:** `make help` lists every target. The flow below is
> `make config` → edit `build/config.env` → `make build-harvester` → `make logs`.
> The raw commands are kept here for reference.

```bash
cd windows-worker

# 0. Set up your config. The real build/config.env is git-ignored (it holds the
#    Harvester token). Copy the template and fill in your values:
cp build/config.env.example build/config.env   # or: make config
$EDITOR build/config.env        # set HARVESTER_SERVER/TOKEN, UPLOAD_TO_HARVESTER, etc.

# 1. Generate the cloud-init. It embeds build/config.env if present, otherwise
#    falls back to config.env.example (valid, but Harvester upload disabled).
#    Re-run after editing anything under build/ or windows/.
./generate-cloud-init.sh

# 2. Create the cloud-init secret + apply the build-host VM.
#    Apply the Leap image FIRST, then let the helper resolve the per-image
#    storage class (Harvester auto-names it lh-<uuid>, NOT longhorn-<image name>)
#    and substitute it before applying the PVC + VM. `make build-harvester`
#    does all of this for you.
kubectl -n default create secret generic coriolis-builder-cloudinit \
  --from-file=userdata=cloud-init/user-data.yaml \
  --from-literal=networkdata=''
kubectl apply -f harvester/leap-image.yaml
./harvester/apply-with-storageclass.sh default opensuse-leap-16-cloud \
  harvester/leap-build-host.yaml

# 3. Watch the build (≈ 30–90 min depending on download speed + nested-virt perf)
#    `make logs` SSHes in (via `virtctl ssh`, tunnelled through the KubeVirt API —
#    no route to the VM needed) and tails the log for you. It authorizes your
#    ~/.ssh/id_ed25519.pub or id_rsa.pub (override with BUILD_SSH_PUBKEY) at
#    cloud-init time. No key? `make console` logs in as builder/builder, then:
tail -f ~/coriolis-worker-build/coriolis-build.log
```

When it finishes, the image is at
`/home/builder/coriolis-worker-build/output/coriolis-windows-worker.qcow2` on the
build host.

### Auto-register the image in Harvester

Put the non-secret bits in `build/config.env` and the token in
`build/config.secret.env` (or pass any as environment overrides) and the build's
final step uploads the qcow2 straight into Harvester as a `VirtualMachineImage`
— no manual download/upload:

```bash
# build/config.env
UPLOAD_TO_HARVESTER=true
HARVESTER_SERVER=https://harvester.example.com   # the UI/API VIP (:443, not :6443)
# build/config.secret.env
HARVESTER_TOKEN=token-xxxxx:yyyyyyyyyyyyyyyy      # UI > Account & API Keys > Create API Key
# optional: HARVESTER_NAMESPACE, HARVESTER_IMAGE_NAME, HARVESTER_IMAGE_DISPLAY
```

It uses the Harvester (Steve) REST API: it `POST`s a `sourceType: upload`
`VirtualMachineImage`, streams the file to `?action=upload&size=<bytes>` as a
multipart `chunk`, and polls `.status.progress` to 100%. Run it standalone too:

```bash
# The default image lives under your home (~/coriolis-worker-build), so no sudo
# is needed to read it. Pass the path explicitly or let it default to
# $OUTPUT_DIR/$WORKER_IMAGE_NAME.
UPLOAD_TO_HARVESTER=true HARVESTER_SERVER=... HARVESTER_TOKEN=... \
  ./build/upload-to-harvester.sh ~/coriolis-worker-build/output/coriolis-windows-worker.qcow2
```

If you leave `UPLOAD_TO_HARVESTER=false`, just copy the image off (e.g. `scp`)
and register it manually (Images → Create → Upload).

> **Nested virtualization is required** on the Harvester node — see the header
> of `harvester/leap-build-host.yaml`. Without `/dev/kvm` the build still works
> but Windows setup runs under slow TCG emulation.

## Run it on any libvirt host (no Harvester)

The build is plain libvirt/KVM against the **system** libvirt (`qemu:///system`)
and is designed to run **without root** — you just need to be in the `libvirt`
and `kvm` groups. (`build-worker.sh` hand-rolls the domain XML and drives it with
`virsh`, so `virt-install` is not required.) Install the tools its preflight
checks for — `qemu-img`, `virsh`, `curl`, `bsdtar`, plus `xorriso`/`genisoimage`
and `jq`. `WORKDIR` defaults to `~/coriolis-worker-build` (user-writable, off the
root partition); override it to point at any roomy filesystem you can write:

```bash
# openSUSE Leap/SLES
sudo zypper install qemu-kvm libvirt libvirt-client qemu-tools \
     xorriso bsdtar curl jq
sudo usermod -aG libvirt,kvm "$USER" && newgrp libvirt   # one-time

# Shortcut: `make build-local` runs build-worker.sh for you.
WINDOWS_SRC_DIR="$PWD/windows" \
  ./build/build-worker.sh                # assets, image and log land under ~/coriolis-worker-build
```

> Everything (assets, the captured qcow2, the build log) lives under `WORKDIR`,
> so the build needs no root and never touches `/var/lib` or `/var/log`. Set
> `WORKDIR=/some/other/path` to relocate it.

## Smoke-test the image boots (before handing it to Coriolis)

`harvester/worker-vm.yaml` boots the built image in an isolated
`coriolis-worker-test` namespace so you can confirm it comes up on virtio.
It is *not* the worker Coriolis runs — just a "does it boot?" check.

```bash
# 1. Upload the image into the test namespace under the name the manifest expects.
#    The default image lives under ~/coriolis-worker-build, so no sudo is needed.
UPLOAD_TO_HARVESTER=true \
HARVESTER_NAMESPACE=coriolis-worker-test \
HARVESTER_IMAGE_NAME=coriolis-windows-worker \
HARVESTER_SERVER=https://192.168.86.250 HARVESTER_TOKEN=... \
  ./build/upload-to-harvester.sh ~/coriolis-worker-build/output/coriolis-windows-worker.qcow2

# 2. Boot it and watch. `make smoke-test` resolves the image's storage class and
#    applies the manifest for you; the raw equivalent is:
./harvester/apply-with-storageclass.sh coriolis-worker-test coriolis-windows-worker \
  harvester/worker-vm.yaml
kubectl -n coriolis-worker-test get vmi coriolis-windows-worker -w
virtctl vnc -n coriolis-worker-test coriolis-windows-worker   # eyeball the console

# 3. Tear down
kubectl delete ns coriolis-worker-test
```

> Validated against this lab's Harvester **v1.8.0** (192.168.86.250): the
> manifest passes server-side admission, and the image→clone-PVC→virtio-boot→
> pod-network path was confirmed end-to-end with a throwaway VM (since removed).
> Harvester auto-names the per-image storage class `lh-<uuid>` (read from the
> image's `.status.storageClassName`), **not** `longhorn-<image name>` — the
> manifests carry an `__IMAGE_STORAGECLASS__` placeholder that
> `apply-with-storageclass.sh` resolves at apply time.

## Point Coriolis at the image

1. Register `coriolis-windows-worker.qcow2` as a Harvester image. Use a
   **virtio-scsi** (or virtio-blk) boot bus — both are covered.
2. In your Coriolis Harvester/KubeVirt endpoint, set the temporary worker image
   to this image. Coriolis boots it during migration, cloudbase-init injects the
   admin password + sets up the WinRM HTTPS listener, and Coriolis connects on
   `:5986` with Basic auth to perform the Windows OS morphing / driver injection.

## Configuration

Two files under `build/`, both created by copying their `.example` and both
git-ignored (override any value via the environment too):

- **`config.env`** — non-secret tunables. Safe to share. Holds the asset URLs and
  optional `*_SHA256` checksums, VM sizing, image index, timeouts, and the
  Harvester target (server/namespace/image name).
- **`config.secret.env`** — secrets only: `HARVESTER_TOKEN` and
  `BUILD_ADMIN_PASSWORD`. `config.env` sources it automatically if present, and
  `generate-cloud-init.sh` embeds it (mode `0600`) so unattended Harvester
  upload works on the build host. If you skip it, those default to empty/throwaway
  and the Harvester upload is simply not attempted.

Key tunables in `config.env`:

- `WIN_IMAGE_INDEX` — edition in the eval ISO (default `2` = Standard Desktop
  Experience; `1` = Standard Core for a smaller worker).
- `WIN_ISO_SHA256` / `VIRTIO_VMDP_SHA256` / `CLOUDBASE_INIT_SHA256` — set to
  verify downloads; blank skips the check (with a warning).
- `BUILD_VM_RAM_MB`, `BUILD_VM_VCPUS`, `WORKER_DISK_SIZE`, timeouts, URLs.

## Notes & caveats

- **VMDP silent install**: the SUSE VMDP installer is GUI-oriented, so the
  builder installs its drivers non-interactively with `pnputil` (extracted from
  the ISO on the Linux side) rather than driving `setup.exe`. If a stand-alone
  `qemu-ga-*.msi` is present on the ISO it's installed too.
- **Boot-critical virtio (0x7B avoidance)**: VMDP does *not* use Red Hat's
  `viostor`/`vioscsi` service names — per its INFs they are `vrtioblk` (or
  `virtio_blk`) for virtio-blk and `vtioscsi` for virtio-scsi. The build VM
  therefore attaches a virtio-blk **and** a virtio-scsi scratch disk so Windows
  binds the real driver; `configure-worker.ps1` reads the bound service name
  back from the live device (`Get-PnpDevice`) and pins it (plus the legacy +
  modern PCI IDs) into the CriticalDeviceDatabase, with the INF-sourced names as
  a fallback. This is what lets the SATA-installed image boot on virtio at the
  destination regardless of whether it's attached as virtio-blk or virtio-scsi.
- **"Press any key to boot from CD"**: defeated by `virsh send-key` tapping
  ENTER for `CD_BOOT_KEYSPAM_SECONDS` after power-on.
- **Windows Updates** are *not* applied by default (they can add an hour+).
  The Cloudbase doc recommends them; add a `wuauclt`/`PSWindowsUpdate` step in
  `configure-worker.ps1` before the sysprep call if you need them.
- The build VM is **transient** — when sysprep powers it off it disappears,
  leaving only the captured qcow2.
