from __future__ import annotations

import sys
from pathlib import Path

if len(sys.argv) != 2:
    raise SystemExit("Usage: apply_runtime_fixes.py <np-source-root>")

root = Path(sys.argv[1]).resolve()


def patch_once(rel: str, old: str, new: str) -> None:
    path = root / rel
    text = path.read_text(encoding="utf-8")
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{rel}: expected exactly one match for runtime isolation patch, found {count}")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")


# Last-resort startup crash logging must never write into the standalone NP Video Studio folder.
patch_once(
    "src/NPVideoStudio.App/Program.cs",
    '                    "NP Video Studio", "Logs");',
    '                    "NP Suno Unified Studio", "Logs");',
)

# Keep structured log metadata clearly identifiable as the unified product.
patch_once(
    "src/NPVideoStudio.Infrastructure/Logging/AppLogging.cs",
    '.Enrich.WithProperty("Application", "NP Video Studio")',
    '.Enrich.WithProperty("Application", "NP + Suno Unified Studio")',
)

# apply_integration.py historically generated the unified Suno block in build-release.ps1
# with literal backslash-n sequences instead of real line breaks. PowerShell then receives one
# malformed line exactly at the packaging phase. Repair only that generated block in the
# temporary NP checkout; neither pinned source repository is modified.
build_release = root / "scripts/build-release.ps1"
build_text = build_release.read_text(encoding="utf-8")
block_start_marker = "# Unified build only: copy the separately staged, pinned Suno runtime into the NP publish tree."
block_end_marker = 'Write-Host "== 5/7: Pravljenje ugradjenog instalatera (NPVideoStudioSetup.exe) ==" -ForegroundColor Cyan'
start = build_text.find(block_start_marker)
end = build_text.find(block_end_marker, start)
if start < 0 or end < 0:
    raise RuntimeError("scripts/build-release.ps1: generated unified Suno packaging block was not found")
block = build_text[start:end]
if "\\n" in block:
    block = block.replace("\\n", "\n")
    build_text = build_text[:start] + block + build_text[end:]
    build_release.write_text(build_text, encoding="utf-8")

# Fail early if the generated block is still malformed instead of discovering it during packaging.
verified = build_release.read_text(encoding="utf-8")n
