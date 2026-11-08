# Builds the Windows host and assembles dist\Flow2Studio-windows\ (exe + ui\ + firmware\).
# Usage: powershell -ExecutionPolicy Bypass -File scripts\build-windows.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$output = Join-Path $root 'dist\Flow2Studio-windows'
$publish = Join-Path $root 'windows\bin\publish'

if (Test-Path $output) { Remove-Item -Recurse -Force $output }
if (Test-Path $publish) { Remove-Item -Recurse -Force $publish }

Write-Host 'Building Flow2Studio for Windows...'
dotnet publish (Join-Path $root 'windows\Flow2Studio.csproj') -c Release -r win-x64 --self-contained true `
    -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:DebugType=none -o $publish
if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed ($LASTEXITCODE)" }

New-Item -ItemType Directory -Force $output | Out-Null
Copy-Item (Join-Path $publish 'Flow2Studio.exe') $output
Get-ChildItem $publish -Filter *.dll | Copy-Item -Destination $output
# The web UI and firmware images are shared with the mac build and copied unchanged.
Copy-Item -Recurse (Join-Path $root 'resources') (Join-Path $output 'ui')
Copy-Item -Recurse (Join-Path $root 'firmware-bundle') (Join-Path $output 'firmware')
# Catalogs are SHA-256 pinned with LF endings; a core.autocrlf checkout rewrites them as CRLF.
# Restore the committed bytes in the copy only. The app still refuses any catalog whose hash differs.
foreach ($catalog in Get-ChildItem (Join-Path $output 'firmware') -Filter *.json) {
    $text = [IO.File]::ReadAllText($catalog.FullName, [Text.Encoding]::UTF8)
    [IO.File]::WriteAllText($catalog.FullName, $text.Replace("`r`n", "`n"), (New-Object Text.UTF8Encoding $false))
}

# Offline self-check of the ported protocol logic and the bundled firmware catalogs (no device access).
$check = Start-Process -FilePath (Join-Path $output 'Flow2Studio.exe') -ArgumentList '--self-check' -Wait -PassThru -NoNewWindow
if ($check.ExitCode -ne 0) { throw "Self-check failed ($($check.ExitCode))" }
Write-Host "Done: $output"
