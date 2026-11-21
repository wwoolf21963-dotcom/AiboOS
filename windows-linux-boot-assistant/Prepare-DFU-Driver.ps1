<#
AiboOS Windows iPhone DFU WinUSB driver preparation.
Installs a driver for EXACTLY ONE PRESENT Apple DFU VID 05AC PID 1227 device
only after the user explicitly approves the GUI action and Windows UAC.
No checkm8, Pongo payload upload, phone erase or iOS replacement.
The helper is wdi-simple, built from pinned pbatard/libwdi upstream source.
#>
[CmdletBinding()]
param([switch]$SelfTest, [switch]$Elevated)
$ErrorActionPreference = "Stop"
$DfuId = 'VID_05AC&PID_1227'
$Tool = Join-Path $PSScriptRoot "AiboOS-DFU-Driver-Tool.exe"
$Root = Join-Path $env:LOCALAPPDATA "AiboOS"
$LogFile = Join-Path $Root "Driver-Setup-Last-Run.txt"
$BackupRoot = Join-Path ([Environment]::GetFolderPath('UserProfile')) "Downloads\AiboOS-Apple-Driver-Backup"

function Is-Admin {
  $current = [Security.Principal.WindowsIdentity]::GetCurrent()
  return [Security.Principal.WindowsPrincipal]::new($current).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Log([string]$message) {
  $line = "$(Get-Date -Format 'HH:mm:ss') $message"
  Write-Host $line
  Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
}
function PresentDfu {
  return @(Get-CimInstance -ClassName Win32_PnPEntity |
    Where-Object {
      $_.PNPDeviceID -match '(^|\\)VID_05AC&PID_1227($|[&\\])' -and $_.Present -ne $false
    })
}
function DriverRecord([string]$id) {
  return @(Get-CimInstance -ClassName Win32_PnPSignedDriver |
    Where-Object { $_.DeviceID -eq $id })
}
function DriverReady([string]$service) {
  return $service -match '^(WinUSB|libusbK|libusb0)$'
}
function Main {
  if ($SelfTest) {
    if (-not ('USB\VID_05AC&PID_1227\EXAMPLE' -match '(^|\\)VID_05AC&PID_1227($|[&\\])')) { throw 'DFU regex mismatch' }
    if ('USB\VID_05AC&PID_12A8\EXAMPLE' -match '(^|\\)VID_05AC&PID_1227($|[&\\])') { throw 'Wrong USB mode accepted' }
    if (-not (DriverReady "WinUSB")) { throw 'WinUSB recognition failed' }
    if (DriverReady "usbaapl64") { throw 'Apple driver wrongly identified as WinUSB' }
    Write-Host '[PASS] Offline DFU-driver safety checks. No drivers accessed or installed.'
    return 0
  }
  New-Item -ItemType Directory -Path $Root -Force | Out-Null
  Set-Content -LiteralPath $LogFile -Value "AiboOS DFU driver operation. No phone firmware/storage operations." -Encoding UTF8
  $devices = @(PresentDfu)
  if ($devices.Count -ne 1) {
    Log "[STOP] Expected one connected Apple DFU 05AC:1227 device, found $($devices.Count)."
    return 10
  }
  $device = $devices[0]
  $service = [string]$device.Service
  Log "[CHECK] One Apple DFU mode device. Windows driver service: $service"
  if (DriverReady $service) {
    Log "[READY] Compatible WinUSB/libusb driver already bound. No change required."
    return 0
  }
  $drivers = @(DriverRecord ([string]$device.PNPDeviceID))
  if ($drivers.Count -gt 1) {
    Log "[STOP] Ambiguous DFU driver records. No changes."
    return 11
  }
  $provider = if ($drivers.Count -eq 1) { [string]$drivers[0].DriverProviderName } else { "" }
  $inf = if ($drivers.Count -eq 1) { [string]$drivers[0].InfName } else { "" }
  Log "[CHECK] Current provider: $provider. INF: $inf"
  if (-not (Test-Path -LiteralPath $Tool -PathType Leaf)) {
    Log "[STOP] Bundled driver installation helper missing. Extract the entire ZIP."
    return 12
  }
  if (-not (Is-Admin)) {
    Log "[APPROVAL] Requesting Windows administrator approval for backup and DFU driver binding."
    try {
      $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Elevated' -f $PSCommandPath
      $child = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -Verb RunAs -PassThru -Wait -ErrorAction Stop
      return $child.ExitCode
    } catch {
      Log '[CANCELLED] Windows approval denied. No drivers changed.'
      return 13
    }
  }

  # The elevated process re-checks the hardware immediately before changes.
  $devices = @(PresentDfu)
  if ($devices.Count -ne 1) {
    Log '[STOP] DFU disconnected or multiple devices now present. No changes.'
    return 14
  }
  $device = $devices[0]
  if (DriverReady ([string]$device.Service)) {
    Log '[READY] Compatible driver appeared during approval. Skipping installation.'
    return 0
  }
  $drivers = @(DriverRecord ([string]$device.PNPDeviceID))
  if ($drivers.Count -gt 1) {
    Log '[STOP] Multiple signed driver entries; refusing change.'
    return 15
  }
  $provider = if ($drivers.Count -eq 1) { [string]$drivers[0].DriverProviderName } else { "" }
  $inf = if ($drivers.Count -eq 1) { [string]$drivers[0].InfName } else { "" }

  # Back up the currently bound Apple driver before modifying this DFU association.
  if ($provider -match 'Apple') {
    if ($inf -notmatch '^oem[0-9]+\.inf$') {
      Log '[STOP] Apple INF cannot be safely backed up. Driver unchanged.'
      return 16
    }
    $backupPath = Join-Path $BackupRoot (($inf -replace '\.inf$','') + '-backup')
    if (-not (Test-Path $backupPath -PathType Container) -or
        @(Get-ChildItem -LiteralPath $backupPath -Filter '*.inf' -File -Recurse -ErrorAction SilentlyContinue).Count -eq 0) {
      New-Item -ItemType Directory -Path $backupPath -Force | Out-Null
      Log "[BACKUP] Exporting Apple DFU driver $inf to Downloads backup folder."
      & "$env:SystemRoot\System32\pnputil.exe" /export-driver $inf $backupPath | Out-Null
      if ($LASTEXITCODE -ne 0 -or
          @(Get-ChildItem -LiteralPath $backupPath -Filter '*.inf' -File -Recurse -ErrorAction SilentlyContinue).Count -eq 0) {
        Log '[STOP] Original driver backup could not be verified. Nothing installed.'
        return 17
      }
    }
    Log "[BACKUP] Verified original driver backup in $backupPath"
  } elseif ($provider -ne '' -and $provider -notmatch 'Microsoft|libusb|WinUSB') {
    Log '[STOP] Unknown third-party driver binding. Refusing to replace it.'
    return 18
  }

  # Only invoke libwdi against exact VID/PID, not wildcard/normal/Recovery mode.
  # No interface wildcard or driver filter used.
  $dest = Join-Path $Root 'WinUSB-DFU-Driver'
  New-Item -ItemType Directory -Path $dest -Force | Out-Null
  Log '[INSTALL] Installing WinUSB only for Apple DFU hardware ID 05AC:1227.'
  & $Tool -n 'AiboOS Apple DFU (WinUSB)' -m 'AiboOS Research' -v 0x05AC -p 0x1227 -t 0 -f 'aiboos-dfu-winusb.inf' -d $dest
  $result = $LASTEXITCODE
  if ($result -ne 0) {
    Log "[BLOCKED] Driver installer exited with code $result."
    return 19
  }
  Start-Sleep -Seconds 3
  $after = @(PresentDfu)
  if ($after.Count -ne 1) {
    Log '[CHECK] Installation returned success but DFU device was not present for verification.'
    return 20
  }
  $newService = [string]$after[0].Service
  Log "[CHECK] Windows driver after install: $newService"
  if (-not (DriverReady $newService)) {
    Log '[BLOCKED] WinUSB binding was not confirmed. No OS payload will be sent.'
    return 21
  }
  Log '[READY] WinUSB driver bound to the DFU device. USB access/boot still require hardware testing.'
  return 0
}
try { exit (Main) }
catch {
  if ($SelfTest) { Write-Host "[FAIL] $($_.Exception.Message)"; exit 99 }
  try { Log "[ERROR] $($_.Exception.Message)" } catch { Write-Host $_ }
  exit 99
}
