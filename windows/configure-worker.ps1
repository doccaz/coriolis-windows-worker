<#
  configure-worker.ps1 — runs ONCE at first logon inside the throwaway Windows
  installer VM (launched by FirstLogonCommands in autounattend.xml).

  It turns a vanilla Windows Server install into a Coriolis temporary migration
  worker and then syspreps + powers the VM off so the disk can be captured.

  Order of operations:
    1. Install the SUSE VMDP virtio storage/net drivers and make them
       boot-critical (so the captured image boots under Harvester/KubeVirt).
    2. Install + configure cloudbase-init (the agent Coriolis drives).
    3. Harden/enable WinRM over HTTPS with Basic auth (Coriolis transport).
    4. General template hygiene (UTC clock, RDP, firewall, keep Admin enabled).
    5. Sysprep /generalize /oobe /shutdown using cloudbase-init's Unattend.xml.

  Everything is idempotent and logged to C:\coriolis-build\configure-worker.log.
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference     = 'SilentlyContinue'
$Base   = 'C:\coriolis-build'
$LogDir = $Base
$Log    = Join-Path $LogDir 'configure-worker.log'

function Log($msg) {
    $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    Write-Host $line
    Add-Content -Path $Log -Value $line
}

# Surface failures in the log and (deliberately) leave the VM running so the
# build host's serial console shows what broke, instead of a silent shutdown.
trap {
    Log "FATAL: $($_.Exception.Message)"
    Log $_.ScriptStackTrace
    exit 1
}

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
Log '=== Coriolis Windows worker configuration started ==='

# Find a mounted CD/volume that contains a given relative file (drive letters
# are not stable across passes/reboots).
function Find-OnVolumes([string]$relPath) {
    foreach ($v in (Get-Volume | Where-Object DriveLetter)) {
        $p = "$($v.DriveLetter):\$relPath"
        if (Test-Path $p) { return $p }
    }
    return $null
}

# ---------------------------------------------------------------------------
# 1. virtio drivers (SUSE VMDP) + make them boot-critical
# ---------------------------------------------------------------------------
Log '--- Installing virtio drivers (SUSE VMDP) ---'

# Trust the SUSE driver-signing publisher BEFORE installing. The VMDP virtio
# drivers are signed by "SUSE LLC", not WHQL, so installing them on the present
# virtio devices makes PnP raise an interactive "install this device software?"
# trust prompt that stalls the unattended build forever. Pre-seeding the signer
# (and its chain) into LocalMachine\TrustedPublisher makes pnputil's /install
# completely silent. Extract the cert from the first signed VMDP catalog/binary.
try {
    $signed = Get-ChildItem "$Base\drivers" -Recurse -Include *.cat,*.sys -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($signed) {
        $cert = (Get-AuthenticodeSignature $signed.FullName).SignerCertificate
        if ($cert) {
            foreach ($storeName in 'TrustedPublisher','Root') {
                $store = New-Object System.Security.Cryptography.X509Certificates.X509Store($storeName, 'LocalMachine')
                $store.Open('ReadWrite'); $store.Add($cert); $store.Close()
            }
            Log "  trusted driver publisher '$($cert.Subject)' from $($signed.Name)"
        } else {
            Log "  WARNING: $($signed.Name) has no Authenticode signer; driver prompt may appear"
        }
    } else {
        Log '  WARNING: no signed .cat/.sys under drivers\; cannot pre-trust publisher'
    }
} catch { Log "  WARNING: could not pre-trust driver publisher: $($_.Exception.Message)" }

# The Linux builder pre-extracted every VMDP .inf into C:\coriolis-build\drivers.
# Install them all non-interactively; pnputil ignores INFs with no matching
# device but still stages them in the driver store for later virtio hardware.
$driverRoots = @()
if (Test-Path "$Base\drivers") { $driverRoots += "$Base\drivers" }
# Belt-and-suspenders: also sweep the raw VMDP ISO if it is mounted.
foreach ($v in (Get-Volume | Where-Object DriveLetter)) {
    $root = "$($v.DriveLetter):\"
    if (Test-Path (Join-Path $root 'VMDP*.exe')) { $driverRoots += $root }
}

$infCount = 0
foreach ($root in ($driverRoots | Select-Object -Unique)) {
    Log "pnputil scanning $root"
    Get-ChildItem -Path $root -Recurse -Filter *.inf -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            & pnputil.exe /add-driver $_.FullName /install | Out-Null
            $infCount++
        } catch { Log "  (skip $($_.Name): $($_.Exception.Message))" }
    }
}
Log "Installed/staged $infCount driver INF(s)."

# --- Make virtio storage boot-critical (prevent 0x7B on first virtio boot) ---
# SUSE VMDP does NOT use the Red Hat service names (viostor/vioscsi). Per the
# VMDP INFs the storage services are:
#     virtio-blk  -> 'vrtioblk' or 'virtio_blk'   (DEV_1001 / DEV_1042)
#     virtio-scsi -> 'vtioscsi'                   (DEV_1004 / DEV_1048)
# To avoid trusting a name, the builder attaches a virtio-blk AND a virtio-scsi
# scratch disk, so Windows binds the real driver here; we read the service that
# actually bound and pin the CriticalDeviceDatabase to it. The INF-sourced names
# are the fallback if a bus had no scratch device.
$scsiClass = '{4d36e97b-e325-11ce-bfc1-08002be10318}'  # SCSIAdapter device class
$cdb = 'HKLM:\SYSTEM\CurrentControlSet\Control\CriticalDeviceDatabase'
$blkIds  = @('PCI#VEN_1AF4&DEV_1001','PCI#VEN_1AF4&DEV_1042')  # legacy + modern
$scsiIds = @('PCI#VEN_1AF4&DEV_1004','PCI#VEN_1AF4&DEV_1048')

function Set-BootCritical([string]$svc, [string[]]$hwids) {
    $svcKey = "HKLM:\SYSTEM\CurrentControlSet\Services\$svc"
    if (Test-Path $svcKey) {
        Set-ItemProperty -Path $svcKey -Name Start -Value 0 -Type DWord   # 0 = boot
        Log "  pinned service '$svc' Start=0 (boot-critical)"
    } else {
        Log "  WARNING: service '$svc' not registered; CDDB entry added regardless"
    }
    foreach ($id in $hwids) {
        $k = Join-Path $cdb $id
        New-Item -Path $k -Force | Out-Null
        New-ItemProperty -Path $k -Name 'Service'   -Value $svc       -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $k -Name 'ClassGUID' -Value $scsiClass -PropertyType String -Force | Out-Null
    }
    Log "  CDDB $($hwids -join ', ') -> $svc"
}

# Let PnP bind the freshly-installed drivers to the scratch virtio disks.
& pnputil.exe /scan-devices 2>$null | Out-Null
Start-Sleep -Seconds 5

# 1) Authoritative: read the service from the live virtio storage devices.
$blkSvc = $null; $scsiSvc = $null
$present = Get-PnpDevice -Class SCSIAdapter -PresentOnly -ErrorAction SilentlyContinue |
           Where-Object { $_.InstanceId -match 'VEN_1AF4' -and $_.Service }
foreach ($d in $present) {
    if ($d.InstanceId -match 'DEV_1001|DEV_1042') { $blkSvc  = $d.Service }
    if ($d.InstanceId -match 'DEV_1004|DEV_1048') { $scsiSvc = $d.Service }
    Log "Discovered virtio storage $($d.InstanceId) -> service '$($d.Service)'"
}

# 2) Fallback to the names pinned from the VMDP INF sources.
if (-not $blkSvc) {
    foreach ($c in 'vrtioblk','virtio_blk') {
        if (Test-Path "HKLM:\SYSTEM\CurrentControlSet\Services\$c") { $blkSvc = $c; break }
    }
    if (-not $blkSvc) { $blkSvc = 'vrtioblk' }
    Log "virtio-blk service not discovered live; using pinned '$blkSvc'"
}
if (-not $scsiSvc) {
    $scsiSvc = 'vtioscsi'
    Log "virtio-scsi service not discovered live; using pinned '$scsiSvc'"
}

Set-BootCritical $blkSvc  $blkIds
Set-BootCritical $scsiSvc $scsiIds

# QEMU guest agent: install from the VMDP CD if a stand-alone MSI is shipped.
$qemuGaMsi = Find-OnVolumes 'qemu-ga-x86_64.msi'
if (-not $qemuGaMsi) { $qemuGaMsi = Find-OnVolumes 'guest-agent\qemu-ga-x86_64.msi' }
if ($qemuGaMsi) {
    Log "Installing QEMU guest agent: $qemuGaMsi"
    Start-Process msiexec.exe -ArgumentList "/i `"$qemuGaMsi`" /qn /norestart" -Wait
} else {
    Log 'QEMU guest agent MSI not found on media (drivers are sufficient for Coriolis).'
}

# ---------------------------------------------------------------------------
# 2. cloudbase-init
# ---------------------------------------------------------------------------
Log '--- Installing cloudbase-init ---'
$cbMsi = Find-OnVolumes 'toolkit\CloudbaseInitSetup_x64.msi'
if (-not $cbMsi) { $cbMsi = "$Base\CloudbaseInitSetup_x64.msi" }
if (-not (Test-Path $cbMsi)) { throw "cloudbase-init MSI not found (looked for $cbMsi)" }

$cbLog = Join-Path $LogDir 'cloudbase-init-msi.log'
Start-Process msiexec.exe -Wait -ArgumentList @(
    '/i', "`"$cbMsi`"", '/qn', '/norestart',
    'RUN_SERVICE_AS_LOCAL_SYSTEM=1',
    'LOGGINGSERIALPORTNAME=',
    '/L*v', "`"$cbLog`""
)

$cbDir   = 'C:\Program Files\Cloudbase Solutions\Cloudbase-Init'
$cbConf  = Join-Path $cbDir 'conf'
if (-not (Test-Path $cbConf)) { throw "cloudbase-init did not install (no $cbConf)" }

# Drop in the Coriolis-tuned config (metadata services + WinRM/user plugins).
Copy-Item "$Base\cloudbase-init.conf"          (Join-Path $cbConf 'cloudbase-init.conf')          -Force
Copy-Item "$Base\cloudbase-init-unattend.conf" (Join-Path $cbConf 'cloudbase-init-unattend.conf') -Force
Log 'cloudbase-init installed and configured.'

# ---------------------------------------------------------------------------
# 3. WinRM over HTTPS + Basic auth (Coriolis transport)
# ---------------------------------------------------------------------------
Log '--- Configuring WinRM ---'
# The HTTPS *listener* (host-specific self-signed cert) is (re)created on every
# boot by cloudbase-init's ConfigWinRMListenerPlugin, so it survives sysprep.
# The service-level settings below persist in the image.
Set-Service -Name WinRM -StartupType Automatic
Start-Service -Name WinRM
# The build VM's NIC is an unidentified/Public network and no HTTPS server cert
# exists yet (cloudbase-init's ConfigWinRMListenerPlugin creates the HTTPS
# listener on first boot). So DON'T force -transport:https here (it would fail
# with WSManFault for lack of a cert) and skip the network-profile check that
# makes winrm quickconfig refuse to run on a Public network.
try { Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private -ErrorAction SilentlyContinue } catch {}
Enable-PSRemoting -Force -SkipNetworkProfileCheck | Out-Null
& winrm.cmd set winrm/config/service/auth '@{Basic="true"}'        | Out-Null
& winrm.cmd set winrm/config/service '@{AllowUnencrypted="false"}' | Out-Null
& winrm.cmd set winrm/config/winrs '@{MaxMemoryPerShellMB="1024"}' | Out-Null

# Open 5986 (HTTPS-In) explicitly in case the bundled rule group is absent.
if (-not (Get-NetFirewallRule -DisplayName 'Windows Remote Management (HTTPS-In)' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName 'Windows Remote Management (HTTPS-In)' `
        -Direction Inbound -LocalPort 5986 -Protocol TCP -Action Allow | Out-Null
}
Log 'WinRM service hardened (Basic over HTTPS, 5986 open).'

# ---------------------------------------------------------------------------
# 4. Template hygiene
# ---------------------------------------------------------------------------
Log '--- Applying template hygiene ---'
# Keep BIOS/RTC in UTC (cloud images expect this).
New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation' `
    -Name RealTimeIsUniversal -Value 1 -PropertyType DWord -Force | Out-Null

# cloudbase-init's default user is "Admin"; Coriolis requires the built-in
# Administrator to stay ENABLED in the worker image.
& net user Administrator /active:yes | Out-Null

# Enable RDP (handy for debugging a stuck worker) and disable hibernation.
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0
Enable-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction SilentlyContinue
& powercfg.exe /hibernate off 2>$null

# Best-effort: stop disk reorder surprises by disabling the page-file reset, etc.
Log 'Template hygiene applied.'

# ---------------------------------------------------------------------------
# 5. Sysprep -> generalize -> shutdown (image is then captured by the host)
# ---------------------------------------------------------------------------
Log '--- Sysprep: generalize + shutdown ---'
$unattend = Join-Path $cbConf 'Unattend.xml'   # shipped by the cloudbase-init MSI
if (-not (Test-Path $unattend)) { throw "cloudbase-init Unattend.xml missing at $unattend" }

Log 'Configuration complete. Handing off to sysprep; VM will power off.'
# Invoke via the call operator so PowerShell quotes the (space-containing)
# unattend path as a single token. The previous Start-Process -ArgumentList
# array form embedded literal quotes that sysprep could not parse, so it just
# printed its USAGE banner and exited without generalizing.
& "$Env:windir\System32\Sysprep\Sysprep.exe" /generalize /oobe /shutdown "/unattend:$unattend"
