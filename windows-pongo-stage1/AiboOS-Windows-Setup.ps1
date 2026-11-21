<#
AiboOS first-generation iPhone SE Windows preparation.
Automates DFU discovery, existing Apple driver backup, and read-only USB access
testing. NEVER replaces a driver, runs checkm8, or writes to the phone.
#>
[CmdletBinding()]
param([switch]$SelfTest,[switch]$BackupOnly,[string]$BackupInf)
$ErrorActionPreference = "Stop"
$DfuPattern = "VID_05AC&PID_1227"
$BackupRoot = Join-Path $env:USERPROFILE "Downloads\Apple-DFU-Driver-Backup"
$LogDir = Join-Path $env:LOCALAPPDATA "AiboOS\Logs"
$Exe = Join-Path $PSScriptRoot "aiboos-pongo-stage1.exe"

function Say([string]$message, [ConsoleColor]$color = [ConsoleColor]::Gray) {
    Write-Host $message -ForegroundColor $color
}
function Is-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Has-Backup {
    if (-not (Test-Path -LiteralPath $script:BackupRoot -PathType Container)) { return $false }
    return (@(Get-ChildItem -LiteralPath $script:BackupRoot -File -Recurse -Filter "*.inf").Count -gt 0)
}
function Export-AppleDriver([string]$inf) {
    if ($inf -notmatch '^oem[0-9]+\.inf$' -or -not (Is-Admin)) {
        Say "[STOP] Apple driver backup requires a valid INF and administrator rights." Red
        return $false
    }
    New-Item -ItemType Directory -Force -Path $script:BackupRoot | Out-Null
    Say "[AUTO] Exporting Apple driver $inf to $script:BackupRoot" Cyan
    & "$env:SystemRoot\System32\pnputil.exe" /export-driver $inf $script:BackupRoot
    if ($LASTEXITCODE -ne 0 -or -not (Has-Backup)) {
        Say "[STOP] Driver backup did not pass verification." Red
        return $false
    }
    Say "[OK] Apple driver backup verified." Green
    return $true
}
function Main {
    Say "AiboOS SE 2016 - ONE-CLICK WINDOWS PREPARATION" Magenta
    Say "Checks USB and backs up original driver. NO flashing or exploit."
    if ($SelfTest) {
        if ($DfuPattern -ne "VID_05AC&PID_1227" -or
            [IO.Path]::GetFileName($Exe) -ne "aiboos-pongo-stage1.exe" -or
            "oem84.inf" -notmatch '^oem[0-9]+\.inf$') {
            throw "Selftest failed."
        }
        Say "[PASS] Offline setup checks; no USB devices or drivers accessed." Green
        return 0
    }
    if ($BackupOnly) {
        if (Export-AppleDriver $BackupInf) { return 0 }
        return 2
    }
    if (-not (Test-Path -LiteralPath $Exe -PathType Leaf)) {
        Say "[STOP] Extract the entire ZIP: aiboos-pongo-stage1.exe is missing." Red
        return 2
    }
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    $logPath = Join-Path $LogDir "Windows-Setup-Last-Run.txt"
    $notes = New-Object System.Collections.Generic.List[string]
    $notes.Add("AiboOS Windows USB preflight, $(Get-Date -Format o)")
    $notes.Add("No exploit, driver replacement, or NAND access attempted.")
    Say "[AUTO] Detecting Apple DFU USB hardware..." Cyan
    $drivers = @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction Stop |
        Where-Object { $_.DeviceID -match $DfuPattern })
    $present = @(Get-CimInstance Win32_PnPEntity -ErrorAction Stop |
        Where-Object { $_.PNPDeviceID -match $DfuPattern -and $_.Present -ne $false })
    if ($present.Count -eq 0) {
        Say "[NOT READY] iPhone DFU 05AC:1227 is not currently connected." Yellow
        Say "Normal iOS and Recovery Mode do not count as DFU."
        $notes.Add("DFU not present")
        $notes | Set-Content -LiteralPath $logPath -Encoding UTF8
        return 1
    }
    Say "[OK] DFU 05AC:1227 detected. Found $($present.Count) device record(s)." Green
    if ($present.Count -ne 1) {
        Say "[STOP] Need one unambiguous DFU device. No driver changes made." Red
        return 2
    }
    foreach ($d in $drivers) {
        Say "[DRIVER] $($d.DeviceName) | $($d.DriverProviderName) | $($d.InfName)"
        $notes.Add("Device=$($d.DeviceName), Provider=$($d.DriverProviderName), INF=$($d.InfName)")
    }
    $apple = @($drivers | Where-Object {
        $_.DriverProviderName -match 'Apple' -and $_.InfName -match '^oem[0-9]+\.inf$'
    })
    if ($apple.Count -eq 1) {
        if (Has-Backup) {
            Say "[OK] Existing Apple driver backup found. No duplicate backup required." Green
        } elseif (Is-Admin) {
            if (-not (Export-AppleDriver ([string]$apple[0].InfName))) { return 2 }
        } else {
            Say "[AUTO] Windows approval needed to back up the original Apple driver." Cyan
            $arg = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -BackupOnly -BackupInf "{1}"' -f $PSCommandPath, ([string]$apple[0].InfName)
            try {
                $proc = Start-Process -FilePath "powershell.exe" -ArgumentList $arg -Verb RunAs -Wait -PassThru -ErrorAction Stop
                if ($proc.ExitCode -eq 0 -and (Has-Backup)) {
                    Say "[OK] Apple driver backup completed." Green
                } else {
                    Say "[WARN] Backup unavailable. No drivers were changed." Yellow
                }
            } catch {
                Say "[WARN] Administrator request cancelled. No drivers were changed." Yellow
            }
        }
    }
    Say "[AUTO] Testing whether Windows can open DFU through libusb..." Cyan
    & $Exe --test-dfu-access
    $code = $LASTEXITCODE
    $notes.Add("libusb-open diagnostic exit code=$code")
    $notes | Set-Content -LiteralPath $logPath -Encoding UTF8
    Say "[INFO] Log: $logPath"
    if ($code -eq 0) {
        Say "[PASS] DFU driver works. Skip driver installation." Green
        Say "[NEXT] PongoOS has NOT been verified booting. No exploit was run."
    } else {
        Say "[BLOCKED] Driver access failed. Do not replace random drivers." Yellow
        Say "The user must review/approve any change for exact device 05AC:1227."
        Say "Official driver utility: https://zadig.akeo.ie/"
    }
    return $code
}
try { exit (Main) }
catch {
    Say "[ERROR] $($_.Exception.Message)" Red
    exit 2
}
