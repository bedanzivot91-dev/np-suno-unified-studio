#Requires -Version 7.0
param(
    [Parameter(Mandatory = $true)]
    [string]$DistDir
)

$ErrorActionPreference = 'Stop'
$dist = (Resolve-Path $DistDir).Path
$installer = Get-ChildItem -Path $dist -Filter 'NPSunoUnifiedStudio-Setup-*.exe' -File | Select-Object -First 1
if ($null -eq $installer) {
    throw "Unified installer was not found in $dist"
}

function Wait-ProcessOrFail {
    param(
        [Parameter(Mandatory = $true)] [System.Diagnostics.Process]$Process,
        [Parameter(Mandatory = $true)] [int]$TimeoutSeconds,
        [Parameter(Mandatory = $true)] [string]$Label,
        [string]$LogFile = ''
    )

    if (-not $Process.WaitForExit($TimeoutSeconds * 1000)) {
        try { Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue } catch {}
        if ($LogFile -and (Test-Path $LogFile)) {
            Write-Host "--- $Label log tail ---"
            Get-Content $LogFile -Tail 250
        }
        throw "$Label timed out after $TimeoutSeconds seconds."
    }
    if ($Process.ExitCode -ne 0) {
        if ($LogFile -and (Test-Path $LogFile)) {
            Write-Host "--- $Label log tail ---"
            Get-Content $LogFile -Tail 250
        }
        throw "$Label failed with exit code $($Process.ExitCode)."
    }
}

$installDir = Join-Path $env:RUNNER_TEMP 'np-suno-unified-installed'
$userDir = Join-Path $env:RUNNER_TEMP 'np-suno-unified-smoke-user'
$installerLog = Join-Path $env:RUNNER_TEMP 'np-suno-unified-install.log'
$uninstallerLog = Join-Path $env:RUNNER_TEMP 'np-suno-unified-uninstall.log'
if (Test-Path $installDir) { Remove-Item $installDir -Recurse -Force }
if (Test-Path $userDir) { Remove-Item $userDir -Recurse -Force }
Remove-Item $installerLog, $uninstallerLog -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $userDir | Out-Null

Write-Host '[1/5] Running the real Inno Setup installer...' -ForegroundColor Cyan
Write-Host "Installer: $($installer.FullName)"
Write-Host "Target:    $installDir"
$installArgs = @(
    '/VERYSILENT',
    '/SUPPRESSMSGBOXES',
    '/NORESTART',
    '/SP-',
    "/DIR=$installDir",
    "/LOG=$installerLog",
    '/MERGETASKS=!desktopicon,!associate,!resetstate'
)
$installProcess = Start-Process -FilePath $installer.FullName -ArgumentList $installArgs -PassThru
Wait-ProcessOrFail -Process $installProcess -TimeoutSeconds 300 -Label 'Unified installer' -LogFile $installerLog
Write-Host '[1/5] Installer completed successfully.' -ForegroundColor Green

Write-Host '[2/5] Verifying the installed payload...' -ForegroundColor Cyan
$required = @(
    'NPVideoStudio.exe',
    'SunoEngine\python\pythonw.exe',
    'SunoEngine\app\server.py',
    'SunoEngine\app\server_core.py',
    'SunoEngine\app\web\index.html',
    'Tools\ffmpeg\ffmpeg.exe',
    'Tools\ffmpeg\ffprobe.exe',
    'Tools\yt-dlp\yt-dlp.exe',
    'Tools\fpcalc\fpcalc.exe',
    'Tools\tesseract\tesseract.exe',
    'Tools\whisper-models\ggml-tiny.bin'
)
foreach ($rel in $required) {
    $path = Join-Path $installDir $rel
    if (-not (Test-Path $path -PathType Leaf)) {
        throw "Installed unified program is incomplete. Missing: $rel"
    }
    if ((Get-Item $path).Length -eq 0) {
        throw "Installed unified file is empty: $rel"
    }
}
Write-Host '[2/5] Required NP + Suno files are physically installed.' -ForegroundColor Green

Write-Host '[3/5] Starting the Suno backend from the INSTALLED directory...' -ForegroundColor Cyan
$engineRoot = Join-Path $installDir 'SunoEngine'
$pythonw = Join-Path $engineRoot 'python\pythonw.exe'
$server = Join-Path $engineRoot 'app\server.py'
$healthPort = 18768
$healthUri = "http://127.0.0.1:$healthPort/api/health"
$env:SUNO_AUTO_OPEN = '0'
$env:SUNO_STUDIO_PORT = $healthPort.ToString()
$env:SUNO_DISABLE_AUTO_UPDATE = '1'
$env:PYTHONUTF8 = '1'
$env:SUNO_STUDIO_USER_DIR = Join-Path $userDir 'Suno'
$env:SUNO_STUDIO_DATA_DIR = Join-Path $userDir 'Suno\data'
$env:SUNO_STUDIO_DOWNLOAD_DIR = Join-Path $userDir 'Suno\Preuzete_pesme'
$env:SUNO_STUDIO_EXPORT_DIR = Join-Path $userDir 'Suno\Izvoz'
$env:SUNO_STUDIO_PUBLISHED_DIR = Join-Path $userDir 'Suno\OBRADJENO_NA_YOUTUBE'
$env:SUNO_STUDIO_LIBRARY_DIR = Join-Path $userDir 'Suno\Biblioteka_pesama'
$env:SUNO_STUDIO_RECOGNITION_DIR = Join-Path $userDir 'Suno\Pronalazac_pesme'

$sunoProcess = Start-Process -FilePath $pythonw -ArgumentList $server -WorkingDirectory $engineRoot -PassThru
try {
    $healthy = $false
    for ($i = 0; $i -lt 60; $i++) {
        $sunoProcess.Refresh()
        if ($sunoProcess.HasExited) {
            throw "Installed Suno backend exited early with code $($sunoProcess.ExitCode)."
        }
        try {
            $response = Invoke-WebRequest -Uri $healthUri -UseBasicParsing -TimeoutSec 2
            if ($response.StatusCode -eq 200) {
                $healthy = $true
                break
            }
        } catch {
            Start-Sleep -Milliseconds 500
        }
    }
    if (-not $healthy) {
        throw 'Installed Suno backend did not become healthy.'
    }
    Write-Host '[3/5] Installed Suno backend health check passed.' -ForegroundColor Green

    try {
        Invoke-WebRequest -Uri "http://127.0.0.1:$healthPort/api/shutdown" -Method Post -ContentType 'application/json' -Body '{}' -UseBasicParsing -TimeoutSec 3 | Out-Null
    } catch {
        Write-Warning "Suno shutdown endpoint returned an error: $_"
    }
} finally {
    if (-not $sunoProcess.HasExited) {
        if (-not $sunoProcess.WaitForExit(5000)) {
            Stop-Process -Id $sunoProcess.Id -Force -ErrorAction SilentlyContinue
        }
    }
}

Write-Host '[4/5] Starting the INSTALLED GUI and checking Windows responsiveness...' -ForegroundColor Cyan
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class NpSunoSmokeNative
{
    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr SendMessageTimeout(
        IntPtr hWnd,
        uint Msg,
        IntPtr wParam,
        IntPtr lParam,
        uint flags,
        uint timeout,
        out IntPtr result);
}
"@

$appExe = Join-Path $installDir 'NPVideoStudio.exe'
$appProcess = Start-Process -FilePath $appExe -WorkingDirectory $installDir -PassThru
try {
    $windowHandle = [IntPtr]::Zero
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Milliseconds 500
        $appProcess.Refresh()
        if ($appProcess.HasExited) {
            $crashCandidates = @(
                (Join-Path $env:LOCALAPPDATA 'NP Suno Unified Studio\Logs\crash.log'),
                (Join-Path $env:LOCALAPPDATA 'NP Suno Unified Studio\Logs')
            )
            Write-Host "GUI exited early with code $($appProcess.ExitCode)."
            foreach ($candidate in $crashCandidates) {
                if (Test-Path $candidate) {
                    if ((Get-Item $candidate).PSIsContainer) {
                        Get-ChildItem $candidate -File | ForEach-Object { Write-Host "--- $($_.FullName) ---"; Get-Content $_.FullName -Tail 200 }
                    } else {
                        Get-Content $candidate -Tail 200
                    }
                }
            }
            throw "Installed GUI exited before a main window was ready (code $($appProcess.ExitCode))."
        }
        if ($appProcess.MainWindowHandle -ne 0) {
            $windowHandle = [IntPtr]$appProcess.MainWindowHandle
            break
        }
    }

    if ($windowHandle -eq [IntPtr]::Zero) {
        throw 'Installed GUI did not create a top-level window within 30 seconds.'
    }

    $result = [IntPtr]::Zero
    $SMTO_ABORTIFHUNG = 0x0002
    $sendResult = [NpSunoSmokeNative]::SendMessageTimeout(
        $windowHandle,
        0,
        [IntPtr]::Zero,
        [IntPtr]::Zero,
        $SMTO_ABORTIFHUNG,
        5000,
        [ref]$result)
    if ($sendResult -eq [IntPtr]::Zero) {
        throw 'Installed GUI main window is not responding to Windows messages.'
    }
    Write-Host '[4/5] Installed GUI created a responsive Windows window.' -ForegroundColor Green
} finally {
    if (-not $appProcess.HasExited) {
        $null = $appProcess.CloseMainWindow()
        if (-not $appProcess.WaitForExit(10000)) {
            Stop-Process -Id $appProcess.Id -Force -ErrorAction SilentlyContinue
        }
    }
}

Write-Host '[5/5] Running the real uninstaller...' -ForegroundColor Cyan
$uninstaller = Get-ChildItem -Path $installDir -Filter 'unins*.exe' -File | Select-Object -First 1
if ($null -eq $uninstaller) {
    throw 'Installer did not create an uninstaller.'
}
$uninstallArgs = @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART',"/LOG=$uninstallerLog")
$uninstallProcess = Start-Process -FilePath $uninstaller.FullName -ArgumentList $uninstallArgs -PassThru
Wait-ProcessOrFail -Process $uninstallProcess -TimeoutSeconds 120 -Label 'Unified uninstaller' -LogFile $uninstallerLog
Write-Host '[5/5] Uninstaller completed successfully.' -ForegroundColor Green
Write-Host 'INSTALL + INSTALLED PAYLOAD + INSTALLED SUNO + RESPONSIVE GUI + UNINSTALL smoke test PASSED.' -ForegroundColor Green
