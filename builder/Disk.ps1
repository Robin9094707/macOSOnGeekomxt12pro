param(
    [Parameter(Mandatory = $true)][ValidateSet('List', 'Prepare', 'Check', 'Find', 'Seal')][string]$Action,
    [uint32]$Number,
    [string]$ExpectedToken,
    [string]$Letters,
    [uint64]$DataMB,
    [switch]$WithMacos
)
# Disk work for the XT12 Pro builder. Only USB disks are ever offered or touched, never the disk Windows runs from.
# A disk is identified by a token (interface path + serial + size), checked again before every write, so a disk number
# or drive letter that moved can never point the builder at another disk.
#
# Layout written by Prepare (GPT):
#   XT12BOOT  2 GiB FAT32   OpenCore, Tahoe recovery, profiles, BIOS guide
#   XT12DATA  exFAT          Tahoe full installer, macOS 27 files, Liberator, Iris Xe, scripts
#   MACOS     exFAT          (only with -WithMacos) placeholder; the Recovery script erases it as APFS for macOS
#
# Windows protects EFI system partitions (no drive letter, no reliable access). So XT12BOOT is created and written as an
# ordinary FAT32 partition and only "sealed" as EFI system partition at the very end (Seal). Find (resume) unseals it
# again before anything is written.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$EspType = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
$DataType = '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'

function Test-UsbDisk($Disk) {
    $null -ne $Disk -and [string]$Disk.BusType -eq 'USB' -and $Disk.Path -and $Disk.Size -ge 30GB -and
        -not ($Disk.IsBoot -or $Disk.IsSystem -or $Disk.IsReadOnly)
}

function Get-Token($Disk) {
    $data = ([string]$Disk.Path).ToUpperInvariant() + '|' + ([string]$Disk.SerialNumber).Trim() + '|' + $Disk.Size
    [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($data))
}

function Find-SelectedDisk {
    $found = @(Get-Disk | Where-Object { (Test-UsbDisk $_) -and (Get-Token $_) -ceq $ExpectedToken })
    if ($found.Count -ne 1) { throw 'Die ausgewaehlte USB-Platte ist nicht mehr eindeutig verbunden.' }
    $found[0]
}

function Get-Letters($Disk) {
    @(Get-Partition -DiskNumber $Disk.Number -ErrorAction SilentlyContinue |
        Where-Object { $_.DriveLetter -match '^[A-Z]$' } | ForEach-Object { ([string]$_.DriveLetter) + ':' })
}

function Get-MountLetters {
    # Volume path -> drive letter, straight from the mount manager (mountvol). Unlike WMI and the storage cmdlets it
    # also knows letters that diskpart gave to an EFI system partition.
    $map = @{}
    $current = $null
    foreach ($line in (& "$env:SystemRoot\System32\mountvol.exe")) {
        $text = ([string]$line).Trim()
        if ($text -like '\\?\Volume{*') { $current = $text.ToUpperInvariant() }
        elseif ($current -and $text -match '^([A-Z]):\\$') { $map[$current] = $Matches[1] }
        elseif (-not $text) { $current = $null }
    }
    $map
}

function Get-DiskVolumes($Disk) {
    # Label -> {letter, fs, path, partition, type} for every labelled volume on this disk (read through WMI and tied to
    # the disk by the partition's volume path).
    Update-HostStorageCache -ErrorAction SilentlyContinue
    $parts = @{}
    foreach ($p in @(Get-Partition -DiskNumber $Disk.Number -ErrorAction SilentlyContinue)) {
        foreach ($ap in @($p.AccessPaths)) { if ($ap -like '\\?\Volume{*') { $parts[$ap.ToUpperInvariant()] = $p } }
    }
    $mounts = Get-MountLetters
    $map = @{}
    foreach ($v in @(Get-CimInstance -ClassName Win32_Volume -ErrorAction SilentlyContinue)) {
        $path = ([string]$v.DeviceID).ToUpperInvariant()
        if (-not $v.Label -or -not $parts.ContainsKey($path)) { continue }
        $letter = ([string]$v.DriveLetter).TrimEnd(':')
        if ($letter -notmatch '^[A-Z]$' -and $mounts.ContainsKey($path)) { $letter = $mounts[$path] }
        $p = $parts[$path]
        $map[[string]$v.Label] = [pscustomobject]@{
            letter = $letter; fs = [string]$v.FileSystem; path = [string]$v.DeviceID
            partition = [int]$p.PartitionNumber; type = ([string]$p.GptType).ToLowerInvariant()
        }
    }
    $map
}

function Get-Labeled($Disk) {
    $map = @{}
    $vols = Get-DiskVolumes $Disk
    foreach ($k in $vols.Keys) { $map[$k] = $vols[$k].letter }
    $map
}

function Get-FreeLetters {
    $used = @()
    $used += @(Get-PSDrive -PSProvider FileSystem | ForEach-Object { [string]$_.Name })
    $used += @(Get-Volume | Where-Object { $_.DriveLetter } | ForEach-Object { [string]$_.DriveLetter })
    $used += @((Get-MountLetters).Values)
    $used += @([Environment]::GetLogicalDrives() | ForEach-Object { ([string]$_).Substring(0, 1) })
    @('Z', 'Y', 'X', 'W', 'V', 'U', 'T', 'S', 'R', 'Q', 'P', 'O', 'N', 'M', 'L', 'K', 'J', 'I', 'H', 'G') |
        Where-Object { $used -notcontains $_ }
}

function Invoke-Diskpart([string[]]$Lines) {
    $file = Join-Path $env:TEMP ('xt12-diskpart-' + [guid]::NewGuid().ToString('N') + '.txt')
    [IO.File]::WriteAllLines($file, $Lines, [Text.Encoding]::ASCII)
    try {
        $output = & "$env:SystemRoot\System32\diskpart.exe" /s $file 2>&1 | Out-String
        @{ code = $LASTEXITCODE; text = $output }
    }
    finally { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
}

function Set-PartType($Disk, [int]$Partition, [string]$Type) {
    $result = Invoke-Diskpart @("select disk $($Disk.Number)", "select partition $Partition",
        ('set id=' + $Type.Trim('{', '}') + ' override'), 'exit')
    Start-Sleep -Seconds 2
    $now = ([string](Get-Partition -DiskNumber $Disk.Number -PartitionNumber $Partition).GptType).ToLowerInvariant()
    if ($now -ne $Type) { throw ("Partitionstyp liess sich nicht setzen:`n" + $result.text) }
}

function Test-Root($Letter) {
    # .NET instead of Test-Path: PowerShell's drive provider often does not see a letter given during this session.
    try { [IO.Directory]::Exists($Letter + ':\') } catch { $false }
}

function Wait-Root($Letter, $Seconds = 10) {
    for ($i = 0; $i -lt ($Seconds * 2); $i++) {
        if (Test-Root $Letter) { return $true }
        Start-Sleep -Milliseconds 500
    }
    $false
}

function Mount-Label($Disk, $Label) {
    # The letter a volume of this disk really has; one is given when it has none. Several letters and two methods are
    # tried, and every failure is reported, so a stubborn Windows says why.
    $log = @()
    for ($round = 1; $round -le 3; $round++) {
        $vol = (Get-DiskVolumes (Find-SelectedDisk))[$Label]
        if (-not $vol) { $log += "Runde ${round}: Volume $Label noch nicht sichtbar"; Start-Sleep -Seconds 3; continue }
        if ($vol.letter -match '^[A-Z]$') {
            if (Wait-Root $vol.letter 3) { return $vol.letter }
            $log += "Runde ${round}: $($vol.letter): ist eingetragen, aber nicht lesbar -> wird freigegeben"
            & "$env:SystemRoot\System32\mountvol.exe" ($vol.letter + ':') /d 2>&1 | Out-Null
            Start-Sleep -Seconds 1
        }
        foreach ($letter in @(Get-FreeLetters | Select-Object -First 4)) {
            try {
                Get-Partition -DiskNumber $Disk.Number -PartitionNumber $vol.partition |
                    Set-Partition -NewDriveLetter $letter -ErrorAction Stop
            }
            catch {
                $log += "Set-Partition ${letter}: $($_.Exception.Message.Trim())"
                $out = (& "$env:SystemRoot\System32\mountvol.exe" ($letter + ':') $vol.path 2>&1 | Out-String).Trim()
                if ($LASTEXITCODE) { $log += "mountvol ${letter}: $out" }
            }
            if (Wait-Root $letter) { return $letter }
            $log += "${letter}: nach dem Zuweisen nicht lesbar (Typ $($vol.type), FS $($vol.fs))"
            & "$env:SystemRoot\System32\mountvol.exe" ($letter + ':') /d 2>&1 | Out-Null
        }
        Start-Sleep -Seconds 3
    }
    throw ("Die Partition $Label liess sich nicht einbinden:`n  " + ($log -join "`n  "))
}

function Assert-Letter($Letter, $FileSystem, $Label) {
    if ($Letter -notmatch '^[A-Z]$') { throw "Die Partition $Label hat keinen Laufwerksbuchstaben." }
    $vol = (Get-DiskVolumes (Find-SelectedDisk))[$Label]
    if (-not $vol -or $vol.letter -ne $Letter -or $vol.fs -ne $FileSystem) {
        $seen = if ($vol) { [string]$vol.letter + ': ' + $vol.fs } else { 'nicht gefunden' }
        throw ('Das Laufwerk ' + $Letter + ': passt nicht mehr zur ausgewaehlten Platte (' + $Label + ' / ' + $FileSystem + ', gesehen: ' + $seen + ').')
    }
}

function Open-BootPartition($Disk) {
    # Unseal XT12BOOT (EFI type -> ordinary data partition) so Windows mounts it normally, then return its letter.
    $vol = (Get-DiskVolumes $Disk)['XT12BOOT']
    if (-not $vol) { throw 'Die Partition XT12BOOT wurde auf der Platte nicht gefunden.' }
    if ($vol.letter -match '^[A-Z]$') {
        & "$env:SystemRoot\System32\mountvol.exe" ($vol.letter + ':') /d 2>$null | Out-Null
    }
    if ($vol.type -ne $DataType) { Set-PartType $Disk $vol.partition $DataType }
    Mount-Label (Find-SelectedDisk) 'XT12BOOT'
}

if ($Action -eq 'List') {
    $disks = @(Get-Disk | Where-Object { Test-UsbDisk $_ } | ForEach-Object {
        $labels = Get-Labeled $_
        [pscustomobject]@{
            number  = $_.Number; name = $_.FriendlyName; bytes = $_.Size; style = [string]$_.PartitionStyle
            letters = ((Get-Letters $_) -join ', '); token = (Get-Token $_)
            builder = ($labels.ContainsKey('XT12BOOT') -and $labels.ContainsKey('XT12DATA'))
        }
    })
    ConvertTo-Json -InputObject $disks -Compress
    exit 0
}

if ($Action -eq 'Find') {
    # A disk this builder prepared before: resume without erasing.
    $disk = Find-SelectedDisk
    $labels = Get-Labeled $disk
    if (-not ($labels.ContainsKey('XT12BOOT') -and $labels.ContainsKey('XT12DATA'))) { throw 'Auf dieser Platte ist kein frueherer XT12-Aufbau.' }
    $boot = Open-BootPartition $disk
    $data = Mount-Label (Find-SelectedDisk) 'XT12DATA'
    Assert-Letter $boot 'FAT32' 'XT12BOOT'
    Assert-Letter $data 'exFAT' 'XT12DATA'
    ConvertTo-Json -InputObject @{ boot = $boot; data = $data; macos = $labels.ContainsKey('MACOS') } -Compress
    exit 0
}

if ($Action -eq 'Check') {
    $parts = $Letters -split ','
    if ($parts[0] -ne '-') { Assert-Letter $parts[0] 'FAT32' 'XT12BOOT' }   # '-': XT12BOOT is sealed as EFI partition
    Assert-Letter $parts[1] 'exFAT' 'XT12DATA'
    exit 0
}

if ($Action -eq 'Seal') {
    # Everything is written: XT12BOOT becomes the EFI system partition the firmware boots from.
    $disk = Find-SelectedDisk
    $vol = (Get-DiskVolumes $disk)['XT12BOOT']
    if (-not $vol) { throw 'Die Partition XT12BOOT wurde auf der Platte nicht gefunden.' }
    if ($vol.letter -match '^[A-Z]$') {
        Get-Partition -DiskNumber $disk.Number -PartitionNumber $vol.partition |
            Remove-PartitionAccessPath -AccessPath ($vol.letter + ':\') -ErrorAction SilentlyContinue
        & "$env:SystemRoot\System32\mountvol.exe" ($vol.letter + ':') /d 2>$null | Out-Null
    }
    if ($vol.type -ne $EspType) { Set-PartType $disk $vol.partition $EspType }
    ConvertTo-Json -InputObject @{ sealed = $true; partition = $vol.partition } -Compress
    exit 0
}

# --- Prepare: erase the selected disk and write the layout ------------------------------------------------------------
$disk = Find-SelectedDisk
if ($disk.Number -ne $Number) { throw 'Die Nummer der Platte hat sich geaendert. Bitte neu starten und erneut waehlen.' }
$free = @(Get-FreeLetters)
if ($free.Count -lt 2) { throw 'Es sind keine zwei freien Laufwerksbuchstaben mehr frei (G: bis Z:).' }
$bootLetter = $free[0]; $dataLetter = $free[1]
if ($disk.IsOffline) { Set-Disk -Number $disk.Number -IsOffline $false }
# Drop letters a previous run may have left on this disk's volumes (the mount manager keeps them for an EFI partition).
foreach ($vol in (Get-DiskVolumes $disk).Values) {
    if ($vol.letter -match '^[A-Z]$') { & "$env:SystemRoot\System32\mountvol.exe" ($vol.letter + ':') /d 2>$null | Out-Null }
}

$lines = @("select disk $($disk.Number)", 'clean', 'convert gpt', 'create partition primary size=2048',
    'format quick fs=fat32 label="XT12BOOT"', "assign letter=$bootLetter")
if ($WithMacos) { $lines += "create partition primary size=$DataMB" } else { $lines += 'create partition primary' }
$lines += @('format quick fs=exfat label="XT12DATA"', "assign letter=$dataLetter")
if ($WithMacos) { $lines += @('create partition primary', 'format quick fs=exfat label="MACOS"', 'remove all noerr') }
$lines += 'exit'
$result = Invoke-Diskpart $lines
Start-Sleep -Seconds 3
$labels = Get-Labeled (Find-SelectedDisk)
if (-not ($labels.ContainsKey('XT12BOOT') -and $labels.ContainsKey('XT12DATA'))) {
    throw ("diskpart konnte die Platte nicht aufteilen:`n" + $result.text)
}
$disk = Find-SelectedDisk
$bootLetter = Mount-Label $disk 'XT12BOOT'
$dataLetter = Mount-Label $disk 'XT12DATA'
Assert-Letter $bootLetter 'FAT32' 'XT12BOOT'
Assert-Letter $dataLetter 'exFAT' 'XT12DATA'
ConvertTo-Json -InputObject @{ boot = $bootLetter; data = $dataLetter; macos = [bool]$WithMacos } -Compress
