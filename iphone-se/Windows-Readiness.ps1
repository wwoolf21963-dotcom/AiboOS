# Read-only Windows 11 iPhone SE A9 bring-up readiness checker.
# NO network, administrator permissions, driver changes, WSL, phone access, or reboots.
$ErrorActionPreference = 'Stop'
Write-Host ''
Write-Host 'AiboOS iPhone SE (2016) - READ-ONLY readiness check' -ForegroundColor Magenta
Write-Host 'This does NOT install or boot AiboOS.'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$variants = @(
    [pscustomobject]@{ Name='Samsung-S8000'; Dtb='s8000-n69u.dtb' },
    [pscustomobject]@{ Name='TSMC-S8003'; Dtb='s8003-n69.dtb' }
)
$ok = $true
foreach ($v in $variants) {
    $folder = Join-Path $root $v.Name
    Write-Host ('Checking ' + $v.Name + ':') -ForegroundColor Cyan
    foreach ($name in @('m1n1.bin', 'm1n1-linux.bin', 'Image.gz', 'initramfs.cpio.gz', $v.Dtb)) {
        $path = Join-Path $folder $name
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Write-Host (' [OK] ' + $name)
        } else {
            Write-Host (' [MISSING] ' + $name) -ForegroundColor Red
            $ok = $false
        }
    }
    $sumFile = Join-Path $folder 'SHA256SUMS.txt'
    if (Test-Path -LiteralPath $sumFile -PathType Leaf) {
        foreach ($line in @(Get-Content -LiteralPath $sumFile)) {
            $parts = $line.Trim() -split '\s+', 2
            if ($parts.Count -ne 2 -or $parts[0] -notmatch '^[0-9a-fA-F]{64}$') {
                Write-Host ' [ERROR] Malformed SHA256SUMS entry' -ForegroundColor Red
                $ok = $false
                continue
            }
            $filename = $parts[1].TrimStart('*')
            # Only simple file names from a known package are accepted.
            if ($filename -match '[\\/]' -or $filename -eq '.' -or $filename -eq '..') {
                Write-Host ' [ERROR] Unsafe checksum file entry' -ForegroundColor Red
                $ok = $false
                continue
            }
            $filePath = Join-Path $folder $filename
            if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
                Write-Host (' [MISSING] ' + $filename) -ForegroundColor Red
                $ok = $false
                continue
            }
            $actual = (Get-FileHash -LiteralPath $filePath -Algorithm SHA256).Hash
            if ($actual -ine $parts[0]) {
                Write-Host (' [ERROR] Hash mismatch: ' + $filename) -ForegroundColor Red
                $ok = $false
            }
        }
        Write-Host ' Checksum inspection finished.'
    } else {
        Write-Host ' [MISSING] SHA256SUMS.txt' -ForegroundColor Red
        $ok = $false
    }
}
try {
    $apple = @(Get-PnpDevice -PresentOnly -ErrorAction Stop | Where-Object {
        $_.FriendlyName -match 'Apple|iPhone' -and $_.Status -eq 'OK'
    })
    if ($apple.Count -gt 0) {
        Write-Host ('Windows reports ' + $apple.Count + ' active Apple/iPhone PnP device entry or entries.') -ForegroundColor Green
        Write-Host 'This proves only that Windows sees Apple hardware, not that Linux can boot it.'
    } else {
        Write-Host 'No active Apple/iPhone PnP entry found. Check the cable/unlock/Trust.'
    }
} catch {
    Write-Host 'Windows PnP list unavailable; the file checks above are still valid.'
}
Write-Host ''
if ($ok) {
    Write-Host '[OK] A9 build files verified locally. HARDWARE BOOT IS NOT VERIFIED.' -ForegroundColor Green
} else {
    Write-Host '[ERROR] A9 build package incomplete or failed checksum verification.' -ForegroundColor Red
}
Write-Host 'No iPhone changes were made. Never flash this bundle.'
if (-not $ok) { exit 1 }
