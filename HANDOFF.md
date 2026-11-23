# Übergabe

## Stand (23.11.2026)
Solstice läuft auf dem iPhone 16 Pro (macOS Sequoia 15.6.1, sideloaded mit Impactor). Das erste Geräte-Log (82 Minuten)
ist ausgewertet; daraus und aus sieben weiteren Analysen entstand der Umbau-Plan in `PLAN.md` (freigegeben am 23.11.).
Das Repo ist öffentlich; die Geschichte wurde vorher von privaten Angaben bereinigt. PC-Eigenes steht in `HANDOFF.local.md`.

## Was drin ist (vor dem Umbau)
- **Basis:** Henge `7b55730` + ausgewählte Community-Verbesserungen (#214 #121 #166 #207 #188 #187 #161 #142 #137 #73 #183
  #215 #109 #209 #170 #167 #123 u. a.).
- **Übersetzer:** kompakte Slow-Paths (−22 % Code), Groups v2, 8192-TLB, Refill für alle Formen, Systemregister inline.
- **Mehrkern/Energie:** Statistik pro CPU, kurze TLBI-Wartezeiten, fristgesteuerter Kicker, PV-Ticket-Locks.
- **Leichter Pfad:** SVC/ERET/WFE ohne SIMD-Sicherung (`core/light.c`), kein ISB bei Treffern im eigenen Sprung-Cache.
- **Code-Cache:** segmentiert und generationell, ohne Stillstand.
- **Speicher:** Block-Records 40 B, Slots 48 B, Tabellen nur für gestartete CPUs, `henge_vm_trim()`, Ballon nach System-Reserve.
- **Hitze/Strom:** `PowerPolicy.swift` (kein WFI-Spin im Stromsparmodus, 30 Hz bei Hitze, Pause bei kritisch).
- **Gast:** Set Up ruft nur `tune` (unsichtbar); sichtbare Erleichterungen nur im optionalen „Lighter macOS“.
- **Prüfung:** alle Engine-Tests normal, wie ausgeliefert (+ ThinLTO) und mit UB-Fallen; Fuzzer; `tools/simd_gate.py`.

## Messwerte vom ersten Gerätelauf (Ziele des Umbaus)
- Speichergrenze 6144 MiB, App 1,7–2,4 GB, immer ≥ 3,7 GB frei.
- Code-Cache 768 MB: 85 % der Übersetzungen sind Wieder-Übersetzungen.
- 4–7 Tsd. Programmwechsel/s → 364–398 Tsd. TLB-Nachfüllungen/s; 148–190 Tsd. Sprung-Cache-Füllungen/s in toten Bestand.
- Geräte-Abfragen 2,7–4,4 Tsd./s (bis 37 Tsd.), Kicker 1,3–1,5 Tsd. Wakeups/s unter Last.
- Leerlauf-Sturm: 40 s mit 65,8 Tsd. IRQ/s bei stehendem Bild.
- Pipeline-Archiv bei 31 von 32 Dateien; Gast-Ton bleibt nach einer iOS-Unterbrechung stehen.
- Download heizt das Gerät („Hot“ nach 82 s), Restore 452 s, erster Start bis Bild 50–60 s.

## Entscheidungen
- **Impactor** zum Sideloaden (beantragt `increased-memory-limit` selbst); Auffrischen alle 7 Tage über den PC.
- **Nur Sequoia** in diesem Durchlauf; Tahoe 26 / macOS 27 später (braucht eine Versions-Weiche).
- **Alles Unbenutzte fällt weg:** „Mac-Apps ohne macOS“, alte JIT-Wege, iOS < 26, Lautstärketasten-Klick, Autopilot, Farbtest.
- **macOS sieht aus wie immer;** „Fortsetzen“ wird Vorgabe; Code-Cache 1 GB auf 8-GB-Geräten.
- **Eigene App-Kennung** im Schluss-Build (`io.github.cxecutives.solstice`): der Mac wird danach einmal neu installiert.
- Herkunftszeile unter Einstellungen → Info und in der README.

## Ablauf des Umbaus (Details in `PLAN.md`)
1. Phase 0: Repo öffentlich, schnellere Prüfung, Regeln.
2. Welle 1 (parallel): S Schlank+Struktur (Swift) · E1 MMU · E2 Code-Cache/Übersetzer/Messung · E3 Wecken/Timer/Bildtakt ·
   E4 Datenwege · E5 Grafik → Build 1 aufs iPhone, Zähler vergleichen.
3. Welle 2 (parallel): I Steuerung · D Bild · L Lebenszyklus · U Einstellungen · K Knopf-Tabelle.
4. Drei unabhängige Prüfungen, Schluss-Build, frische Installation auf iPhone 16 Pro und iPad Air 4.
