param(
    [Parameter(Mandatory = $true)][ValidateSet('Inspect', 'Install')][string]$Action,
    [string]$Source,
    [string]$BackupDir,
    [switch]$AddBootEntry
)
# Optional: put the XT12 OpenCore on the internal Windows EFI partition (the ~200 MB ESP), replacing an OpenCore that is
# already there. Windows' own files (EFI\Microsoft) are never touched; EFI\BOOT\BOOTx64.efi is replaced only when it is
# an OpenCore one. Everything replaced is backed up first (to BackupDir).
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$EspGuid = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'

function Get-SystemEsp {
    $esp = @(Get-Partition | Where-Object { $_.GptType -eq $EspGuid } | Where-Object {
        $d = Get-Disk -Number $_.DiskNumber; $d.IsSystem -or $d.IsBoot -or $_.IsSystem })
    if ($esp.Count -lt 1) { throw 'Keine EFI-Systempartition der Windows-Platte gefunden (BIOS im UEFI-Modus?).' }
    $esp[0]
}

function Get-FreeLetter {
    $used = @(Get-PSDrive -PSProvider FileSystem | ForEach-Object { [string]$_.Name })
    $letter = @('S', 'R', 'Q', 'P', 'O', 'N', 'M', 'L', 'K', 'T', 'U', 'V', 'W') | Where-Object { $used -notcontains $_ } | Select-Object -First 1
    if (-not $letter) { throw 'Kein freier Laufwerksbuchstabe fuer die EFI-Partition.' }
    $letter
}

function Test-OpenCoreFile($Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $bytes = [IO.File]::ReadAllBytes($Path)
    $ascii = [Text.Encoding]::ASCII.GetString($bytes)
    $utf16 = [Text.Encoding]::Unicode.GetString($bytes)
    ($ascii.Contains('OpenCore') -or $utf16.Contains('OpenCore') -or $ascii.Contains('OC_BOOTSTRAP') -or $utf16.Contains('\EFI\OC\'))
}

function Get-TreeBytes($Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    $sum = (Get-ChildItem -LiteralPath $Path -Recurse -File -Force | Measure-Object -Property Length -Sum).Sum
    if ($null -eq $sum) { 0 } else { [int64]$sum }
}

function Get-FirmwareEntries {
    $text = (& "$env:SystemRoot\System32\bcdedit.exe" /enum firmware) | Out-String
    $entries = @()
    foreach ($block in ($text -split "(\r?\n){2,}")) {
        $id = [regex]::Match($block, '(?m)^identifier\s+(\{[^}]+\})').Groups[1].Value
        if (-not $id) { $id = [regex]::Match($block, '(?m)^Bezeichner\s+(\{[^}]+\})').Groups[1].Value }
        $path = [regex]::Match($block, '(?m)^(path|Pfad)\s+(.+)$').Groups[2].Value.Trim()
        $desc = [regex]::Match($block, '(?m)^(description|Beschreibung)\s+(.+)$').Groups[2].Value.Trim()
        if ($id) { $entries += [pscustomobject]@{ id = $id; path = $path; description = $desc } }
    }
    $entries
}

$esp = Get-SystemEsp
$letter = Get-FreeLetter
& "$env:SystemRoot\System32\mountvol.exe" ($letter + ':') /s | Out-Null
$root = $letter + ':\'
try {
    for ($i = 0; $i -lt 10 -and -not (Test-Path $root); $i++) { Start-Sleep -Milliseconds 500 }
    if (-not (Test-Path $root)) { throw 'Die EFI-Partition liess sich nicht einbinden.' }
    $volume = Get-Volume -DriveLetter $letter
    $oc = Join-Path $root 'EFI\OC'
    $boot = Join-Path $root 'EFI\BOOT\BOOTx64.efi'
    $info = [ordered]@{
        size          = [int64]$esp.Size
        free          = [int64]$volume.SizeRemaining
        has_opencore  = (Test-Path -LiteralPath (Join-Path $oc 'OpenCore.efi'))
        opencore_mb   = [math]::Round((Get-TreeBytes $oc) / 1MB, 1)
        boot_is_oc    = (Test-OpenCoreFile $boot)
        boot_exists   = (Test-Path -LiteralPath $boot)
        has_microsoft = (Test-Path -LiteralPath (Join-Path $root 'EFI\Microsoft\Boot\bootmgfw.efi'))
        oc_entry      = [bool](@(Get-FirmwareEntries | Where-Object { $_.path -match '\\EFI\\OC\\OpenCore\.efi' }).Count)
    }
    if ($Action -eq 'Inspect') {
        ConvertTo-Json -InputObject $info -Compress
        exit 0
    }

    # --- Install -----------------------------------------------------------------------------------------------------
    if (-not (Test-Path -LiteralPath (Join-Path $Source 'OC\OpenCore.efi'))) { throw "Quelle ist keine OpenCore-EFI: $Source" }
    if (-not $info.has_microsoft) { throw 'Auf dieser EFI-Partition fehlt der Windows-Bootmanager. Abbruch, nichts geaendert.' }
    $need = (Get-TreeBytes (Join-Path $Source 'OC')) + 4MB
    $available = [int64]$info.free + (Get-TreeBytes $oc)
    if ($need -gt $available) {
        throw ('Zu wenig Platz auf der Windows-EFI: ' + [math]::Round($available / 1MB) + ' MB frei, ' + [math]::Round($need / 1MB) + ' MB noetig.')
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup = Join-Path $BackupDir ('Windows-EFI-Backup-' + $stamp)
    New-Item -ItemType Directory -Force -Path $backup | Out-Null
    foreach ($name in @('OC', 'BOOT')) {
        $from = Join-Path $root ('EFI\' + $name)
        if (Test-Path -LiteralPath $from) { Copy-Item -LiteralPath $from -Destination (Join-Path $backup $name) -Recurse -Force }
    }
    if ((Get-TreeBytes $oc) -gt 0 -and (Get-TreeBytes (Join-Path $backup 'OC')) -ne (Get-TreeBytes $oc)) {
        throw 'Die Sicherung der alten OpenCore-EFI ist unvollstaendig. Nichts geaendert.'
    }

    if (Test-Path -LiteralPath $oc) { Remove-Item -LiteralPath $oc -Recurse -Force }
    Copy-Item -LiteralPath (Join-Path $Source 'OC') -Destination $oc -Recurse -Force
    $replacedBoot = $false
    if ($info.boot_is_oc -or -not $info.boot_exists) {
        New-Item -ItemType Directory -Force -Path (Split-Path $boot) | Out-Null
        Copy-Item -LiteralPath (Join-Path $Source 'BOOT\BOOTx64.efi') -Destination $boot -Force
        $replacedBoot = $true
    }
    Set-Content -LiteralPath (Join-Path $root '.1401-build') -Value 'built by 1401 (XT12 Pro Golden Gate Builder)' -Encoding ASCII

    $bad = @()
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $Source 'OC') -Recurse -File -Force) {
        $rel = $file.FullName.Substring((Join-Path $Source 'OC').Length).TrimStart('\')
        $dst = Join-Path $oc $rel
        if (-not (Test-Path -LiteralPath $dst) -or (Get-FileHash -LiteralPath $dst).Hash -ne (Get-FileHash -LiteralPath $file.FullName).Hash) { $bad += $rel }
    }
    if ($bad.Count) { throw ('Diese Dateien lesen sich auf der Windows-EFI falsch zurueck: ' + ($bad -join ', ') + ". Sicherung: $backup") }

    $entry = ''
    if ($AddBootEntry -and -not $info.oc_entry) {
        $out = (& "$env:SystemRoot\System32\bcdedit.exe" /copy '{bootmgr}' /d 'OpenCore (XT12 Pro)') | Out-String
        $guid = [regex]::Match($out, '\{[0-9a-fA-F-]{36}\}').Value
        if ($guid) {
            & "$env:SystemRoot\System32\bcdedit.exe" /set $guid path '\EFI\OC\OpenCore.efi' | Out-Null
            & "$env:SystemRoot\System32\bcdedit.exe" /set '{fwbootmgr}' displayorder $guid /addlast | Out-Null
            $entry = $guid
        }
    }
    ConvertTo-Json -InputObject @{ backup = $backup; boot_replaced = $replacedBoot; entry = $entry; had_entry = $info.oc_entry } -Compress
}
finally {
    & "$env:SystemRoot\System32\mountvol.exe" ($letter + ':') /d | Out-Null
}
