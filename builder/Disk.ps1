param(
    [Parameter(Mandatory = $true)][ValidateSet('List', 'Prepare', 'Check', 'Find')][string]$Action,
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
#   1  EFI system partition, 2 GiB FAT32 "XT12BOOT"  OpenCore, Tahoe recovery, profiles, BIOS guide
#   2  exFAT "XT12DATA"                                Tahoe full installer, macOS 27 files, Liberator, Iris Xe, scripts
#   3  exFAT "MACOS" (only with -WithMacos)            placeholder; the Recovery script erases it as APFS for macOS
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

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

function Get-Labeled($Disk) {
    $map = @{}
    foreach ($p in @(Get-Partition -DiskNumber $Disk.Number -ErrorAction SilentlyContinue)) {
        $v = $p | Get-Volume -ErrorAction SilentlyContinue
        if ($v -and $v.FileSystemLabel) { $map[[string]$v.FileSystemLabel] = [string]$p.DriveLetter }
    }
    $map
}

function Assert-Letter($Letter, $FileSystem, $Label) {
    if ($Letter -notmatch '^[A-Z]$') { throw "Die Partition $Label hat keinen Laufwerksbuchstaben." }
    $disk = Find-SelectedDisk
    $partition = Get-Partition -DriveLetter $Letter
    $volume = Get-Volume -DriveLetter $Letter
    if ($partition.DiskNumber -ne $disk.Number -or $volume.FileSystem -ne $FileSystem -or $volume.FileSystemLabel -ne $Label) {
        throw ('Das Laufwerk ' + $Letter + ': passt nicht mehr zur ausgewaehlten Platte (' + $Label + ').')
    }
}

function Get-FreeLetters {
    $used = @()
    $used += @(Get-PSDrive -PSProvider FileSystem | ForEach-Object { [string]$_.Name })
    $used += @(Get-Volume | Where-Object { $_.DriveLetter } | ForEach-Object { [string]$_.DriveLetter })
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
    foreach ($name in @('XT12BOOT', 'XT12DATA')) {
        if ($labels[$name] -notmatch '^[A-Z]$') {
            # Windows does not mount an EFI system partition by itself: give it a letter through its volume path.
            $letter = @(Get-FreeLetters)[0]
            $part = Get-Partition -DiskNumber $disk.Number | Where-Object { ($_ | Get-Volume -ErrorAction SilentlyContinue).FileSystemLabel -eq $name }
            $guidPath = @($part.AccessPaths | Where-Object { $_ -like '\\?\Volume{*' })[0]
            try { $part | Set-Partition -NewDriveLetter $letter -ErrorAction Stop }
            catch { & "$env:SystemRoot\System32\mountvol.exe" ($letter + ':') $guidPath | Out-Null }
            for ($i = 0; $i -lt 10 -and -not (Test-Path ($letter + ':\')); $i++) { Start-Sleep -Milliseconds 500 }
            $labels[$name] = $letter
        }
    }
    Assert-Letter $labels['XT12BOOT'] 'FAT32' 'XT12BOOT'
    Assert-Letter $labels['XT12DATA'] 'exFAT' 'XT12DATA'
    ConvertTo-Json -InputObject @{ boot = $labels['XT12BOOT']; data = $labels['XT12DATA']; macos = $labels.ContainsKey('MACOS') } -Compress
    exit 0
}

if ($Action -eq 'Check') {
    $parts = $Letters -split ','
    Assert-Letter $parts[0] 'FAT32' 'XT12BOOT'
    Assert-Letter $parts[1] 'exFAT' 'XT12DATA'
    exit 0
}

# --- Prepare: erase the selected disk and write the layout ------------------------------------------------------------
$disk = Find-SelectedDisk
if ($disk.Number -ne $Number) { throw 'Die Nummer der Platte hat sich geaendert. Bitte neu starten und erneut waehlen.' }
$free = @(Get-FreeLetters)
if ($free.Count -lt 2) { throw 'Es sind keine zwei freien Laufwerksbuchstaben mehr frei (G: bis Z:).' }
$bootLetter = $free[0]; $dataLetter = $free[1]
if ($disk.IsOffline) { Set-Disk -Number $disk.Number -IsOffline $false }

function Get-Script([bool]$TrueEsp) {
    $lines = @("select disk $($disk.Number)", 'clean', 'convert gpt')
    if ($TrueEsp) { $lines += 'create partition efi size=2048' } else { $lines += 'create partition primary size=2048' }
    $lines += @('format quick fs=fat32 label="XT12BOOT"', "assign letter=$bootLetter")
    if ($WithMacos) { $lines += "create partition primary size=$DataMB" } else { $lines += 'create partition primary' }
    $lines += @('format quick fs=exfat label="XT12DATA"', "assign letter=$dataLetter")
    if ($WithMacos) { $lines += @('create partition primary', 'format quick fs=exfat label="MACOS"', 'remove all noerr') }
    $lines += 'exit'
    $lines
}

# A real EFI system partition first (what every UEFI firmware boots from); a FAT32 data partition as the fallback for
# Windows builds that refuse an ESP on a USB disk.
$result = Invoke-Diskpart (Get-Script $true)
Start-Sleep -Seconds 3
$labels = Get-Labeled (Find-SelectedDisk)
if (-not ($labels.ContainsKey('XT12BOOT') -and $labels.ContainsKey('XT12DATA'))) {
    $result = Invoke-Diskpart (Get-Script $false)
    Start-Sleep -Seconds 3
    $labels = Get-Labeled (Find-SelectedDisk)
}
if (-not ($labels.ContainsKey('XT12BOOT') -and $labels.ContainsKey('XT12DATA'))) {
    throw ("diskpart konnte die Platte nicht aufteilen:`n" + $result.text)
}
for ($i = 0; $i -lt 10 -and (-not (Test-Path ($bootLetter + ':\')) -or -not (Test-Path ($dataLetter + ':\'))); $i++) { Start-Sleep -Seconds 1 }
Assert-Letter $bootLetter 'FAT32' 'XT12BOOT'
Assert-Letter $dataLetter 'exFAT' 'XT12DATA'
ConvertTo-Json -InputObject @{ boot = $bootLetter; data = $dataLetter; macos = [bool]$WithMacos } -Compress
