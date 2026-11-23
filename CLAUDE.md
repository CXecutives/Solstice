# Solstice

Eigener, schlanker macOS-Lader für iPhone und iPad, hervorgegangen aus Henge (GPL-2.0-or-later): echtes macOS Sequoia 15.6.1
per eigenem arm64→arm64-JIT. Geräte des Besitzers: iPhone 16 Pro (Hauptgerät), iPad Air 4 (4 GB, knappster Fall), später
iPad Pro. Das Repo ist **öffentlich**. Plan: `PLAN.md`; Stand und Entscheidungen: `HANDOFF.md`; PC-Eigenes (nicht
eingecheckt): `HANDOFF.local.md`.

## Leitlinien
1. **Schlank vor vollständig:** Was der Besitzer nicht nutzt, fliegt ganz raus (Code, Texte, Tests, Doku). Kein Schalter für Totes.
2. **Erst messen, dann den gemessenen Engpass beheben.** Grundlage ist das Geräte-Log; jede Kern-Änderung nennt den Zähler, den sie senkt.
3. **Niedrigste Verzögerung zuerst:** Eingabe → Bild ist der wichtigste Weg; nichts Schweres auf dem UI-Faden, keine festen
   Wartezeiten, wo ein Ereignis reicht.
4. **macOS bleibt macOS:** Aussehen und Verhalten des Gasts werden nicht automatisch verändert; optimiert wird darunter.
5. **Eine Quelle pro Entscheidung:** Namen, Texte, Einstellungs-Schlüssel, Engine-Knöpfe und Gerätewerte je in einer Tabelle;
   was Swift und C beide kennen, wird erzeugt, nicht abgeschrieben.
6. **Kleinste Änderung, die das Verhalten erhält;** Umbauten als reine Verschiebungen in eigenen Commits. Logikfehler: erst
   der Test, dann die Behebung.
7. **Keine privaten Angaben** (Pfade, Adressen, Gerätekennungen, Konten) in Dateien, Commits oder Logs im Repo.
8. Keine unnötige Komplexität: einfach vor schlau; abstrahieren erst beim dritten Mal.

## Befehle
- Kein lokaler Build (Windows). Gebaut und getestet wird auf GitHub Actions (App und Schlussprüfungen auf dem `xcode-27`-Runner, schnelle Tests auf `macos-26`; kostenlos, weil öffentlich).
- `tools/check.sh test_jit test_mem` – nur die genannten Engine-Tests (berührte Teile).
- `tools/check-all.sh` – alle Engine-Tests (normal, wie ausgeliefert + ThinLTO, mit UB-Fallen), Registerschutz-Prüfung,
  iOS-Build; die IPA landet in `out/Solstice.ipa`.
- `tools/screens.sh` – Bildschirmfotos aller App-Bildschirme (Simulator, Beispieldaten) nach `out/screens/`, Übersicht `index.html`.
- `tools/shipped_env.py` – die ausgelieferten Engine-Einstellungen aus `EngineTuning.swift` (CI testet damit).
- `tools/windows-sideload.ps1` – richtet einen Windows-PC fürs Sideloading ein (Apple-Gerätedienst, Treiber).

## Grenzen
- Nichts außer `origin` (CXecutives/Solstice) wird beschrieben; keine Releases.
- Nur Sequoia 15.6.1 als Gast, bis eine Versions-Weiche gebaut ist (der vBlank-Zeitstempel aus #161 gilt nur für macOS 15).
  Geräte ab A14, iOS/iPadOS ab 26.
- Engine-Standardwerte nur in `ios/Henge/EngineTuning.swift`, Gerätewerte nur in der Gerätetabelle
  `ios/Henge/DeviceProfile.swift` (reines Foundation, Test `tests/test_device_profile.swift`).
- Die Helper-Thunks in `host/enter.S` sichern q0–q31 nicht: aus `hv_tlb_refill`/`hv_ijc_resolve`/`hv_light` heraus kein
  libc-Aufruf und kein SIMD (Dateien in `NOSIMD` im Makefile; CI-Gate `tools/simd_gate.py`). Resets großer Tabellen nur im
  Dispatcher.
- Gast-Setup: Set Up ruft nur `tune` (nichts Sichtbares); sichtbare Änderungen nur im optionalen `lighten`.
- Sichtbar heißt alles „Solstice“; interne Namen (`henge_vm_*`, Ordner `ios/Henge`, Einstellungs-Schlüssel) bleiben.
- Sprache im Repo: Englisch (Code, Kommentare, Commits); mit dem Besitzer: Deutsch.
