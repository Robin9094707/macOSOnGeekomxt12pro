# Startet den XT12-Pro-Builder: holt die gepruefte 1401-Engine (nullmoth/1401 v3.0, eingebettetes Python + OpenCore-
# Builder), entpackt sie einmal in den Cache und startet XT12Builder.py damit. Laeuft als Administrator.
$ErrorActionPreference = 'Stop'
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -Verb RunAs -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'))
    exit
}
$Host.UI.RawUI.WindowTitle = 'GEEKOM XT12 Pro - macOS Tahoe + Golden Gate Builder'
$code = 1
try {
    # Downloaded ZIPs carry the "from the internet" mark; the builder's own scripts are ours, unblock them.
    Get-ChildItem -LiteralPath (Split-Path $PSScriptRoot) -Recurse -File | Unblock-File -ErrorAction SilentlyContinue

    $cache = $env:XT12_CACHE
    if (-not $cache) { $cache = Join-Path $env:LOCALAPPDATA 'RJ-XT12Pro-GoldenGate' }
    New-Item -ItemType Directory -Force -Path $cache | Out-Null
    $drive = Get-PSDrive -Name ([IO.Path]::GetPathRoot($cache).Substring(0, 1))
    Write-Host ('Cache: ' + $cache + '  (frei: ' + [math]::Round($drive.Free / 1GB, 1) + ' GB)')
    Write-Host 'Tipp: Mit wenig Platz auf C: einfach Option 1 nehmen - die grossen Dateien gehen dann direkt auf die Platte.'

    $url = 'https://github.com/nullmoth/1401/releases/download/v3.0/1401-Windows-3.0.0.zip'
    $expected = '29B5404AAF8A5A17FD9A3CE053DBEB5CBB1B497F6E5F672BAB0B567ED98E3867'
    $zip = Join-Path $cache '1401-Windows-3.0.0.zip'
    $engine = Join-Path $cache 'engine-1401-3.0.0'
    $okFile = Join-Path $engine 'xt12-ok.txt'
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'

    if (-not (Test-Path -LiteralPath $okFile)) {
        if (-not (Test-Path -LiteralPath $zip) -or (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ne $expected) {
            Write-Host 'Lade die 1401-Engine 3.0 (95 MB) von GitHub ...'
            $part = $zip + '.part'
            & $curl --fail --location --proto '=https' --proto-redir '=https' --connect-timeout 30 --retry 5 `
                --continue-at - --output $part $url
            if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 33) { throw "Download der 1401-Engine unterbrochen (curl $LASTEXITCODE). Erneut starten setzt fort." }
            if ((Get-FileHash -LiteralPath $part -Algorithm SHA256).Hash -ne $expected) {
                Remove-Item -LiteralPath $part -Force
                throw '1401-Engine hat eine falsche SHA-256-Pruefsumme. Bitte erneut starten.'
            }
            Move-Item -LiteralPath $part -Destination $zip -Force
        }
        if (Test-Path -LiteralPath $engine) { Remove-Item -LiteralPath $engine -Recurse -Force }
        Write-Host 'Entpacke die gepruefte 1401-Engine ...'
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::ExtractToDirectory($zip, $engine)
        Set-Content -LiteralPath $okFile -Value $expected -Encoding ASCII
    }
    $python = @(Get-ChildItem -LiteralPath $engine -Filter python.exe -File -Recurse | Where-Object {
        $_.Directory.Name -eq 'python' -and (Test-Path -LiteralPath (Join-Path $_.Directory.Parent.FullName 'app\p1401\__main__.py'))
    })
    if ($python.Count -ne 1) { Remove-Item -LiteralPath $okFile -Force; throw 'Die 1401-Engine ist unvollstaendig. Bitte erneut starten.' }
    $app = Join-Path $python[0].Directory.Parent.FullName 'app'
    Push-Location -LiteralPath $app
    try {
        & $python[0].FullName -E -s -B -X utf8 -u (Join-Path $PSScriptRoot 'XT12Builder.py') $cache
        $code = $LASTEXITCODE
    }
    finally { Pop-Location }
}
catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
}
finally {
    [void](Read-Host 'Enter zum Schliessen')
}
exit $code
