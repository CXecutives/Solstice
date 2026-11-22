# Solstice

Privater, leistungsorientierter Fork von Henge (iOS-App, die echtes macOS 15.6.1 per eigenem
arm64→arm64-JIT ausführt). Einziger Nutzer: der Besitzer. Geräte: iPhone 16 Pro (Hauptgerät),
iPad Air 4 (4 GB, knappster Fall), später iPad Pro M4/M5. Kostenlose Apple-ID, Sideloading über
AltStore Classic 2.3. Plan und Blöcke: `PLAN.md`; Detailwissen: `docs/solstice/`; Stand: `HANDOFF.md`.

## Befehle
- Kein lokaler Build (Windows). Gebaut und getestet wird nur auf GitHub Actions (`xcode-27`-Runner).
- `tools/check.sh test_jit test_mem` – nur die genannten Engine-Tests in CI (berührte Teile).
- `tools/check-all.sh` – alle Engine-Tests + iOS-Build + IPA (Blockende).
- IPA landet nach `tools/check-all.sh` in `out/Solstice.ipa`.

## Grenzen
- Privat. Pushen nur nach `origin` (CXecutives/Solstice); nichts veröffentlichen.
- macOS-Minuten sind knapp (privat ~200 min/Monat): Läufe bündeln, nie ohne Änderung wiederholen.
- Nur Sequoia 15.6.1 als Gast (#161-Zeitstempel gilt nur für macOS 15).
- Bundle-ID bleibt `com.henge.app` (Daten und App-IDs bleiben erhalten). Signiert wird mit
  `Henge.personal.entitlements` (kostenloses Team: kein EVA).
- Engine-Standardwerte nur in `ios/Henge/EngineTuning.swift`, Geräte-Werte nur in der Gerätetabelle
  in `ios/Henge/Hardware.swift`.
- Die Helper-Thunks in `host/enter.S` sichern q0–q31 nicht: aus `hv_tlb_refill`/`hv_ijc_resolve`
  heraus kein memset/memcpy/SIMD (CI-Gate `tools/simd_gate.py`).
- Sprache im Repo: Englisch (Code, Kommentare, Commits); mit dem Besitzer: Deutsch.
