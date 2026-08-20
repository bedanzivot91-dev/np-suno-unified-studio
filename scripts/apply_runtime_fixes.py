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

print("Unified runtime isolation fixes applied:", root)
