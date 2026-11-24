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
- Kein lokaler Build (Windows). Gebaut und getestet wird auf GitHub Actions (`xcode-27`-Runner, kostenlos, weil öffentlich).
- `tools/check.sh test_jit test_mem` – nur die genannten Engine-Tests (berührte Teile).
- `tools/check-all.sh` – alle Engine-Tests (normal, wie ausgeliefert + ThinLTO, mit UB-Fallen), Registerschutz-Prüfung,
  iOS-Build; die IPA landet in `out/Solstice.ipa`.
- `tools/screens.sh` – Bildschirmfotos aller App-Bildschirme (Simulator, Beispieldaten) nach `out/screens/`, Übersicht `index.html`.
- `tools/shipped_env.py` – die ausgelieferten Engine-Einstellungen aus `EngineTuning.swift` (CI testet damit).
- `tools/regen.sh` – schreibt alles Erzeugte neu (Knopf-Tabelle, Karte); CI prüft, dass es aktuell ist.
- `tools/windows-sideload.ps1` – richtet einen Windows-PC fürs Sideloading ein (Apple-Gerätedienst, Treiber).

## Grenzen
- Nichts außer `origin` (CXecutives/Solstice) wird beschrieben; keine Releases.
- Nur Sequoia 15.6.1 als Gast, bis eine Versions-Weiche gebaut ist (der vBlank-Zeitstempel aus #161 gilt nur für macOS 15).
  Geräte ab A14, iOS/iPadOS ab 26.
- Engine-Einstellungen (Name, Typ, Vorgabe, Bereich) nur in `core/knobs.def`; daraus erzeugt `tools/regen.sh` die Swift-Namen und
  `KNOBS.md`. Was die App abweichend ausliefert, steht nur in `ios/Solstice/EngineTuning.swift`. Gerätewerte nur in der Gerätetabelle
  `ios/Solstice/DeviceProfile.swift` (reines Foundation, Test `tests/test_device_profile.swift`).
- Die Helper-Thunks in `host/enter.S` sichern q0–q31 nicht: aus `hv_tlb_refill`/`hv_ijc_resolve`/`hv_light` heraus kein
  libc-Aufruf und kein SIMD (Dateien in `NOSIMD` im Makefile; CI-Gate `tools/simd_gate.py`). Resets großer Tabellen nur im
  Dispatcher.
- Gast-Setup: Set Up ruft nur `tune` (nichts Sichtbares); sichtbare Änderungen nur im optionalen `lighten`.
- Alles heißt Solstice, sichtbar und intern (Symbole, Dateien, Ordner, Schlüssel, Kennungen). „Henge“ steht nur noch in
  Herkunft und Lizenz (`README.md`, `NOTICE`, Einstellungen, About) und in der Liste alter Gast-Namen in `host/brand.h`;
  `tools/brand_gate.py` prüft das. App-Texte sind schlicht: kein Punkt zwischen Wörtern, kein Gedankenstrich als Satzzeichen.
- Sprache im Repo: Englisch (Code, Kommentare, Commits); mit dem Besitzer: Deutsch.
