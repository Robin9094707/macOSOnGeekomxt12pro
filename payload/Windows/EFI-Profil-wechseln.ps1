# XT12 Pro: OpenCore-Profil auf der externen Platte umschalten (BASIS <-> IRIS), von Windows aus.
# BASIS = Installation/Notfall ohne Grafikbeschleunigung, IRIS = WhateverXe (Iris Xe mit Metal).
# XT12BOOT ist eine EFI-Systempartition, die Windows schuetzt. Sie wird dafuer kurz zur normalen Datenpartition
# gemacht, eingebunden, umbenannt und danach wieder zur EFI-Partition gemacht.
$ErrorActionPreference = 'Stop'
$identity = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -Verb RunAs -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'))
    exit
}
$EspType = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
$DataType = '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'

function Invoke-Diskpart([string[]]$Lines) {
    $file = Join-Path $env:TEMP ('xt12-diskpart-' + [guid]::NewGuid().ToString('N') + '.txt')
    [IO.File]::WriteAllLines($file, $Lines, [Text.Encoding]::ASCII)
    try { & "$env:SystemRoot\System32\diskpart.exe" /s $file 2>&1 | Out-String }
    finally { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
}

function Set-PartType($DiskNumber, $PartitionNumber, $Type) {
    $text = Invoke-Diskpart @("select disk $DiskNumber", "select partition $PartitionNumber",
        ('set id=' + $Type.Trim('{', '}') + ' override'), 'exit')
    Start-Sleep -Seconds 2
    Update-HostStorageCache -ErrorAction SilentlyContinue
    $now = ([string](Get-Partition -DiskNumber $DiskNumber -PartitionNumber $PartitionNumber).GptType).ToLowerInvariant()
    if ($now -ne $Type) { throw ("Partitionstyp liess sich nicht setzen:`n" + $text) }
}

$disk = $null; $bootPart = $null; $letter = $null; $wasEsp = $false
try {
    $dataLetter = [IO.Path]::GetPathRoot($PSScriptRoot).Substring(0, 1)
    $dataPart = Get-Partition -DriveLetter $dataLetter
    $disk = Get-Disk -Number $dataPart.DiskNumber
    if ([string]$disk.BusType -ne 'USB' -or $disk.IsBoot -or $disk.IsSystem) { throw 'Bitte direkt von der externen XT12-Platte starten.' }

    # XT12BOOT finden: Volume mit diesem Namen, dessen Volume-Pfad zu einer Partition dieser Platte gehoert.
    $parts = @{}
    foreach ($p in @(Get-Partition -DiskNumber $disk.Number)) {
        foreach ($ap in @($p.AccessPaths)) { if ($ap -like '\\?\Volume{*') { $parts[$ap.ToUpperInvariant()] = $p } }
    }
    $vol = @(Get-CimInstance -ClassName Win32_Volume | Where-Object {
        $_.Label -eq 'XT12BOOT' -and $parts.ContainsKey(([string]$_.DeviceID).ToUpperInvariant()) })
    if ($vol.Count -ne 1) { throw 'XT12BOOT wurde auf dieser Platte nicht gefunden.' }
    $bootPart = $parts[([string]$vol[0].DeviceID).ToUpperInvariant()]

    $wasEsp = ([string]$bootPart.GptType).ToLowerInvariant() -eq $EspType
    if ($wasEsp) { Set-PartType $disk.Number $bootPart.PartitionNumber $DataType }
    $used = @(Get-PSDrive -PSProvider FileSystem | ForEach-Object { [string]$_.Name })
    $letter = @('X', 'W', 'V', 'U', 'T', 'S', 'R', 'Q', 'P') | Where-Object { $used -notcontains $_ } | Select-Object -First 1
    Get-Partition -DiskNumber $disk.Number -PartitionNumber $bootPart.PartitionNumber | Set-Partition -NewDriveLetter $letter
    for ($i = 0; $i -lt 20 -and -not (Test-Path ($letter + ':\')); $i++) { Start-Sleep -Milliseconds 500 }
    if (-not (Test-Path ($letter + ':\'))) { throw 'XT12BOOT liess sich nicht einbinden.' }

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
    if ($disk -and $bootPart) {
        try {
            if ($letter) {
                Get-Partition -DiskNumber $disk.Number -PartitionNumber $bootPart.PartitionNumber |
                    Remove-PartitionAccessPath -AccessPath ($letter + ':\') -ErrorAction SilentlyContinue
            }
            Set-PartType $disk.Number $bootPart.PartitionNumber $EspType
        }
        catch { Write-Host ('XT12BOOT konnte nicht wieder als EFI-Partition markiert werden: ' + $_.Exception.Message) -ForegroundColor Red }
    }
    [void](Read-Host 'Enter zum Schliessen')
}
