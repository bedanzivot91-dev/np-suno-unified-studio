param(
    [Parameter(Mandatory=$true)][string]$SunoRoot,
    [Parameter(Mandatory=$true)][string]$OutputDir
)

$ErrorActionPreference = 'Stop'
$SunoRoot = (Resolve-Path $SunoRoot).Path
$OutputDir = [System.IO.Path]::GetFullPath($OutputDir)
if (Test-Path $OutputDir) { Remove-Item $OutputDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

Write-Host "Staging pinned Suno source from $SunoRoot"

# Use the original Suno setup's own component staging logic, but only in this temporary checkout.
Push-Location (Join-Path $SunoRoot 'windows_build')
try {
    & (Join-Path $SunoRoot 'windows_build\normalize_setup_components.ps1')
    go vet ./...
    if ($LASTEXITCODE -ne 0) { throw 'go vet failed' }
    $setupExe = Join-Path $env:RUNNER_TEMP 'unified-suno-stage.exe'
    go build -ldflags="-H windowsgui" -o $setupExe ./setup
    if ($LASTEXITCODE -ne 0) { throw 'Suno setup build failed' }
} finally {
    Pop-Location
}

$proc = Start-Process -FilePath $setupExe -ArgumentList @('--stage-components', $OutputDir) -Wait -PassThru -NoNewWindow
if ($proc.ExitCode -ne 0) { throw "Suno --stage-components failed with exit code $($proc.ExitCode)" }

Copy-Item -Recurse -Force (Join-Path $SunoRoot 'app') (Join-Path $OutputDir 'app')
Copy-Item -Recurse -Force (Join-Path $SunoRoot 'plugins') (Join-Path $OutputDir 'plugins')
Copy-Item -Force (Join-Path $SunoRoot 'requirements-core.txt') (Join-Path $OutputDir 'requirements-core.txt')
Get-ChildItem -Recurse -Directory -Filter '__pycache__' (Join-Path $OutputDir 'app'), (Join-Path $OutputDir 'plugins') -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force

# Unified copy must not auto-update itself from the standalone Suno release branch.
$serverCore = Join-Path $OutputDir 'app\server_core.py'
$serverText = Get-Content $serverCore -Raw -Encoding UTF8
$pattern = '(?m)^    UPDATE_STOP\.clear\(\)\r?$' + "`n" +
           '^    UPDATE_THREAD = threading\.Thread\(target=update_check_loop, daemon=True, name="auto-update-check"\)\r?$' + "`n" +
           '^    UPDATE_THREAD\.start\(\)\r?$'
$replacement = @'
    UPDATE_STOP.clear()
    if os.environ.get("SUNO_DISABLE_AUTO_UPDATE", "0") != "1":
        UPDATE_THREAD = threading.Thread(target=update_check_loop, daemon=True, name="auto-update-check")
        UPDATE_THREAD.start()
    else:
        UPDATE_THREAD = None
'@
$matches = [regex]::Matches($serverText, $pattern)
if ($matches.Count -ne 1) { throw "Expected exactly one Suno update-thread block, found $($matches.Count)." }
$serverText = [regex]::Replace($serverText, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $replacement }, 1)
Set-Content -Path $serverCore -Value $serverText -Encoding UTF8 -NoNewline

# Reuse the real FFmpeg/ffprobe installed for the NP build and mirror Suno's expected tools layout.
$ffmpeg = (Get-Command ffmpeg.exe -ErrorAction Stop).Source
$ffprobe = (Get-Command ffprobe.exe -ErrorAction Stop).Source
$ffDir = Join-Path $OutputDir 'tools\ffmpeg\bin'
New-Item -ItemType Directory -Force -Path $ffDir | Out-Null
Copy-Item -Force $ffmpeg (Join-Path $ffDir 'ffmpeg.exe')
Copy-Item -Force $ffprobe (Join-Path $ffDir 'ffprobe.exe')

# Install the exact core Python dependency list into Suno's staged embeddable interpreter.
$py = Join-Path $OutputDir 'python\python.exe'
$pyw = Join-Path $OutputDir 'python\pythonw.exe'
if (-not (Test-Path $py) -or -not (Test-Path $pyw)) { throw 'Embeddable Python was not staged.' }
$pth = Get-ChildItem (Join-Path $OutputDir 'python\*._pth') | Select-Object -First 1
(Get-Content $pth.FullName) -replace '^#\s*import site', 'import site' | Set-Content $pth.FullName
$getPip = Join-Path $OutputDir 'python\get-pip.py'
Invoke-WebRequest -Uri 'https://bootstrap.pypa.io/get-pip.py' -OutFile $getPip
& $py $getPip --no-warn-script-location
if ($LASTEXITCODE -ne 0) { throw 'get-pip bootstrap failed' }
Remove-Item $getPip -Force
& $py -m pip install --no-warn-script-location -r (Join-Path $SunoRoot 'requirements-core.txt')
if ($LASTEXITCODE -ne 0) { throw 'pip install into embedded Suno Python failed' }

# Real health check using the SAME pythonw + server.py path that the unified app will use.
$healthRoot = Join-Path $env:RUNNER_TEMP 'np-suno-unified-health'
if (Test-Path $healthRoot) { Remove-Item $healthRoot -Recurse -Force }
$env:SUNO_STUDIO_USER_DIR = $healthRoot
$env:SUNO_STUDIO_DATA_DIR = Join-Path $healthRoot 'data'
$env:SUNO_STUDIO_DOWNLOAD_DIR = Join-Path $healthRoot 'downloads'
$env:SUNO_STUDIO_EXPORT_DIR = Join-Path $healthRoot 'exports'
$env:SUNO_STUDIO_PUBLISHED_DIR = Join-Path $healthRoot 'published'
$env:SUNO_STUDIO_LIBRARY_DIR = Join-Path $healthRoot 'library'
$env:SUNO_STUDIO_RECOGNITION_DIR = Join-Path $healthRoot 'recognition'
$env:SUNO_STUDIO_PORT = '18766'
$env:SUNO_AUTO_OPEN = '0'
$env:SUNO_DISABLE_AUTO_UPDATE = '1'
$env:PYTHONUTF8 = '1'
$server = Join-Path $OutputDir 'app\server.py'
$p = Start-Process -FilePath $pyw -ArgumentList @($server) -PassThru -NoNewWindow
$ok = $false
try {
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Milliseconds 500
        try {
            $r = Invoke-RestMethod -Uri 'http://127.0.0.1:18766/api/health' -TimeoutSec 2
            if ($r.ok) { $ok = $true; break }
        } catch {}
    }
    if (-not $ok) { throw 'Staged Suno server did not become healthy.' }
    Invoke-RestMethod -Uri 'http://127.0.0.1:18766/api/shutdown' -Method Post -Body '{}' -ContentType 'application/json' -TimeoutSec 5 | Out-Null
} finally {
    Start-Sleep -Milliseconds 500
    if (-not $p.HasExited) { $p.Kill() }
}

Write-Host "SunoEngine staged and health-tested successfully: $OutputDir"
