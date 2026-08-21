#Requires -Version 7.0
param(
    [Parameter(Mandatory = $true)] [string]$DistDir
)

$ErrorActionPreference = 'Stop'
$dist = (Resolve-Path $DistDir).Path
$installer = Get-ChildItem -Path $dist -Filter 'NPSunoUnifiedStudio-Setup-*.exe' -File | Select-Object -First 1
if ($null -eq $installer) { throw "Unified installer not found in $dist" }

function Wait-CheckedProcess {
    param([System.Diagnostics.Process]$Process,[int]$TimeoutSeconds,[string]$Label)
    if (-not $Process.WaitForExit($TimeoutSeconds * 1000)) {
        Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
        throw "$Label timed out after $TimeoutSeconds seconds."
    }
    if ($Process.ExitCode -ne 0) { throw "$Label failed with exit code $($Process.ExitCode)." }
}

$installDir = Join-Path $env:RUNNER_TEMP 'np-suno-functional-installed'
$userDir = Join-Path $env:RUNNER_TEMP 'np-suno-functional-user'
if (Test-Path $installDir) { Remove-Item $installDir -Recurse -Force }
if (Test-Path $userDir) { Remove-Item $userDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $userDir | Out-Null

Write-Host 'FUNCTIONAL INSTALL: installing a second clean copy...' -ForegroundColor Cyan
$args = @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-',"/DIR=$installDir",'/MERGETASKS=!desktopicon,!associate,!resetstate')
$p = Start-Process -FilePath $installer.FullName -ArgumentList $args -PassThru
Wait-CheckedProcess -Process $p -TimeoutSeconds 600 -Label 'Functional-test installer'

$engine = Join-Path $installDir 'SunoEngine'
$pythonw = Join-Path $engine 'python\pythonw.exe'
$server = Join-Path $engine 'app\server.py'
if (-not (Test-Path $pythonw) -or -not (Test-Path $server)) { throw 'Installed Suno runtime is incomplete.' }

$port = 18769
$env:SUNO_AUTO_OPEN = '0'
$env:SUNO_STUDIO_PORT = $port.ToString()
$env:SUNO_DISABLE_AUTO_UPDATE = '1'
$env:PYTHONUTF8 = '1'
$env:SUNO_STUDIO_USER_DIR = Join-Path $userDir 'Suno'
$env:SUNO_STUDIO_DATA_DIR = Join-Path $userDir 'Suno\data'
$env:SUNO_STUDIO_DOWNLOAD_DIR = Join-Path $userDir 'Suno\downloads'
$env:SUNO_STUDIO_EXPORT_DIR = Join-Path $userDir 'Suno\exports'
$env:SUNO_STUDIO_PUBLISHED_DIR = Join-Path $userDir 'Suno\published'
$env:SUNO_STUDIO_LIBRARY_DIR = Join-Path $userDir 'Suno\library'
$env:SUNO_STUDIO_RECOGNITION_DIR = Join-Path $userDir 'Suno\recognition'

$suno = Start-Process -FilePath $pythonw -ArgumentList $server -WorkingDirectory $engine -PassThru
try {
    $ready = $false
    for ($i=0; $i -lt 90; $i++) {
        Start-Sleep -Milliseconds 500
        $suno.Refresh()
        if ($suno.HasExited) { throw "Installed Suno exited early with code $($suno.ExitCode)." }
        try {
            $health = Invoke-RestMethod -Uri "http://127.0.0.1:$port/api/health" -TimeoutSec 2
            if ($health.ok) { $ready = $true; break }
        } catch {}
    }
    if (-not $ready) { throw 'Installed Suno did not become healthy for functional tests.' }

    pwsh -NoProfile -File (Join-Path $PSScriptRoot 'installed_functional_smoke.ps1') -InstallDir $installDir -SunoPort $port
    if ($LASTEXITCODE -ne 0) { throw 'Installed functional smoke script failed.' }

    try {
        Invoke-RestMethod -Uri "http://127.0.0.1:$port/api/shutdown" -Method Post -Body '{}' -ContentType 'application/json' -TimeoutSec 5 | Out-Null
    } catch {}
} finally {
    if (-not $suno.HasExited -and -not $suno.WaitForExit(5000)) {
        Stop-Process -Id $suno.Id -Force -ErrorAction SilentlyContinue
    }
}

$uninstaller = Get-ChildItem -Path $installDir -Filter 'unins*.exe' -File | Select-Object -First 1
if ($null -eq $uninstaller) { throw 'Functional-test install has no uninstaller.' }
$u = Start-Process -FilePath $uninstaller.FullName -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART') -PassThru
Wait-CheckedProcess -Process $u -TimeoutSeconds 180 -Label 'Functional-test uninstaller'

Write-Host 'FULL CLEAN-INSTALL FUNCTIONAL TEST PASSED.' -ForegroundColor Green
