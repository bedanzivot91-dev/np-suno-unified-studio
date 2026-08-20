# Arhitektura unified programa

## 1. NP Video Studio

Glavni proces ostaje `NPVideoStudio.exe` (.NET 8 + Avalonia). Sve postojeće video funkcije, timeline, player, titlovi, OCR, render, YouTube download i ostali NP servisi ostaju u istom kodu iz zaključanog NP commita.

## 2. Suno Pesme Studio

Suno ostaje njegov provereni Python backend + postojeći web frontend. Unified build ga pakuje u:

`SunoEngine/`

Ključne putanje u finalnoj instalaciji:

- `SunoEngine/python/pythonw.exe`
- `SunoEngine/app/server.py`
- `SunoEngine/app/server_core.py`
- `SunoEngine/app/web/`
- `SunoEngine/plugins/`
- `SunoEngine/tools/`

## 3. Most između njih

`SunoStudioHostService` je jedini novi procesni most. On:

- pokreće Suno server;
- postavlja izolovane environment promenljive;
- čeka pravi `/api/health`;
- izlaže `http://127.0.0.1:18765/` Avalonia WebView-u;
- šalje `/api/shutdown` pri gašenju aplikacije;
- ako uredan shutdown ne uspe, gasi samo child proces koji je unified aplikacija sama pokrenula.

## 4. UI

`MainWindow` dobija stalno dugme `Suno Studio` i `DataTemplate` za `SunoStudioViewModel`. `SunoStudioView` koristi `NativeWebView`, pa je Suno UI fizički unutar istog desktop prozora.

## 5. Zaštita originala

Originalni repository se u workflow-u checkoutuje sa `persist-credentials: false`, a workflow ima samo `contents: read`. Integracione izmene nastaju isključivo u `_sources/np`, privremenom CI direktorijumu.

Installer dobija novi AppId `A0C88060-C275-4677-9983-E0E76DFFCCF6`, pa ga Windows ne tretira kao upgrade originalnog NP Video Studio instalera.
