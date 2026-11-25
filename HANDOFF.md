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

## Stand des Umbaus (24.11.2026)
**In `main`:** der ganze Umbau (Welle 1 und 2, alle Behebungen aus sechs Prüfungen) und seit heute:
- **Alles heißt Solstice,** auch intern: Symbole `solstice_*`, Ordner `ios/Solstice`, Einstellungs-Schlüssel, Kennung
  `io.github.cxecutives.solstice`, Workflow `build-solstice.yml`. „Henge" steht nur noch in Herkunft und Lizenz
  (`README.md`, `NOTICE`, Zeile in Einstellungen, About) und in der Liste alter Gast-Namen in `host/brand.h`.
  `tools/brand_gate.py` prüft das im ganzen Baum.
- **Texte der App:** eigene Gliederung der Einstellungen (JIT, Trackpad & Mouse, Keyboard, Start & Resume, Appearance,
  Performance, Diagnostics, About), Zeilen in Titel-Schreibweise wie in den iOS-Einstellungen, Menüpfade als „A > B",
  kurze normale Sätze. Kein Punkt zwischen Wörtern, kein Gedankenstrich als Satzzeichen (prüft dieselbe Sperre).
  Wunsch des Besitzers: eigenes, logisches, sorgfältiges Wording, weder KI-Ton noch Kopie des Originals.
- **Bildschirmfotos** aller Ansichten aus dem Simulator: `tools/screens.sh`, Ergebnis in `out/screens/`.

Geprüft: alle Engine-Tests normal, wie ausgeliefert + LTO und mit UB-Fallen, Swift-Tests, App-Build mit SIMD-Sperre,
Namens- und Knopf-Sperre. **Noch auf keinem Gerät gelaufen.**

**Builds in `out/`:** `Solstice.ipa` ist der neue Stand mit neuer Kennung (für iOS eine neue App neben der alten: macOS
wird darin frisch installiert, JIT neu eingerichtet). `Solstice-1.0.91.ipa` ist der letzte Stand mit alter Kennung.

**Was der Gerätetest zeigen soll (Log lesen):**
- Zähler gegen die Tabelle oben: Wieder-Übersetzungen, TLB-Nachfüllungen, Sprung-Cache-Füllungen, Geräte-Abfragen, Kicker.
- iPad Air 4: kein totes Bild mehr; bei einem GPU-Fehler die Zeilen `pvg-metal: N remaps so far` und
  `GPU context lost: drawing on a new command queue`.
- iPhone: zählen die Werte unter Details hoch? (Im Simulator mit iOS 27 zeichnet die Sitzung auf dem iPhone nach dem
  ersten Bild nicht neu; Auslöser dort ist `ExternalMacDisplayModifier`. Am echten Gerät unbestätigt.)
- Fortsetzen, Shut Down über den Ein/Aus-Knopf, Rechtsklick, deutsche Tastatur, Ton nach Unterbrechung, schärferes Bild.

**Danach:** nachbessern, was das Log zeigt; Bildschirmgröße in den Kopf des Speicherstands (heute verwirft eine geänderte
Größe den Stand still); die Liste alter Gast-Namen entfernen, sobald alle Macs frisch installiert sind; drei
Schluss-Prüfungen (Kern, App, Sicherheit); `-Werror`, `MAP.md`, `tools/WHERE.md`.

**Entschieden am 24.11.:** Es bleibt bei Sequoia 15.6.1. Kein Umschreiben in Rust: Die Engine ist C, eine Übersetzung
bliebe rechtlich ein Abkömmling und die GPL gälte weiter; einzelne Teile in Rust neu zu schreiben bleibt möglich.

**CI:** alle macOS-Jobs auf dem `xcode-27`-Image. GitHub hat für macOS-arm64 Kapazitätsengpässe: Jobs warten bis 30 min
und werden nach 15 min ohne Runner verworfen („not acquired"), dann denselben Lauf neu starten. Mehrere Zweige zusammen in
einem Lauf prüfen statt einzeln.

## Neuaufbau in Rust (entschieden am 25.11.2026)
Der Besitzer will Solstice als eigenes Werk neu aufbauen: die Engine in Rust, von Grund auf sauber gegliedert, mit
maximaler Performance und niedrigster Verzögerung in jedem Aspekt, zuerst für das iPhone 16 Pro, der Auslegung nach für
alle Geräte ab A14. Der C-Stand in `main` ist das Original, gegen das geprüft wird. Sequoia 15.6.1 bleibt, Lizenz und
Herkunftszeile bleiben.

**Vorgehen (freigegeben):** das Rust selbst schreiben, in eine vorher entworfene Struktur, Stück für Stück hinter
derselben Schnittstelle, jedes Stück gegen den C-Stand und die Tests geprüft (die Methode von `rust-anything`: Verhalten
des Originals aufzeichnen, Stück portieren, vergleichen). Kein mechanischer Übersetzer. Randteile zuerst (alles, was
Daten vom Mac prüft), der Kern zuletzt. Assembler und die Grafik-Wiedergabe mit Metal bleiben.

**Die großen Weichen, die der Plan klären muss:** Speicherzugriffe des Gasts (Tabelle im Code wie heute, oder
Adressräume des Gasts im Wirt abbilden: vermutlich der größte Hebel und das größte Risiko), Stufen der Übersetzung,
übersetzter Code über Starts hinweg, Zuordnung der virtuellen CPUs zu starken und sparsamen Kernen, Wege für Platte,
Netz und Ton, Grenze zwischen Rust und Metal, Aufbau der Rust-Teile und wo „unsafe" erlaubt ist.

**Stand:** Ein Plan für die Planung ist freigegeben (acht Pakete: Ziele in Zahlen, Pflichtenheft, Messbasis, Stand der
Technik, Entwurfsfragen mit Versuchen, Geräte-Modell, Prüfweise, Risiken). Eine Sammelphase mit 17 parallelen Helfern
wurde nach wenigen Minuten gestoppt, weil sie das Wochenlimit des Besitzers aufzehrte; es entstand noch kein Dokument.
**Lehre: keine großen parallelen Läufe ohne sein Ja zum Verbrauch.** Sparsam weiter: der Leiter schreibt den Plan
selbst, Helfer nur einzeln und für klar begrenzte Fragen.

**Hilfreich:** Rust 1.95 ist auf dem PC vorhanden und darf genutzt werden (lokale `cargo test` für alles
Geräteunabhängige). Offen ist der Gerätetest des fertigen Builds auf dem iPhone 16 Pro als Messbasis. Das App-Icon ist
noch das ursprüngliche und bleibt vorerst.
