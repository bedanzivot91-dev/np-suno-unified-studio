# NP + Suno Unified Studio

Novi, odvojeni projekat koji spaja **NP Video Studio** i **Suno Pesme Studio** u jednu Windows aplikaciju, bez menjanja originalnog repozitorijuma.

## Izvori su zaključani

Ovaj repo NE sadrži izmene u `bedanzivot91-dev/force-delete-studio`.
GitHub Actions uzima dve read-only kopije:

- Suno Pesme Studio: tag `v3.3.2.343`
- NP Video Studio: commit `52278e919f6ee0af760241a2666626e3ecb16a03`

Tačne reference su u `sources.lock.json`.

## Kako je spojeno

NP Video Studio ostaje glavni Avalonia desktop shell i video editor. U isti glavni prozor se dodaje kartica **Suno Studio**. Kada se ona otvori:

1. aplikacija pokreće ugrađeni Suno Python backend iz `SunoEngine/`;
2. backend radi isključivo na `127.0.0.1:18765`;
3. Suno web interfejs se prikazuje unutar istog Avalonia prozora preko `NativeWebView`;
4. zatvaranje unified aplikacije uredno gasi i ugrađeni Suno backend.

Dakle korisnik pokreće **jednu aplikaciju**, a ne dva odvojena programa.

## Izolacija od originala

Unified verzija namerno koristi:

- novi installer `AppId`;
- novi naziv instalacije: `NP + Suno Unified Studio`;
- novi AppData: `%LOCALAPPDATA%\NP Suno Unified Studio`;
- odvojeni Suno port `18765`;
- odvojene Suno baze/foldere unutar unified AppData;
- read-only checkout originalnih GitHub izvora (`persist-credentials: false`, workflow `contents: read`).

Zbog toga instaliranje ili deinstaliranje unified programa ne treba da nadograđuje niti uklanja originalni NP Video Studio.

## Build

Pokreni GitHub Actions workflow **Build NP + Suno Unified Studio**. Workflow:

- proverava tačne source commit/tag reference;
- pravi privremene kopije oba originalna projekta;
- primenjuje integracioni overlay samo na NP kopiju;
- koristi originalni Suno staging mehanizam za embedded Python i runtime komponente;
- stvarno pokreće `/api/health` Suno servera pod staged `pythonw.exe`;
- gradi NP solution i pokreće postojeće NP testove;
- pravi jedan Inno Setup installer i jedan portable paket;
- proverava da finalni payload sadrži i `NPVideoStudio.exe` i `SunoEngine`.

Očekivani artefakti:

- `NPSunoUnifiedStudio-Setup`
- `NPSunoUnifiedStudio-Portable`

## Važno

Ovaj repo je integracioni projekat. Izvorni kod dva programa se namerno ne kopira i ne prepravlja u njihovom originalnom repou; CI ga preuzima na tačno zaključanim referencama i pravi novu kombinovanu distribuciju.
