# Solstice — Umbau zum eigenen, schlanken Fork (großer Abschluss-Durchlauf)

## Kontext
Solstice läuft seit heute auf dem iPhone 16 Pro (macOS Sequoia 15.6.1, installiert mit Impactor). Der Besitzer will daraus
einen **eigenen, aufgeräumten, maximal schnellen macOS-Lader für iPhone und iPad** machen: nur Sequoia (Tahoe 26 / macOS 27
später), alles Unbenutzte raus, überall „Solstice“ statt „Henge“, Steuerung und Bild so macOS-nah und verzögerungsarm wie
möglich, feste Struktur nach den eigenen Arbeitsregeln. Der Kern hat Vorrang; an der Oberfläche nur, was Funktion bringt.
Grundlage sind **acht Analysen** des Stands `f2598a2`: das erste Geräte-Log (87 Statistikblöcke, 82 Minuten), Namens-Inventar,
App-Oberfläche, Steuerung, Struktur, Lebenszyklus, Bild + Einstellungen, Datenwege + Sicherheit. Entschieden ist: Das Repo
wird öffentlich (unbegrenzte Build-Minuten), nach Bereinigung privater Angaben.

## Leitlinien (werden in die Projekt-`CLAUDE.md` geschrieben)
1. **Schlank vor vollständig:** Was der Besitzer nicht nutzt, fliegt ganz raus (Code, Texte, Tests, Doku). Kein Schalter für Totes.
2. **Erst messen, dann den gemessenen Engpass beheben.** Grundlage ist das Geräte-Log; jede Kern-Änderung nennt den Zähler, den sie senken soll.
3. **Niedrigste Verzögerung zuerst:** Eingabe → Bild ist der wichtigste Weg; nichts Schweres auf dem UI-Faden, keine festen Wartezeiten, wo ein Ereignis reicht.
4. **macOS bleibt macOS:** Aussehen und Verhalten des Gasts werden nicht automatisch verändert; Optimiert wird darunter.
5. **Eine Quelle pro Entscheidung:** Namen, Texte, Einstellungs-Schlüssel, Engine-Knöpfe, Gerätewerte je in einer Tabelle; was zwei Seiten kennen (Swift/C), wird erzeugt, nicht abgeschrieben.
6. **Kleinste Änderung, die das Verhalten erhält;** Umbauten als reine Verschiebungen in eigenen Commits. Logikfehler: erst der Test, dann die Behebung.
7. **Öffentliches Repo:** keine privaten Angaben (Pfade, Adressen, Gerätekennungen) in Dateien oder Commits; PC-Eigenes steht in einer nicht eingecheckten `HANDOFF.local.md`.
8. Nur Sequoia 15.6.1, bis eine Versions-Weiche gebaut ist; Geräte ab A14, iOS/iPadOS ab 26.

## Messwerte vom iPhone 16 Pro (worauf der Kern-Teil zielt)
| Befund | Zahl | Folge |
|---|---|---|
| Speicher | Grenze 6144 MiB, App 1,7–2,4 GB, immer ≥ 3,7 GB frei | Platz für größeren Code-Cache ist da |
| Code-Cache (768 MB) | voll nach 65 s; **85 %** aller Übersetzungen sind Wieder-Übersetzungen (40,6 von 47,6 Mio.); 363 Verdrängungen, 14,3 s Arbeit; 59–66 % des Codes liegt „außer der Reihe“ | Cache zu klein, Code zu breit |
| Programmwechsel | 4–7 Tsd./s (bis 31 Tsd.); danach **364–398 Tsd. TLB-Nachfüllungen/s**; pro Wechsel 200–300 Einträge kopiert; nur 8 Ablagen pro CPU | größter Einzelposten |
| Sprung-Cache | 148–190 Tsd. Füllungen/s „in toten Bestand“; Ursache: ganze Hälften werden bei bestimmten TLBIs verworfen (12–28×/s pro CPU) | gezielt statt pauschal verwerfen |
| Geräte-Abfragen | 2,7–4,4 Tsd./s (bis 37 Tsd.), obwohl nur 0,5–1,6 Tsd. Weckrufe Arbeit tragen; jede GIC-Flanke löst eine Abfrage aller 12 Geräte aus | Abfrage nur, wo nötig |
| Kicker | 1,3–1,5 Tsd. Wakeups/s unter Last, 910/s davon nur für die 1-ms-Abfrage | nur bei Bedarf abfragen |
| Leerlauf-Sturm | 40 s lang 65,8 Tsd. IRQ/s, 379 Tsd. MSR/s bei stehendem Bild, ~1,1 Kerne verbrannt | Ursache finden, beheben |
| Netz | bis 24,9 Tsd. Pakete/s, **jedes** weckt CPU 0; Prüfsummen rechnet der Gast emuliert | bündeln, Prüfsummen abnehmen |
| Grafik | 501 Pipelines je 24–50 ms blockierend übersetzt (12 s); Archiv bei 31 von 32 Dateien → danach wird **nichts mehr gespeichert** | Deckel heben, asynchron übersetzen |
| Ton | nach einer iOS-Unterbrechung bleibt der Gast-Ton für immer stehen (im Log passiert) | Fehler beheben |
| Hitze | „Hot“ schon 82 s nach Download-Beginn, vor dem ersten Mac; 37 Minuten lang | Download entlasten |
| Gut | 0 Komplett-Flushes, 0 Grafikfehler, TLBI-Warten < 1 % eines Kerns, 44–94 Tsd. Systemaufrufe/s direkt fortgesetzt | bleibt so |

## Wie wir schnell ans Ziel kommen (ohne an Qualität zu sparen)
Bisher brauchte ich etwa die Hälfte meiner Schätzungen (letzter Durchlauf: 4–6 h geschätzt, ~2 h 10 min gebraucht). Für diesen
Durchlauf rechne ich mit **6–8 Stunden** in zwei Wellen plus zwei kurzen Gerätetests.
- **Repo zuerst öffentlich** → unbegrenzte, parallele Testläufe; kein Rationieren mehr.
- **Testlauf in parallelen Teilen** (Engine normal / wie ausgeliefert + LTO / mit UB-Fallen / iOS-Build als vier Jobs, Objekt-Cache, Abbruch überholter Läufe) → Rückmeldung in ~4 statt ~10 Minuten; ein reiner Swift-Job (~3 min) für App-Änderungen.
- **Sechs Helfer gleichzeitig** mit fest getrennten Dateien; jeder bekommt die Befunde mit Datei und Zeile, niemand erkundet neu.
- **Erst löschen, dann bauen** (≈ 22.000 Zeilen weniger); Swift-Struktur vor Swift-Funktionen, Kern parallel dazu.
- **Zusammenführen im Fluss:** jeder Helfer holt `main` vor seinem letzten Lauf; ich merge, sobald einer fertig ist.
- **Audits parallel zur Arbeit**, nicht danach; Gerätetest von Build 1 läuft, während Welle 2 arbeitet.
- **Mechanisches an Sonnet-Helfer** (Löschen, Verschieben, Umbenennen), Produktformendes an Opus.
- **Zwei-Versuche-Regel:** was nach zwei Anläufen nicht grün ist, wird gestrichen oder anders gelöst und gemeldet.
- **Frische Sitzung für die Ausführung** (diese ist sehr lang und dadurch langsam); Plan + `HANDOFF.md` tragen alles.
- Ich erzähle unterwegs in kurzen Sätzen, was gerade passiert.

---

## Phase 0 — Fundament (ich, zuerst, ~1 h)
**0.1 Repo öffentlich**
- Private Angaben aus Dateien entfernen: `HANDOFF.md:55` (LAN-Adresse), `PLAN.md:21,45`, sieben Dateien in `docs/solstice/` (Scratch-Pfade mit Benutzername) — die meisten dieser Dateien fallen in 0.3 ohnehin weg.
- Geschichte der 124 eigenen Commits bereinigen (`git filter-repo --replace-text`; Werkzeug per `pip` nachinstallieren), Sicherung des alten Stands als lokales Bundle, dann Force-Push auf das noch private `origin`.
- Alte Workflow-Läufe und Artefakte löschen; `permissions: contents: read`; Husk und Actions auf Commit-SHAs pinnen; prüfen, dass `runs-on: xcode-27` ein Standard-Runner ist (sonst auf den passenden `macos-*`-Namen mit gepinntem Xcode umstellen).
- `README.md` neu (was Solstice ist, eine Zeile Herkunft: „basiert auf Henge von Leviidev, GPL-2.0-or-later“), `NOTICE` mit den Solstice-Änderungen (GPL §2a), `LICENSE` bleibt.
- Erst dann Sichtbarkeit auf „öffentlich“ (**dein Ja liegt vor; ich schalte um, wenn die Bereinigung geprüft ist**).

**0.2 Schnellere Prüfung**
- Workflow in parallele Jobs teilen (siehe oben), `concurrency` pro Branch, Objekt-Cache für Engine und Husk.
- Swift-Tests (7 vorhandene, 6 davon liefen nie in CI) und die verwaisten Engine-Tests (`test_vm_lifecycle`, `test_dns_lifecycle`) in `TESTS` bzw. einen `swift-test`-Job; `-Werror` für `core/ host/ devices/` nach Behebung der 13 Warnungen; Xcode-Warnungen in CI sichtbar.
- `tools/check.sh` wählt die Tests aus den berührten Dateien (eine Tabelle Datei → Tests in `tools/WHERE.md`, maschinenlesbar).
- `.gitattributes`: `*.c *.h *.m *.swift *.py Makefile eol=lf`, `*.ps1 eol=crlf` (beendet die CRLF-Warnungen).

**0.3 Regeln und Grundausstattung**
- Leitlinien in `CLAUDE.md`; `PLAN.md` (erledigt, widerspricht inzwischen `HANDOFF.md`) löschen; Entscheidungen stehen in `HANDOFF.md`.
- `tools/map.py` erzeugt `MAP.md` (jede Datei mit Zweck aus der Kopfzeile; 17 Kopfzeilen fehlen), `tools/regen.sh` schreibt alles Erzeugte neu (MAP, Knopf-Tabelle, Namen, Xcode-Projekt), CI prüft `regen && git diff --exit-code`.

---

## Welle 1 — sechs Helfer parallel (getrennte Dateien)

### S — Schlank und Struktur der App (Swift; Sonnet für das Mechanische, Opus prüft)
**S1 Entfernen** (jeweils komplett: Code, Texte, Tests, Doku, Build-Einträge)
| Was | Beleg | Kleinste Änderung |
|---|---|---|
| „Mac-Apps ohne macOS“ (`tl/`, `henge-tl*`, `MacApps.swift`, `MacScreen.swift`, Tests, Beispiel-DMG) | 47 Dateien, ~18.900 + 2.150 Zeilen; hinter einem Schalter (`henge.macApps`); `-lhengetl -ObjC` lädt bei jedem Start alle Klassen | Ordner und Einträge löschen, `-ObjC`/`-lhengetl` aus `project.yml`, `Makefile:193-243` |
| JIT über TrollStore, Jailbreak, externes StikDebug, Selbst-Freigabe vor iOS 26 | 121 + 51 + 251 Treffer; auf iOS 26/27 funktioniert nur der eingebaute Weg; 3 von 7 Anleitungsschritten | `JITMethod` auf den eingebauten Weg; `Henge.entitlements` (unbenutzt), `ci/build-stikjit.sh` weg |
| iOS < 26 | `deploymentTarget` 17.0, aber eingebautes JIT braucht iOS 26; `LegacyExternalDisplay`, `#available`-Zweige, TXM-Tabelle | Ziel auf **iOS 26.0**, tote Zweige löschen |
| Lautstärketasten als Klick (`VolumeClicks.swift`) | 350 Zeilen, hält die Kamera aktiv, braucht Kamera-Erlaubnis | löschen, `NSCameraUsageDescription` weg |
| Autopilot | 174 Zeilen; führt Befehle aus einer Datei in „Dokumente“ aus (Sicherheitsfund) | löschen |
| Farbtest (`pvg_colorprobe.h`, `tools/colorprobe`) | 616 Zeilen in jedem Build | löschen (in Helfer E5, weil `pvg_metal.m`) |
| Henge-Infrastruktur: `bitrise.yml`, `ci/`, `repo.json`, `tools/update-source.py`, `Screenshots/`, `CHANGELOG.md`, `ios/README.md` | nichts hängt daran | löschen |
| Veraltete Berichte `docs/solstice/*` (plan-review, pr-triage, tools-forks, setup-flow, gapfind, gpu-io-system, translator, perf-knobs) | Einmal-Analysen gegen einen alten Stand, teils widerlegt | löschen; was noch gilt, steht in `HANDOFF.md`/`MAP.md` |
| Reste der Versionsauswahl | `MacOSRelease.all` mit einem Eintrag + Auswahl-Verdrahtung | auf einen festen Eintrag vereinfachen |

**S2 Struktur** (reine Verschiebungen je Commit, danach die Vereinheitlichung)
- `Hardware.swift` → `DeviceProfile.swift` + `HardwareKeys/PointerLock/HardwareMouse/ScrollFingers/AbsolutePointer`; `SessionView.swift` → Ansicht, `SessionLayout`, `SessionController` (Ablauf/Abfragen); `Theme.swift` ohne `MacPreview`/`ByteText`; `AutoStart` aus `HengeApp.swift`.
- **`Brand.swift`** (App-Name, Gast-Adresse, Pfade, Agent-Namen) und **`Strings.swift`** (alle 188 Oberflächentexte, typgeprüft); CI-Sperre: kein Textliteral in Ansichten außerhalb davon.
- **`Settings.swift`**: ein `enum SettingKey` (36 `henge.*` + 5 `solstice.*` + `appearance`), Voreinstellungen typisiert; `henge.cpus` (5 Stellen), `henge.jitMethod` (3), Helligkeit (3) nur noch dort.
- **Typisierter Maschinen-Zustand:** `enum HengeVmState` in `henge-vm.h`, Swift ersetzt die ~49 Zahlenvergleiche.
- **Eine Gerätetabelle** für Speicher-Schwellen (heute drei Orte mit verschiedenen Grenzen: `Hardware.swift:62-75`, `Machines.swift:74`, `JITBootstrap.swift:75-76`), mit hineingereichten Werten statt statischer Abfragen → testbar (`test_device_profile`).
- Farben/Abstände: `enum Theme` und `PrimaryButtonStyle` in `Desk` falten; Skalen `Desk.Font/Space/Radius`.
- **Schein-Engine + Bildschirmfotos in CI:** Protokoll `Engine` um die `henge_vm_*`-Aufrufe, `MockEngine` mit Testdaten; ein Simulator-Job erzeugt Fotos jeder Ansicht (iPhone 16 Pro, iPad Air 4) als Artefakt → Oberflächen-Änderungen sehe ich ohne dein Gerät, du bekommst Vorher/Nachher.

**S3 Sichtbarer Name** — überall „Solstice“: ~95 Textzeilen, beide `Info.plist`, `PRODUCT_NAME`, URL-Schema `solstice`, Log-Dateien (`solstice.log` …), Log-Kopf und -Präfixe, `tools/solstice-log-listen.py`. Im Gast: Ordner/Volume „Solstice“, Agent `solstice-agent`, Dienste `com.solstice.*`, Adresse `/.solstice/`, Gerätenamen „Solstice Keyboard/Trackpad/Pointer“, Plattenkennung, Hostname. Das Set-Up-Skript entfernt die alten `com.henge.*`-Einträge. **Interne Namen bleiben** (C-Symbole `henge_vm_*`, Ordner `ios/Henge`, Einstellungs-Schlüssel): ~850 Stellen ohne sichtbaren Nutzen.

### E1 — Speicherverwaltung der Engine (`core/mmu.c`, `sysreg.c`, `cpu.h`; Opus)
Ziel: TLB-Nachfüllungen und Sprung-Cache-Füllungen pro Programmwechsel drastisch senken.
1. Günstige Zähler zuerst (EL0/EL1, „Platz hielt andere Seite“, Ablage-Treffer), damit Build 1 misst.
2. **Mehr Ablagen:** `HV_STASHES` 8 → 32 mit Seitenfilter pro Ablage (damit `stash_drop_va` nicht 32×n Einträge absucht). Erwartet: −130 bis −310 Tsd. Nachfüllungen/s.
3. **Ablage nicht „verbrauchen“:** beim Zurückholen bleibt sie gültig, gesichert wird nur das seither Gefüllte (Kopien pro Wechsel etwa halbiert).
4. **Sprung-Cache gezielt verwerfen:** bei „alle ASIDs, eine Adresse“ nur die Seite unter jeder lebenden Kennung löschen (wie `hv_ijc_drop_code_page`, `mmu.c:1001-1005`) statt die ganze Hälfte; `ijc_va` für 2–4 Seiten. Erwartet: Verwerfen der Nutzer-Hälfte 28/s → ~5/s.
5. **Gemeinsamer Bereich überlebt Wechsel** (dyld-Shared-Cache, 96 % der Nutzer-Füllungen): Einträge behalten, wenn der L2-Eintrag des 32-MB-Zweigs in altem und neuem Adressraum gleich ist. Riskantester Punkt → eigener Test (zwei Adressräume mit geteiltem Zweig, TLBI dazwischen), Fuzzer; bei Zweifel nach zwei Versuchen streichen.
Tests: `test_mmu`, `test_mp`, `test_memory`, `test_fuzz` + neue Fälle je Punkt.

### E2 — Code-Cache, Übersetzer, Messung (`core/codecache.c`, `translate.c`, Statistik in `dispatch.c`; Opus)
1. **Cache 1 GB auf 6–8-GB-Geräten** (mehr geht ohne bezahltes Konto nicht: größtes Loch ~1080 MiB); die Messung zeigt ≥ 3,7 GB Reserve. Gerätetabelle statt verstreuter Zahlen.
2. **Schmalerer Code:** gemeinsame Ausgangs- und Slow-Path-Stücke, damit weniger als die heutigen ~15 Wörter pro Gastbefehl entstehen (59–66 % liegen außer der Reihe). Maß: Wörter/Befehl in `test_mem`/`test_fuzz`.
3. **Verdrängung prüfen:** 308 von 363 verdrängten Segmenten waren „bewährte“; Politik so ändern, dass heißer Code bleibt (Simulation in `test_codecache` mit den Geräte-Raten).
4. **Messfehler beheben:** „Wörter pro Befehl 0,0x“ (`dispatch.c:239`), Statistik nach Zeit statt alle 65.536 Einträge von CPU 0 (Abstände bis 161 s), `[perf] blocks/s` als Mittel, Statistik auch während der Installation, Drucken aus `dispatch.c` nach `stats.c`.

### E3 — Wecken, Kicker, Timer, Bildtakt (`core/machine.c`, `light.c`, `devices/vmapple.c`, `gicv3.c`, vBlank in `pvg_lite.c`; Opus)
1. **GIC-Flanke weckt ohne Geräte-Abfrage** (`machine.c:535`, `gicv3.c:85`); nur pvg und Uhr fordern ausdrücklich an. Erwartet: Abfragen 3,8 Tsd. → ~2,5 Tsd./s, im Sturm 37 Tsd. → < 1 Tsd.
2. **Kicker fragt nur ab, wenn ein Gerät „Arbeit ohne Signal“ meldet** (heute stur jede Millisekunde): −700 Wakeups/s.
3. **Leerlauf-Sturm:** immer mitlaufender, billiger Detektor (IRQ-Rate + häufigstes Systemregister einmal loggen), Ursache finden (Verdacht: Timer wird in der Vergangenheit neu gestellt), beheben, Test dazu.
4. **Gast-Timer und Geräte-Frist trennen** (`hv_resume`): −300 bis −600 abgelehnte Schnell-Fortsetzungen/s; kein Mutex/Signal für laufende Ziel-CPUs.
5. **Bildtakt:** bei gedeckelter Ausgabe (Hitze) auch das vBlank-Ereignis im Deckel-Takt; keine vBlank-Frist, solange der Gast das Ereignis maskiert (mit Schutz gegen den #161-Sturm, Test in `test_pvg_vblank_clock`).

### E4 — Datenwege und ihre Sicherheit (`host/net_slirp.c`, `devices/virtio_net.c`, `virtio_blk.c`, `virtio_snd.c`, `host/audio_mac.c`, `host/share.c`, `host/disk.c`; Opus)
1. **Ton-Fehler:** nach iOS-Unterbrechung Gerät neu starten, währenddessen den Gast per Uhr weiterlaufen lassen; Start/Stopp nicht mehr unter der Gerätesperre; Unterläufe ins Log.
2. **Netz:** Wecken nur bei „leer → nicht leer“ (auch DNS), Zustellung sofort, wenn der Gast Puffer nachlegt (heute bis 20 ms Wartezeit), Zähler für Füllstand und Verluste; **Prüfsummen abnehmen** (GUEST_CSUM/CSUM), sofern Apples Treiber sie annimmt; Paketpuffer aus einem Vorrat statt `malloc` pro Paket.
3. **Platte:** ein Arbeiter pro Auftrag wecken statt alle acht; Zähler für Discard (prüft, ob TRIM wirklich ankommt).
4. **Freigabe-Server:** nur Anfragen mit `Host: 10.0.2.4` annehmen und die Zwischenablage mit einem Sitzungs-Kennwort schützen (sonst kann eine Webseite im Gast die iPhone-Zwischenablage lesen); Kopfzeilen gepuffert lesen (heute ein Systemaufruf pro Byte); Obergrenze für Uploads (freier Platz), fehlerhafte Bereichsangaben → 416.

### E5 — Grafik (`devices/pvg_metal.m`, zuerst entlang der vorhandenen Nähte in 6 Dateien geteilt; Opus)
1. **Pipeline-Archiv:** Deckel 32 → 256 Dateien + Verdichtung (sonst wird ab der nächsten Sitzung nichts mehr gespeichert).
2. **Pipelines asynchron übersetzen,** gewartet wird erst beim ersten Gebrauch (Ruckler beim ersten Anzeigen neuer Elemente; Bündel von 100 Stück ~2,4 s → < 1 s).
3. **Video-Oberflächen:** kein Hashen der ganzen Fläche pro Befehl, Kopie auf der GPU statt per CPU (4K-Video: ~1–1,5 GB/s Speicherverkehr weniger; behebt nebenbei verpasste Bildänderungen).
4. **Sicherheit:** fehlende Längenprüfungen im Render-Decoder (`:1771-1776`, `:1927-1929`, `:1952-1958`, Doppel-Lesen bei `:1914-1918`), Indizes begrenzen.
5. **Schärferes Bild ohne Mehrarbeit für den Mac:** Die Ausgabe zeichnet in echter Bildschirmauflösung und skaliert selbst (Catmull-Rom + milde Schärfung; pixelgenau bei ganzzahligem Faktor; sauberes Verkleinern im Hochformat), statt die weiche Standard-Skalierung von iOS zu nutzen; feines Rauschen gegen Farbstufen.
6. **Zeiger im Takt des Bildschirms** (120 Hz auf dem iPhone), Einstellungen per Aufruf statt aus `NSUserDefaults` gelesen, Diagnose-Ausgaben (1.360 Oberflächen-Zeilen, Gamma-Dumps) nur noch bei eingeschalteter Spur, Farbtest raus.

**Danach: Build 1 → du installierst ihn mit Impactor (5 min) und benutzt den Mac 15 Minuten; ich vergleiche die Zähler mit der Tabelle oben.**

---

## Welle 2 — fünf Helfer parallel (auf der aufgeräumten Struktur)

### I — Steuerung (`Trackpad.swift`, `Input.swift`, Eingabe-Klassen, `devices/xhci.c`, `virtio_input.c`, Eingabe in `host/vm.c`)
Leitbild: Finger bleiben ein echtes Magic Trackpad (macOS erkennt Wischen, Zoomen, Drehen selbst) — und alles drumherum wird direkter.
1. **Tastatur nach Belegung:** Tabellen Zeichen → Taste für Deutsch und US, Wahl in den Einstellungen (Vorgabe: Sprache der iOS-Tastatur); Umlaute, @, Klammern, z/y stimmen; Befehle zum Einrichten funktionieren auf deutschem Mac. Deutsche Hardware-Tastatur: ISO-Typ melden, `<`-Taste zuordnen. (Tabellen per Test geprüft.)
2. **Berührungen gehen nie verloren:** Bewegungs-Meldungen zusammenfassen, Absetzen/Abheben nie verwerfen (`xhci.c:1088-1100`) → kein Weiterscrollen von selbst, keine „klebenden“ Finger.
3. **Echter Rechtsklick ohne 100 ms** und ohne Blockieren des Zeigers (`vm.c:737-748`): Zwei-Finger-Klick des Trackpads.
4. **Randgesten bleiben im Mac** (`defersSystemGestures`); **Werkzeugleiste weg von der Menüleiste** (seitlich neben der Dynamic Island).
5. **Sondertasten:** haftendes ⇧, Doppeltipp rastet ein (mehrfaches ⌘-Tab), Sondertasten überleben eine Zeigerbewegung, fn/F1–F12, Entf, Pos1/Ende/Bild↑↓, Kurzbefehl-Leiste (⌘Space, ⌘Tab, ⌘Q, ⌘W, Bildschirmfoto, Mission Control).
6. **Ziehen per Doppeltipp-und-Halten** zusätzlich zum 0,4-s-Halten; Zeiten einstellbar; Zustandsmaschine als reine, getestete Struktur.
7. **Flüssiger:** alle Berührungs-Zwischenwerte nutzen (120 Hz), Maus-Ereignisse auf eigener Warteschlange, Scroll-Tempo auch für Finger.
8. **Hardware-Tastatur:** Kürzel, die iPadOS abgeben kann, an den Mac (`UIKeyCommand` mit Vorrang).
9. **Zwischenablage:** Abfrage 0,25 s, Bestätigung statt fester 800 ms, auf Wunsch automatisch in beide Richtungen; **Dateien hineinziehen** → landen im geteilten Ordner.
10. **Direktes Antippen als zweiter Modus** (Zeiger springt dorthin, wo du tippst) über das vorhandene Absolut-Zeigergerät, Tasten im selben Bericht.

### D — Bild und Bildschirmgrößen (`DeviceProfile.swift`, `Machines.swift`, `SessionLayout`, `BootDisplay.swift`)
| Gerät | Neu als Vorgabe | Warum |
|---|---|---|
| iPhone 16 Pro | **1664×864** im sicheren Bereich (heute 1536×864 mit 239 px Rand je Seite) | 7 Punkte breiter genutzt, nichts unter der Dynamic Island, +8 % Pixel; mit der neuen Skalierung deutlich schärfer |
| iPad Air 4 | **1176×816 bei exakt 2×** (heute 1280×888 bei 1,84×) | gestochen scharf statt weich, 16 % weniger Arbeit für den Mac |
| iPad Pro M4 | **Retina** (echte Pixel) | genug Leistung, nichts zu skalieren |
- Echte Pixeldichte je Gerät statt fest 264 ppi; Layout auf ganze Pixel; nur Bildraten anbieten, die das Gerät zeigen kann (120 Hz nicht auf dem Air 4); Eck-Maske ohne Zusatzdurchgang.
- **Eine** Bildschirm-Einstellung pro Mac mit Vorgaben („Empfohlen“, „Mehr Platz“, „Größer“, „Retina“) und Zeile „sieht aus wie … · scharf/weich · leichter/schwerer“; bestehende Macs mit alter Vorgabe wandern auf „Empfohlen“.
- Reine Größen-Mathematik per Test geprüft.

### L — Lebenszyklus (`Installer.swift`, `RangedDownload.swift`, `InstantResume.swift`, `KeepAlive.swift`, `SessionController`, `HengeLog.swift`, `host/snapshot.c`, Ablauf in `henge-vm.c`)
1. **Antippen → Schreibtisch in Sekunden:** „Fortsetzen“ wird Vorgabe. Gespeichert wird erst nach ~20 s im Hintergrund und nur, wenn der Mac seit dem letzten Stand lief (schont den Speicher); der Stand wird erst gelöscht, wenn der Mac wirklich weiterläuft; zwei Wege mit liegenbleibenden Dateien behoben. (Ein veralteter Stand wird schon heute sicher abgelehnt.)
2. **Download ohne Hitze:** Fortschritt 2–4×/s statt tausendfach (heute wird bei jedem Datenblock die ganze Oberfläche neu berechnet), Schreiben in 4–8-MB-Blöcken, **SHA-256 im Durchlauf** gegen einen festen Wert (kaputte Downloads fallen sofort auf), Löschen der Installationsdatei wird geprüft und geloggt.
3. **Kein Einfrieren:** Start/Fortsetzen und Speicherabfragen weg vom UI-Faden; Bereitschaft per Ereignis statt per Abfrage (100/200/500-ms-Schleifen); pausiert nur noch 1 Abfrage/s statt 10.
4. **Sauber ausschalten:** „Shut Down“ drückt den Ein/Aus-Knopf des Macs (GPIO vorhanden), macOS fährt geordnet herunter; „Force Off“ bleibt; Wächter, wenn ein Stopp hängt.
5. **Stille Tonspur nur beim Verlassen** der App (heute läuft sie die ganze Sitzung); Ballon-Wartezeit von 3 s entfällt, wenn der Gast nicht reagiert; Autostart-Zähler zählt Pausen nicht als Fehlstart; Start-Arbeit vor dem ersten Bild entschlackt; Log ereignisgesteuert statt 25 Abfragen/s.
6. **Sicherheit:** Kopplungsschlüssel aus „Dokumente“ in den Schlüsselbund (einmalige Übernahme, alte Datei löschen); Log-Übertragung kürzt Pfade und Gerätenamen und warnt bei Zielen außerhalb des Heimnetzes; `solstice-env.txt` nimmt nur bekannte Knöpfe an.

### U — Einstellungen und Info (`SettingsView.swift`, `MacSettingsView.swift`; ordnet die Bausteine von I, D, L an)
- **App:** JIT · Zeiger & Trackpad · Tastatur des Macs (neu) · Beim Verlassen (Wach halten, Fortsetzen, letzten Mac starten) · Darstellung · **Erweitert** (Bildrate „Automatisch“, Code-Cache „Automatisch“, schnellere Plattenschreibvorgänge) · **Diagnose** (Speicherwerte, Log teilen, Log-Übertragung) · **Info** (Version, „Based on Henge by Leviidev · GPL-2.0“, Link zum Quelltext — so machen es Forks üblicherweise).
- **Pro Mac:** Name · Bildschirm (eine Wahl) · Speicher (nur was wirklich startet, mit Erklärung) · Prozessoren (pro Mac gespeichert) · Über diesen Mac · Speicherplatz · Verwalten; eine Fußzeile „gilt ab dem nächsten Start“ + „Jetzt neu starten“.
- Weg aus der Oberfläche: Farbanpassung und „scharfe Kanten“ (immer an), doppelter Scroll-Regler, Methode/TrollStore, Superblocks, „schneller aufwachen“ (entscheidet die App).
- Falsche Hilfetexte korrigiert (Ordnername, iOS-Menüpfade).

### K — Eine Knopf-Tabelle für die Engine (C; nach dem Merge von Welle 1, ein Rutsch)
- `core/knobs.def` (Name, Typ, Vorgabe, Bereich, Zweck) → C-Zugriff mit **einmaligem** Lesen beim Erzeugen der Maschine (heute 189 `getenv`-Stellen für 119 Namen, 85 nirgends dokumentiert, `HV_HZ` zweimal mit verschiedenen Regeln gelesen), erzeugte Swift-Tabelle und Doku; `EngineTuning.swift` enthält nur noch die ausgelieferten Abweichungen; nie gelesene Knöpfe fallen weg.
- Danach reine Datei-Teilungen im Kern entlang der Nähte (`translate.c`, `dispatch.c`, `share.c`), je ein Commit.
- **Optionaler Versuch (ein Anlauf):** echter macOS-Start in CI mit dem Mac-Werkzeug `hengevm` als Ende-zu-Ende-Test und Zählerquelle ohne Gerät — nur, wenn der Runner genug Plattenplatz hat; sonst gestrichen.

---

## Abschluss
1. **Drei unabhängige Prüfer parallel** (Kern · App · Sicherheit), jeder mit dem Auftrag, Fehler zu finden; jeder bestätigte Fund: erst Test, dann Behebung.
2. **Eigene App-Kennung** `io.github.cxecutives.solstice` (+ `.JITHelper`) im Schluss-Build: damit ist auch technisch nichts mehr „Henge“. Folge: Der neue Build ist für iOS eine neue App — der jetzige Mac wird nicht übernommen. Das nutzen wir als Abnahmetest der ganzen Kette (Download → Installation → Start → Fortsetzen).
3. Volle Prüfung grün → `out/Solstice.ipa`; `HANDOFF.md`, `MAP.md`, `README.md`, `NOTICE` aktuell; nur `main`, keine Arbeitsordner.
4. **Du:** alte App löschen, Schluss-Build mit Impactor aufs iPhone 16 Pro **und** iPad Air 4, macOS installieren, Set Up im Mac einmal ausführen, 15 Minuten benutzen. Ich lese beide Logs: keine Abstürze, Zähler gegen die Tabelle oben, Speicher auf dem Air 4.

## Entscheidungen, die ich getroffen habe (sag es, wenn du eine anders willst)
- **Neue App-Kennung im Schluss-Build** → macOS wird am Ende einmal neu installiert (~1 h, läuft von selbst). Alternative: Kennung `com.henge.app` behalten (unsichtbar außer in Impactor), dann bleibt der jetzige Mac.
- **Lautstärketasten-Klick, Autopilot, Farbtest, „Mac-Apps“, alte JIT-Wege, iOS < 26** fallen weg.
- **„Fortsetzen“ wird Vorgabe;** Code-Cache 1 GB auf 8-GB-Geräten; neue Bildschirm-Vorgaben wie in der Tabelle.
- **Herkunftszeile** unter Einstellungen → Info und in der README; sonst steht überall Solstice.
- Im Mac ist nach dem Update **einmal „Set Up“ neu auszuführen** (neue Namen, alte Einträge werden entfernt).

## Bewusst nicht in diesem Durchlauf
| Was | Warum |
|---|---|
| Tahoe 26 / macOS 27 | deine Entscheidung; braucht eine Versions-Weiche (eine Sequoia-Verbesserung würde bei 27 den Bildschirm 60×/s abschalten) und eigene Geräte-Logs |
| Größere Netz-Pakete, Segment-Abnahme (TSO) | Verhalten von Apples Treiber unbekannt, hoher Aufwand; erst wenn die neuen Zähler zeigen, dass es lohnt |
| Umschalten der Auflösung im laufenden Mac, P3-Farbraum | unerforschte Register, hohes Risiko |
| Vorübersetzung auf Sparkernen, Register nur bei Bedarf sichern, Profil-Kompilierung | Risiko stiller Rechenfehler bzw. braucht Geräteprofile; nach der neuen Messung neu bewerten |
| Interne Namen (`henge_vm_*`, Ordner, Schlüssel) | ~850 Stellen, niemand sieht sie |

## Kritische Dateien
`core/{mmu,sysreg,codecache,translate,dispatch,machine,light}.c`, `core/{cpu,machine}.h`, neu `core/knobs.def`, `core/stats.c` ·
`devices/{pvg_metal.m → 6 Dateien, pvg_lite.c, vmapple.c, gicv3.c, xhci.c, virtio_net.c, virtio_blk.c, virtio_snd.c, virtio_input.c}` ·
`host/{vm.c, net_slirp.c, share.c, audio_mac.c, disk.c, snapshot.c}` · `tools/henge-agent.m` ·
`ios/Henge/{Trackpad,Input,Hardware→6 Dateien,SessionView→3,SettingsView,MacSettingsView,Installer,RangedDownload,InstantResume,KeepAlive,HengeLog,BootDisplay,Machines,Theme,EngineTuning}.swift`, neu `Brand/Strings/Settings/DeviceProfile/Engine.swift` · `ios/Henge/JIT/*`, `ios/Henge/Native/henge-vm.{c,h}` · `ios/project.yml`, `Makefile`, `.github/workflows/build-henge.yml`, `tools/{check.sh,regen.sh,map.py,WHERE.md}` · `CLAUDE.md`, `HANDOFF.md`, `README.md`, `NOTICE`.
Wiederverwendet: `hv_ijc_drop_code_page` (`mmu.c:1001`), Absolut-Zeiger (`xhci.c:129-158`), Trackpad-Taste `henge_vm_touch_button`, GPIO-Ein/Aus-Knopf (`pl061`), Uhr-Abfluss für Ton (`virtio_snd.c:225-236`), GPU-Rücklese-Test `HV_PVG_GPU_TEST`, reine Swift-Tests nach dem Muster `tests/test_device_identity.swift`.

## Verifikation
- **Pro Helfer:** nur berührte Tests (CI, parallel), je Punkt ein neuer Test; Übersetzer/MMU zusätzlich Differential-Fuzzer; Registerschutz-Prüfung (SIMD-Gate) bleibt Pflicht.
- **Struktur:** Sperren per `grep` in CI (keine Textliterale/Schlüssel außerhalb der Kataloge, kein „Henge“ in sichtbaren Texten, kein `getenv("HV_` außerhalb der Tabelle), `regen && git diff --exit-code`, `-Werror`.
- **Oberfläche:** Bildschirmfotos aus dem Simulator-Job (Vorher/Nachher für dich).
- **Gerät:** Build 1 (Zähler-Vergleich gegen die Messwert-Tabelle) und Schluss-Build (frische Installation auf iPhone und iPad Air 4, Fortsetzen, Ton nach Unterbrechung, Rechtsklick, deutsche Tastatur, Bildschärfe).
- **Alltagstest im Mac (Teil der Abnahme):** ein Programm aus dem Netz installieren und benutzen — Claude Code im Terminal
  (Installation, Anmeldung, ein Befehl), dazu Chrome oder VS Code; Datei über den geteilten Ordner hin und zurück, Kopieren/Einfügen
  zwischen iOS und Mac, Ton in Safari. Was dabei hakt, wird vor „fertig“ behoben oder ehrlich als Grenze benannt.
- **Fertig heißt:** alles gemergt, drei Prüfungen ohne offenen Fund, volle Prüfung grün, Schluss-IPA installiert und auf beiden Geräten benutzt, Übergabe aktuell.
