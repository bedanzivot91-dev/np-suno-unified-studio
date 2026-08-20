# Analiza dva izvorna programa

## Suno Pesme Studio v3.3.2.343

Suno deo je Python 3.13 aplikacija sa lokalnim `http.server` backendom, SQLite bibliotekom i web frontend-om. Funkcionalni inventar taga pokazuje module za Suno povezivanje, biblioteku, audio obradu, fingerprinting, prepoznavanje pesme, YouTube OAuth/analitiku, backup, subtitlove, stem/transkripciju, release/update i druge funkcije. Server sluša samo loopback i podrazumevano koristi port 8765; unified verzija mu namerno daje drugi port 18765.

## NP Video Studio build iz workflow run-a 32290385367

Workflow run je uspešan na commitu `52278e919f6ee0af760241a2666626e3ecb16a03`. Gradi .NET 8/Avalonia desktop aplikaciju, pokreće testove i pravi Windows installer i portable paket. Build koristi FFmpeg, yt-dlp, Chromaprint i Tesseract. NP projekat već ima DI composition root, više ViewModel/View ekrana, timeline/player, render pipeline, titlove, OCR, song recognition, YouTube download i druge video funkcije.

## Zašto nije urađen običan git merge

Tag Suno i NP commit su divergirane istorije sa potpuno različitim aplikacionim strukturama. Direktan merge bi napravio veliki konflikt i, još važnije, ugrozio bi zahtev da oba originala ostanu netaknuta. Zato unified repo koristi reproducibilni composition build: dve zaključane read-only kopije + mali integracioni overlay.
