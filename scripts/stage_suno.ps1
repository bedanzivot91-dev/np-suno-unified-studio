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

Push-Location (Join-Path $SunoRoot 'windows_build')
try {
    & (Join-Path $SunoRoot 'windows_build\normalize_setup_components.ps1')
    go vet ./...
    if ($LASTEXITCODE -ne 0) { throw 'go vet failed' }
    $setupExe = Join-Path $env:RUNNER_TEMP 'unified-suno-stage.exe'
    go build -ldflags="-H windowsgui" -o $setupExe ./setup
    if ($LASTEXITCODE -ne 0) { throw 'Suno setup build failed' }
} finally { Pop-Location }

$proc = Start-Process -FilePath $setupExe -ArgumentList @('--stage-components', $OutputDir) -Wait -PassThru -NoNewWindow
if ($proc.ExitCode -ne 0) { throw "Suno --stage-components failed with exit code $($proc.ExitCode)" }

Copy-Item -Recurse -Force (Join-Path $SunoRoot 'app') (Join-Path $OutputDir 'app')
Copy-Item -Recurse -Force (Join-Path $SunoRoot 'plugins') (Join-Path $OutputDir 'plugins')
Copy-Item -Force (Join-Path $SunoRoot 'requirements-core.txt') (Join-Path $OutputDir 'requirements-core.txt')
Copy-Item -Force (Join-Path $SunoRoot 'requirements-ai.txt') (Join-Path $OutputDir 'requirements-ai.txt')
Get-ChildItem -Recurse -Directory -Filter '__pycache__' (Join-Path $OutputDir 'app'), (Join-Path $OutputDir 'plugins') -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force

# Unified copy must not auto-update itself from the standalone Suno release branch.
$serverCore = Join-Path $OutputDir 'app\server_core.py'
$serverText = Get-Content $serverCore -Raw -Encoding UTF8
$pattern = '(?m)^    UPDATE_STOP\.clear\(\)\r?$' + "`n" + '^    UPDATE_THREAD = threading\.Thread\(target=update_check_loop, daemon=True, name="auto-update-check"\)\r?$' + "`n" + '^    UPDATE_THREAD\.start\(\)\r?$'
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

# Embedded CPython's ._pth isolated mode ignores PYTHONPATH. The original Suno launchers use
# PYTHONPATH for per-plugin environments, so patch ONLY the staged unified worker copies to put
# their adjacent env folders on sys.path explicitly. This makes the actual workers functional.
$workerPatches = @(
    @{ Path = (Join-Path $OutputDir 'plugins\transcribe_worker.py'); Env = 'transcription_env' },
    @{ Path = (Join-Path $OutputDir 'plugins\stems_worker.py'); Env = 'stems_env' }
)
foreach ($patch in $workerPatches) {
    $workerText = Get-Content $patch.Path -Raw -Encoding UTF8
    $needle = "from pathlib import Path`n"
    if (-not $workerText.Contains($needle)) { $needle = "from pathlib import Path`r`n" }
    if (-not $workerText.Contains($needle)) { throw "Worker patch anchor missing: $($patch.Path)" }
    $lineEnd = if ($needle.Contains("`r`n")) { "`r`n" } else { "`n" }
    $insert = "from pathlib import Path$lineEnd$lineEnd_PLUGIN_ENV = Path(__file__).resolve().with_name('$($patch.Env)')$lineEndif _PLUGIN_ENV.is_dir():$lineEnd    sys.path.insert(0, str(_PLUGIN_ENV))$lineEnd"
    $workerText = $workerText.Replace($needle, $insert)
    Set-Content -Path $patch.Path -Value $workerText -Encoding UTF8 -NoNewline
}

# Keep the full FFmpeg staged and verified by original Suno setup.
$stagedFfmpeg = Join-Path $OutputDir 'tools\ffmpeg\bin\ffmpeg.exe'
$stagedFfprobe = Join-Path $OutputDir 'tools\ffmpeg\bin\ffprobe.exe'
if (-not (Test-Path $stagedFfmpeg) -or -not (Test-Path $stagedFfprobe)) { throw 'Original Suno staging did not produce FFmpeg/ffprobe.' }
$muxers = & $stagedFfmpeg -hide_banner -muxers 2>&1 | Out-String
if ($LASTEXITCODE -ne 0 -or $muxers -notmatch '(?i)chromaprint') { throw 'Staged Suno FFmpeg lacks Chromaprint muxer.' }

# Real Chromaprint binary, never Chocolatey shim.
$chromaprintDir = Join-Path $OutputDir 'plugins\chromaprint'
New-Item -ItemType Directory -Force -Path $chromaprintDir | Out-Null
$fpZip = Join-Path $env:RUNNER_TEMP 'chromaprint-fpcalc-1.5.1-windows-x86_64.zip'
$fpExtract = Join-Path $env:RUNNER_TEMP 'chromaprint-fpcalc-real'
if (Test-Path $fpExtract) { Remove-Item $fpExtract -Recurse -Force }
Invoke-WebRequest -Uri 'https://github.com/acoustid/chromaprint/releases/download/v1.5.1/chromaprint-fpcalc-1.5.1-windows-x86_64.zip' -OutFile $fpZip -UseBasicParsing
Expand-Archive -Path $fpZip -DestinationPath $fpExtract -Force
$realFpcalc = Get-ChildItem -Path $fpExtract -Filter 'fpcalc.exe' -Recurse -File | Where-Object { $_.Length -gt 100000 } | Select-Object -First 1
if ($null -eq $realFpcalc) { throw 'Real fpcalc.exe not found in official Chromaprint archive.' }
Copy-Item -Force $realFpcalc.FullName (Join-Path $chromaprintDir 'fpcalc.exe')
& (Join-Path $chromaprintDir 'fpcalc.exe') -version
if ($LASTEXITCODE -ne 0) { throw 'Bundled real Suno fpcalc failed version test.' }
Remove-Item $fpZip, $fpExtract -Recurse -Force -ErrorAction SilentlyContinue

# Core Python packages.
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

# Exact optional AI dependency sets in the locations expected by original plugin_status().
$transcriptionEnv = Join-Path $OutputDir 'plugins\transcription_env'
$stemsEnv = Join-Path $OutputDir 'plugins\stems_env'
New-Item -ItemType Directory -Force -Path $transcriptionEnv, $stemsEnv | Out-Null
& $py -m pip install --no-warn-script-location --disable-pip-version-check --target $transcriptionEnv 'faster-whisper==1.2.1' 'ctranslate2==4.8.1'
if ($LASTEXITCODE -ne 0) { throw 'Suno transcription AI dependencies failed to install.' }
& $py -m pip install --no-warn-script-location --disable-pip-version-check --target $stemsEnv 'audio-separator[cpu]==0.44.5'
if ($LASTEXITCODE -ne 0) { throw 'Suno stem-separation AI dependencies failed to install.' }

# Explicit sys.path mirrors the worker patch and works under CPython ._pth isolation.
& $py -c "import sys; sys.path.insert(0, sys.argv[1]); import faster_whisper, ctranslate2; print('TRANSCRIPTION_AI_OK')" $transcriptionEnv
if ($LASTEXITCODE -ne 0) { throw 'Bundled Suno transcription AI import test failed.' }
& $py -c "import sys; sys.path.insert(0, sys.argv[1]); import audio_separator; from audio_separator.separator import Separator; print('STEMS_AI_OK')" $stemsEnv
if ($LASTEXITCODE -ne 0) { throw 'Bundled Suno stem-separation AI import test failed.' }

# Prove the actual staged worker files see their own env without PYTHONPATH.
$workerProbe = @'
import runpy, sys
from pathlib import Path
for name, env, mods in [
    ('transcribe_worker.py','transcription_env',('faster_whisper','ctranslate2')),
    ('stems_worker.py','stems_env',('audio_separator',)),
]:
    worker = Path(sys.argv[1]) / 'plugins' / name
    text = worker.read_text(encoding='utf-8-sig')
    ns = {'__file__': str(worker), '__name__': 'unified_worker_probe'}
    exec(compile(text, str(worker), 'exec'), ns, ns)
    for mod in mods:
        __import__(mod)
    for mod in mods:
        sys.modules.pop(mod, None)
    sys.path[:] = [p for p in sys.path if env not in p]
print('WORKER_ENV_IMPORTS_OK')
'@
$probeFile = Join-Path $env:RUNNER_TEMP 'probe_unified_workers.py'
Set-Content $probeFile $workerProbe -Encoding UTF8
& $py $probeFile $OutputDir
if ($LASTEXITCODE -ne 0) { throw 'Actual staged Suno worker environment probe failed.' }
Remove-Item $probeFile -Force

# Real server health and feature status.
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
        try { $r = Invoke-RestMethod -Uri 'http://127.0.0.1:18766/api/health' -TimeoutSec 2; if ($r.ok) { $ok = $true; break } } catch {}
    }
    if (-not $ok) { throw 'Staged Suno server did not become healthy.' }
    $advanced = Invoke-RestMethod -Uri 'http://127.0.0.1:18766/api/advanced/status' -TimeoutSec 10
    foreach ($component in @('stems','transcription','chromaprint')) {
        $state = $advanced.plugins.$component
        if ($null -eq $state -or -not $state.installed) { throw "Staged Suno advanced component not installed: $component" }
    }
    $v3 = Invoke-RestMethod -Uri 'http://127.0.0.1:18766/api/v3/status' -TimeoutSec 15
    if (-not $v3.preflight.ok) { throw "Suno v3 preflight blocked: $($v3.preflight | ConvertTo-Json -Depth 8 -Compress)" }
    Invoke-RestMethod -Uri 'http://127.0.0.1:18766/api/shutdown' -Method Post -Body '{}' -ContentType 'application/json' -TimeoutSec 5 | Out-Null
} finally {
    Start-Sleep -Milliseconds 500
    if (-not $p.HasExited) { $p.Kill() }
}
Write-Host "SunoEngine staged and runtime-tested successfully: $OutputDir"
