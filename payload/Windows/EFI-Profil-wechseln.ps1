# XT12 Pro: OpenCore-Profil auf der externen Platte umschalten (BASIS <-> IRIS), von Windows aus.
# BASIS = Installation/Notfall ohne Grafikbeschleunigung, IRIS = WhateverXe (Iris Xe mit Metal).
$ErrorActionPreference = 'Stop'
$identity = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -Verb RunAs -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'))
    exit
}
$mounted = $null
try {
    $dataLetter = [IO.Path]::GetPathRoot($PSScriptRoot).Substring(0, 1)
    $dataPart = Get-Partition -DriveLetter $dataLetter
    $disk = Get-Disk -Number $dataPart.DiskNumber
    if ([string]$disk.BusType -ne 'USB' -or $disk.IsBoot -or $disk.IsSystem) { throw 'Bitte direkt von der externen XT12-Platte starten.' }
    $bootPart = @(Get-Partition -DiskNumber $disk.Number | Where-Object {
        ($_ | Get-Volume -ErrorAction SilentlyContinue).FileSystemLabel -eq 'XT12BOOT' })
    if ($bootPart.Count -ne 1) { throw 'XT12BOOT wurde auf dieser Platte nicht gefunden.' }
    $bootPart = $bootPart[0]
    $letter = [string]$bootPart.DriveLetter
    if ($letter -notmatch '^[A-Z]$') {
        $used = @(Get-PSDrive -PSProvider FileSystem | ForEach-Object { [string]$_.Name })
        $letter = @('X', 'W', 'V', 'U', 'T', 'S', 'R') | Where-Object { $used -notcontains $_ } | Select-Object -First 1
        $guidPath = @($bootPart.AccessPaths | Where-Object { $_ -like '\\?\Volume{*' })[0]
        & "$env:SystemRoot\System32\mountvol.exe" ($letter + ':') $guidPath | Out-Null
        $mounted = $letter
        Start-Sleep -Seconds 1
    }
    $root = $letter + ':\'
    $active = Join-Path $root 'EFI'
    $iris = Join-Path $root 'EFI-IRIS-XE'
    $base = Join-Path $root 'EFI-BASIS'
    if ((Test-Path $iris) -eq (Test-Path $base)) { throw 'Auf XT12BOOT ist kein eindeutiges zweites Profil vorhanden.' }
    if (Test-Path $iris) { $mode = 'IRIS'; $source = $iris; $keep = 'EFI-BASIS' }
    else { $mode = 'BASIS'; $source = $base; $keep = 'EFI-IRIS-XE' }
    foreach ($dir in @($active, $source)) {
        foreach ($f in @('BOOT\BOOTx64.efi', 'OC\OpenCore.efi', 'OC\config.plist')) {
            if (-not (Test-Path -LiteralPath (Join-Path $dir $f))) { throw ('EFI-Datei fehlt: ' + (Join-Path $dir $f)) }
        }
    }
    Write-Host ''
    if ($mode -eq 'IRIS') { Write-Host 'Aktiv ist BASIS. Umschalten auf IRIS (WhateverXe, Iris-Xe-Beschleunigung)?' }
    else { Write-Host 'Aktiv ist IRIS. Zurueck auf BASIS (ohne Grafikbeschleunigung, sicherer Start)?' }
    if ((Read-Host ('Zum Umschalten ' + $mode + ' eingeben')) -ne $mode) { Write-Host 'Abgebrochen.'; return }
    Rename-Item -LiteralPath $active -NewName $keep
    try { Rename-Item -LiteralPath $source -NewName 'EFI' }
    catch { Rename-Item -LiteralPath (Join-Path $root $keep) -NewName 'EFI'; throw }
    Write-Host ('Aktives Profil auf XT12BOOT: ' + $mode) -ForegroundColor Green
}
catch { Write-Host $_.Exception.Message -ForegroundColor Red }
finally {
    if ($mounted) { & "$env:SystemRoot\System32\mountvol.exe" ($mounted + ':') /d | Out-Null }
    [void](Read-Host 'Enter zum Schliessen')
}
