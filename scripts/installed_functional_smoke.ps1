#Requires -Version 7.0
param(
    [Parameter(Mandatory = $true)] [string]$InstallDir,
    [Parameter(Mandatory = $true)] [int]$SunoPort
)

$ErrorActionPreference = 'Stop'
$InstallDir = (Resolve-Path $InstallDir).Path
$temp = Join-Path $env:RUNNER_TEMP 'np-suno-installed-functional-smoke'
if (Test-Path $temp) { Remove-Item $temp -Recurse -Force }
New-Item -ItemType Directory -Force -Path $temp | Out-Null

function Require-File([string]$Path, [string]$Label) {
    if (-not (Test-Path $Path -PathType Leaf) -or (Get-Item $Path).Length -eq 0) { throw "$Label is missing or empty: $Path" }
}

Write-Host '[FUNCTIONAL 1/8] FFmpeg -> real audio generation' -ForegroundColor Cyan
$ffmpeg = Join-Path $InstallDir 'Tools\ffmpeg\ffmpeg.exe'
$ffprobe = Join-Path $InstallDir 'Tools\ffmpeg\ffprobe.exe'
Require-File $ffmpeg 'NP FFmpeg'; Require-File $ffprobe 'NP FFprobe'
$wav = Join-Path $temp 'tone.wav'
& $ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'sine=frequency=440:duration=2' -ac 1 -ar 44100 $wav
if ($LASTEXITCODE -ne 0) { throw 'Installed NP FFmpeg could not generate a WAV file.' }
Require-File $wav 'Generated WAV'
Write-Host '[FUNCTIONAL 1/8] FFmpeg generated real audio.' -ForegroundColor Green

Write-Host '[FUNCTIONAL 2/8] FFprobe -> real media probe' -ForegroundColor Cyan
$durationRaw = (& $ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 $wav | Out-String).Trim()
$duration = 0.0
if (-not [double]::TryParse($durationRaw,[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$duration)) { throw "Invalid FFprobe duration: $durationRaw" }
if ($duration -lt 1.5 -or $duration -gt 2.5) { throw "Unexpected FFprobe duration: $duration" }
Write-Host "[FUNCTIONAL 2/8] FFprobe duration=$duration seconds." -ForegroundColor Green

Write-Host '[FUNCTIONAL 3/8] Chromaprint/fpcalc -> real fingerprint' -ForegroundColor Cyan
$fpcalc = Join-Path $InstallDir 'Tools\fpcalc\fpcalc.exe'
Require-File $fpcalc 'NP fpcalc'
$fpOutput = (& $fpcalc $wav 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0 -or $fpOutput -notmatch 'FINGERPRINT=') { throw "Installed NP fpcalc failed: $fpOutput" }
Write-Host '[FUNCTIONAL 3/8] fpcalc produced a real fingerprint.' -ForegroundColor Green

Write-Host '[FUNCTIONAL 4/8] Tesseract -> real OCR' -ForegroundColor Cyan
$tesseract = Join-Path $InstallDir 'Tools\tesseract\tesseract.exe'
Require-File $tesseract 'NP Tesseract'
$ocrImage = Join-Path $temp 'ocr-test.png'
try { Add-Type -AssemblyName System.Drawing.Common -ErrorAction Stop } catch { Add-Type -AssemblyName System.Drawing -ErrorAction Stop }
$bitmap = New-Object System.Drawing.Bitmap 900,220
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
try {
    $graphics.Clear([System.Drawing.Color]::White)
    $font = New-Object System.Drawing.Font('Arial',72,[System.Drawing.FontStyle]::Bold,[System.Drawing.GraphicsUnit]::Pixel)
    try { $graphics.DrawString('TEST 123',$font,[System.Drawing.Brushes]::Black,30,55) } finally { $font.Dispose() }
    $bitmap.Save($ocrImage,[System.Drawing.Imaging.ImageFormat]::Png)
} finally { $graphics.Dispose(); $bitmap.Dispose() }
$ocrText = (& $tesseract $ocrImage stdout --psm 7 -l eng 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $ocrText -notmatch '(?i)TEST' -or $ocrText -notmatch '123') { throw "Installed Tesseract OCR failed: $ocrText" }
Write-Host "[FUNCTIONAL 4/8] OCR output: $ocrText" -ForegroundColor Green

Write-Host '[FUNCTIONAL 5/8] yt-dlp executable' -ForegroundColor Cyan
$ytdlp = Join-Path $InstallDir 'Tools\yt-dlp\yt-dlp.exe'
Require-File $ytdlp 'NP yt-dlp'
$ytVersion = (& $ytdlp --version 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($ytVersion)) { throw 'Installed yt-dlp did not execute successfully.' }
Write-Host "[FUNCTIONAL 5/8] yt-dlp version $ytVersion." -ForegroundColor Green

Write-Host '[FUNCTIONAL 6/8] Installed Suno AI + actual worker import path' -ForegroundColor Cyan
$engine = Join-Path $InstallDir 'SunoEngine'
$python = Join-Path $engine 'python\python.exe'
Require-File $python 'Installed Suno Python'
$transcriptionEnv = Join-Path $engine 'plugins\transcription_env'
$stemsEnv = Join-Path $engine 'plugins\stems_env'
& $python -c "import sys; sys.path.insert(0, sys.argv[1]); import faster_whisper, ctranslate2; print('installed transcription AI OK')" $transcriptionEnv
if ($LASTEXITCODE -ne 0) { throw 'Installed Suno transcription AI import failed.' }
& $python -c "import sys; sys.path.insert(0, sys.argv[1]); import audio_separator; from audio_separator.separator import Separator; print('installed stems AI OK')" $stemsEnv
if ($LASTEXITCODE -ne 0) { throw 'Installed Suno stems AI import failed.' }

# Execute both installed worker modules under embedded Python isolation. Their staged unified patches
# must add the adjacent env directory to sys.path without relying on PYTHONPATH.
$probe = @'
import sys
from pathlib import Path
root=Path(sys.argv[1])
for name, env, mods in [('transcribe_worker.py','transcription_env',('faster_whisper','ctranslate2')),('stems_worker.py','stems_env',('audio_separator',))]:
    worker=root/'plugins'/name
    ns={'__file__':str(worker),'__name__':'installed_worker_probe'}
    exec(compile(worker.read_text(encoding='utf-8-sig'),str(worker),'exec'),ns,ns)
    for mod in mods: __import__(mod)
    for mod in mods: sys.modules.pop(mod,None)
    sys.path[:]=[p for p in sys.path if env not in p]
print('INSTALLED_WORKERS_IMPORT_OK')
'@
$probeFile = Join-Path $temp 'probe_workers.py'
Set-Content $probeFile $probe -Encoding UTF8
& $python $probeFile $engine
if ($LASTEXITCODE -ne 0) { throw 'Installed Suno worker import-path probe failed.' }
Write-Host '[FUNCTIONAL 6/8] Both AI envs and both installed worker modules load correctly.' -ForegroundColor Green

Write-Host '[FUNCTIONAL 7/8] Installed Suno advanced/v3 API status' -ForegroundColor Cyan
$base = "http://127.0.0.1:$SunoPort"
$advanced = Invoke-RestMethod -Uri "$base/api/advanced/status" -TimeoutSec 15
if (-not $advanced.ok) { throw 'Installed Suno /api/advanced/status returned ok=false.' }
foreach ($component in @('stems','transcription','chromaprint')) {
    $state = $advanced.plugins.$component
    if ($null -eq $state -or -not $state.installed) { throw "Installed Suno reports component unavailable: $component" }
}
$v3 = Invoke-RestMethod -Uri "$base/api/v3/status" -TimeoutSec 20
if (-not $v3.ok -or -not $v3.preflight.ok) { throw "Installed Suno v3 preflight blocked: $($v3.preflight | ConvertTo-Json -Depth 8 -Compress)" }
Write-Host "[FUNCTIONAL 7/8] Suno advanced components ready; v3 preflight=$($v3.preflight.readiness)." -ForegroundColor Green

Write-Host '[FUNCTIONAL 8/8] Installed Suno web application delivery' -ForegroundColor Cyan
$web = Invoke-WebRequest -Uri "$base/" -UseBasicParsing -TimeoutSec 15
if ($web.StatusCode -ne 200 -or [string]::IsNullOrWhiteSpace($web.Content) -or $web.Content.Length -lt 1000) { throw 'Installed Suno web application was not served correctly.' }
Write-Host "[FUNCTIONAL 8/8] Suno UI served successfully ($($web.Content.Length) chars)." -ForegroundColor Green
Write-Host 'INSTALLED FUNCTIONAL SMOKE PASSED.' -ForegroundColor Green
