# Solstice — der schnellste Henge-Fork (privat, nur für dich; iPhone 16 Pro zuerst)

## Context
Ziel: macOS **und** iOS/iPadOS auf deinen Geräten, so schnell wie technisch möglich. Basis: Henge (Leviidev/Henge, GPL-2.0; Engine C/ASM, App Swift, GPU-Replay über Metal), Stand upstream main `7b55730`. Upstream merged seit 12.11. nichts mehr, CI auf main ist kaputt, 8-GB-Standardwerte sind zu hoch, Übersetzer und Geräte haben große, im Code belegte Reserven.
**Solstice** = privates Repo `CXecutives/Solstice`, einziger Nutzer: du. Keine Messungen/Doku für andere, keine Veröffentlichung.
Geräte: **iPhone 16 Pro** (A18 Pro: 2 P- + 4 E-Kerne, 8 GB, iOS 27.2.1, ~51 GB frei) = Hauptgerät; **iPad Air 4** (A14: 2 P- + 4 E-Kerne, **4 GB**, iPad13,1/13,2) = aktuell einziges iPad → **muss gut laufen**; später **iPad Pro M4/M5** (gleiche Codepfade, nur Tabellenwerte). Untergrenze A14/M1. Ziel: auf jedem iPad ab A14 und jedem neuen Gerät einfach und schnell. Kostenlose Apple-ID, nur Windows-PC.
Grundlage: Code-Analysen (Übersetzer, Grafik/IO/System, Speicher, Plattform), Triage aller ~80 offenen PRs und aller 234 Forks, Quellcode von SideStore/AltStore/iloader/xtool.

## Arbeitsregeln (aus deiner CLAUDE.md, gelten für die ganze Umsetzung)
- **Leitsatz:** maximal Zeit/Aufwand sparen, ohne an Qualität zu sparen. Jeder Schritt muss Leistung, Stabilität oder Einrichtung verbessern, sonst fällt er weg.
- **Machen statt fragen:** Klares mache ich und nenne es im Bericht. Fragen nur bei Richtung/Teurem/Unumkehrbarem, gebündelt, mit Empfehlung. Wartet etwas auf dich, arbeite ich am Rest weiter.
- **Tempo:** sofort anfangen, Plan unterwegs verbessern; CI-Läufe im Hintergrund; **zuerst liefern, was du sehen kannst** (laufendes Solstice), Tiefenarbeit danach. Nach 2 Fehlversuchen derselben Idee: Ansatz wechseln oder kurz melden.
- **Tests gezielt:** pro Änderung nur berührte Engine-Tests; volle Prüfung einmal am Blockende; Exit-Code entscheidet. Logikfehler: erst Test, der ihn zeigt, dann Fix.
- **Struktur:** eine Quelle pro Entscheidung (alle Engine-Standardwerte in **einer** Tabelle `ios/Henge/EngineTuning.swift`; Geräte-Grenzwerte in einer Gerätetabelle statt verstreut, z. B. die vier vCPU-Stellen); nichts hartcodiert; kleine Commits; **was wegfällt, fällt ganz weg** – Optimierungen ersetzen den alten Pfad statt hinter einem Schalter daneben zu leben (vorhandene upstream-Knöpfe bleiben).
- **Nicht raten:** jede Änderung gegen den Code der benutzten Version; vor Umbenennen jede Verwendung suchen.
- **Feste Versionen:** Xcode im Workflow gepinnt, Husk auf Tag `3.4`, Actions mit Version.
- **Performance:** erst messen, dann den gemessenen Engpass beheben – mit Bordmitteln (HV_STATS-Log, hvprof), kein eigenes Benchmark-System.
- **Helfer:** Kleines direkt. Nur große, unabhängige Teile (z. B. Übersetzer-Umbau vs. GPU-Replay) an Helfer in eigenen Worktrees, Opus; danach zusammenführen, Worktree löschen. Keine Audit-Runden.
- **Grenzen:** Pushen nur ins private `CXecutives/Solstice` – **die Freigabe dieses Plans gilt als dein Wort dafür**; nichts veröffentlichen. **Keine Kosten:** private Repos haben im Free-Tarif ~200 macOS-Minuten/Monat → Builds schlank (~5 min), gebündelt, nur auf Knopfdruck; ist das Kontingent leer, stoppt GitHub ohne Kosten (keine Zahlungsart/Budget anlegen). Keine Schlüssel/Passwörter lesen oder committen.
- **Grundausstattung** (einmalig, klein): Projekt-`CLAUDE.md` (was, Befehle, Grenzen), Prüfbefehle `tools/check.sh` (berührt) / `tools/check-all.sh` (Blockende), `HANDOFF.md` (Stand, Entscheidungen, Nächstes). Keine weitere Doku.
- **Sitzung:** Umsetzung in einer **frischen Sitzung** im Ordner `C:\Users\owner\Documents\Solstice`, dieser Plan als Übergabe; nach jedem großen Block neue Sitzung mit aktueller `HANDOFF.md`.
- **Probleme vorbeugen:** vor zerstörenden Git-Schritten `git status`; Upstream-Daten nie verwerfen; Gast-Daten (Mac-Disk) nie ohne Sicherung anfassen.
- **Fertig heißt** (pro Block): tut, was verlangt war; Randfälle bedacht (kein Platz, Abbruch, kein JIT, App im Hintergrund); volle Prüfung grün; Branches sauber; `HANDOFF.md` aktuell. Erst dann „fertig“.
- **Bericht:** Deutsch, kurz, ehrlich, mit echten Zeiten.

## Dein Aufwand
- **Einmalig (~30 min):** Einrichtung (unten).
- **Pro Block (~5 min + Nutzung):** neue IPA installieren → Solstice ~15 min normal benutzen. Logs kommen **automatisch per Live-Log-Stream an den PC** (not-nullptr `616435e`); ich werte sie selbst aus.

---

## Sideloading (Leistungsfaktor)
Wichtigster Hebel beim Signieren ist **`increased-memory-limit` (IML)**: Speichergrenze ~3 GB → ~6 GB (Gast-RAM, Code-Cache, keine Jetsam-Abstürze).
- **SideStore** verliert IML bei kostenlosen Konten – auch 0.7.0-alpha (`allowedFeatures` für Free-Teams = nur appGroups/interAppAudio; SideStore #1616 offen).
- **AltStore Classic 2.3** (30.09.2026, neuer als SideStores letztes Release, „Remote AltServer“ = PC-frei nach Einrichtung) behält IML.
- iloader 2.4.2 setzt IML beim Import; ob SideStores Auffrischen es wieder entfernt, ist offen.
- xtool (baut Henge nicht, verwirft IML) und Impactor (Auffrischen nur vom PC) scheiden aus.
→ **Entschieden: AltStore Classic 2.3 + AltServer für Windows + Remote AltServer.** Notfall-Rückfall: SideStore + iloader-Import / GetMoreRam.
Fest: **LocalDevVPN 1.3.0**; JIT über den **eingebauten StikJIT-Helfer** mit Kopplung auf dem iPhone; Anisette `mac-ani.jkcoxson.com`; iTunes + iCloud direkt von apple.com; Reserve-Apple-ID.

---

## Block 1 — Solstice läuft auf deinem iPhone (zuerst sichtbar)
**1.1 Repo + Build**
- Privates Repo `CXecutives/Solstice`, Henge mit Verlauf spiegeln (`git push --mirror`), upstream als Remote; Klon `C:\Users\owner\Documents\Solstice`, Git-Identität `203267938+CXecutives@users.noreply.github.com`, `.gitattributes` (`*.sh text eol=lf`).
- CI-Fix `Makefile:192` → `env -u SDKROOT -u IPHONEOS_DEPLOYMENT_TARGET $(MAKE) -C tl …`.
- `.github/workflows/build-henge.yml`: Husk `ref: 3.4`, Xcode pinnen, Caches (Husk-Deps, Restore-Stack), `make -j`, ohne `.tipa`, `HOMEBREW_NO_AUTO_UPDATE=1`, nur manuell; Ausgabe IPA-Artefakt; bei Fehler Build-Log hochladen.
- Version per `plutil -replace` in App- und `HengeJITHelper.appex`-Info.plist; Anzeigename „Solstice“; Bundle-ID bleibt `com.henge.app`.
- **`-mcpu=apple-a14`** (heute apple-a7 ohne LSE → alle C-Atomics als LL/SC-Schleifen; `Makefile:136`). Vorher **SIMD-Gate**: Helper-Thunks (`host/enter.S:226-246,298-317,375-394`) sichern q0–q31 nicht → Skript prüft per `otool -tv`, dass aus `hv_tlb_refill`/`hv_ijc_resolve` keine neuen memset/memcpy/SIMD-Kanten entstehen; `kva_note`-getenv/calloc in die Init verschieben (`core/mmu.c:604-611`).

**1.2 Übernommene Fixes** (je ein Commit „pick #N“): #214 (am Leben bleiben, Ballon, 8-GB-Grenzen), #121 (Adress-Reservierungen vor Gast-RAM freigeben; größtes Mapping 2,5 → 16,9 GB), not-nullptr `4aed49b` (Code-Cache ohne EVA ≤ 1 GB), #166 (JIT-Port nur vom eigenen Gerät), #207 („signal 4“-Absturz), #188 (GPU-Absturz + Metal-Pipeline-Archiv, `HV_PVG_ARCHIVE_MB=256`), #187 (Mehr-Ebenen-Oberflächen ohne Hash/memcpy), #161 (Interrupt-Sturm 20–48K/s weg; gilt für macOS 15 → **nur Sequoia 15.6.1 anbieten**, `Installer.swift:29-34`), #142, #137, #73, #183 (Mac startet nach Installation ohne App-Neustart; Konflikt `henge-vm.c:36-47`: beide Blöcke), #215 + #109 (logische Auflösung 1536×864 = 64 % Pixel), #209, abetinoco `e4798b0`, not-nullptr `616435e` (Live-Log), Monolith `51d4d82` (eigener Pairing-Hostname).

**1.3 Funktion + Einrichtung** (Automatiken einmal pro App-Start)
- Erster Start ohne Mac → Install-Tab; nicht gekoppelt → Kopplungsseite mit Hinweis „erst iPhone-Code, dann Solstice-Code; WLAN an“, ein Tipp „Kopplung starten“ (`JITSetupView.swift:45-53`).
- Nach Kopplung Flag setzen; wenn Solstice wieder aktiv: VPN → `prepareBuiltIn` → `enableBuiltIn` verkettet (`JITSetup.swift:313-320,392-397`). Auto-JIT standardmäßig an (Leser `JITSetup.swift:181` + Toggle `SettingsView.swift:5`); `enable()` verbindet LocalDevVPN vorher.
- Download sofort ohne JIT (`InstallView.swift:124-125`, neuer Phase-Fall „Warte auf JIT“, `busy` erweitern); „Download danach löschen“ an.
- Nach Installation: `unsetenv("HV_WRITE_CACHE")` direkt nach `henge_vm_install` (sonst 2–3× langsamerer 1. Boot, `Installer.swift:229`), auf `henge_vm_can_start()` warten, neuen Mac starten; bei Restore-Fehler VM stoppen.
- Letzten Mac automatisch starten, sobald JIT bereit (Guards; nach 2 Fehlstarts aus + sicherer Modus `HV_SAFE`).
- **Festplatte (128-GB-iPhone):** Disk-Obergrenze aus freiem Speicher (~48 GiB statt fest 64; eine Konstante für `Installer.swift:199-214` + `Machines.swift:125`); Wächter < 6 GB frei → Mac pausieren + Hinweis.
- Speicher: IML-Status sichtbar; Standardwerte aus der Gerätetabelle (Block 5) schon ab Block 1.
- **iPad Air 4 (4 GB) lauffähig machen** – der knappste Fall, deshalb früh:
  - Profil „wenig Speicher“: Gast-RAM 2 GB (Ballon aktiv), Code-Cache 512 MB, 2 vCPUs, 1280×720, schlankes macOS Pflicht; ein iPad 10 mit gleichem Chip/RAM stürzte bisher im Setup-Assistenten ab (#158) → genau dort messen.
  - Speicher sparen, wo er heute verschwendet wird (vorgezogen aus Block 2/3): IJC-Tabellen nur für gestartete vCPUs (heute 8×64 MB), Cache-Verwaltung ~0,75× → ~0,4× der Cache-Größe, Gast-RAM vor den JIT-Metadaten reservieren.
  - JIT-Erkennung für iPad13,x prüfen (TXM-Tabelle `HengeLog.swift:374-386` behandelt iPhone/iPad derselben Chip-Generation verschieden) – sonst meldet Solstice „JIT an“, obwohl es fehlt.
  - Erster Log vom Air 4 entscheidet die finalen Werte.

**1.4 Sofort-Leistung** (Standardwerte in `EngineTuning.swift:12-19`)
- `HV_SYNC_WAIT=1` (TLBI-Warten 76 % → 4–9 % eines Kerns), `HV_RANGE_DROP=256`, `HV_STATS=30`.
- Teure Statistik-Pfade nur bei Diagnose (`dispatch.c:156-165,200-207,365-368,643-663,1098-1114`, `memop.c:303-337`, `machine.c:253-268`, `translate.c:1983-1987`).
- GPU-Hygiene: `getenv` aus der Ressourcen-Schleife (`pvg_metal.m:2107`), `NSUserDefaults` pro Frame cachen (`:21-36,:2545`), Shader-Dumps nur bei Bedarf (`EngineTuning.swift:30`), blockierte Kanäle bei jeder Türklingel neu prüfen (`pvg_lite.c:774-776`; 1–10-ms-Hänger weg).
- Netz: Wake-Pipe nur bei leer→nicht-leer (`net_slirp.c:111-117,254-263`).
- **Schlankes macOS** automatisch beim „Set Up“ (`host/share.c:583-654`): Animationen, Siri, Vorschläge, Handoff aus; mit Passwort: `mdutil -a -i off` (Hauptursache des ~15-min-Login-Sturms), Time Machine/Auto-Updates/Power Nap/Diagnose aus; mit Festplattenvollzugriff: Transparenz + Bewegung reduzieren. Im Setup-Assistenten: keine Apple-ID, FileVault aus, automatische Anmeldung an.

**Fertig, wenn:** auf iPhone 16 Pro **und** iPad Air 4 ein Tipp aufs Icon bis zum macOS-Schreibtisch führt, Log zeigt IML an, 15 min ohne Jetsam/Panic. Danach ein hvprof-Boot → ordnet Block 2–4 nach echtem Engpass.

## Block 2 — Übersetzer (Kern der Geschwindigkeit)
Jede Änderung ersetzt den alten Pfad; abgesichert durch gezielte Engine-Tests (`tests/*_programs.S`) + **Differential-Fuzzer** (nativ vs. JIT, `tests/harness.h:130-160`, mit SIMD-Sentinels) auf dem macOS-Runner.
- Knopf-Plumbing: `knobs_init()` auch in `hv_machine_init` (`machine.c:49-53`).
- **Statistik pro CPU** (128-B-ausgerichtet, `machine.h:156-212`): kein Cache-Line-Pingpong P↔E; 2–8 % bei 3–4 vCPUs.
- **Größerer TLB** (Tomba247 `2797ea5`) am größten Hotspot (~35 % der Zeit im übersetzten Code).
- **Kompakte Slow-Paths:** ~18 Wörter pro Speicherzugriff → 4 + Record + gemeinsamer Thunk (`translate.c:38-54,1766-1819`, `enter.S`) → −25–30 % Code, ~1,4× seltener Cache-Flush, 15–25 % weniger Übersetzungszeit; dazu Tomba247 `a3ca070` (Exit-Stubs), `a218623` (Literal-Pool).
- **Leichter Refill** auch für Pre/Post-Index + RMW (`translate.c:1087`).
- **Groups v2** (Kopien in den kalten Teil): +11 % Bildrate bei +2–4 % statt +15 % Code.
- **Systemregister inline** (`translate.c:1479-1559`; Tomba247 `2f8b1e0`/`2d9fa9d`), CLREX inline, IJC per LDP, ADRP+ADD falten.
- **TLBI-Warten kürzen:** übersetzende CPU zählt nicht als „live“, Anfragen vor TTBR0-Wechsel abarbeiten (`dispatch.c:157-160`, `sysreg.c:203`).
- **Paravirtuelle Spinlocks:** macOS fragt beim Boot nach VM-Lock-Hilfe (`lck_init_pv`; UID 0x8300ff01, WFK 0xc3000005, KICK 0xc3000006), Henge antwortet „nein“ (`exception.c:208-211`) → implementieren + `kern.ticket_lock_spins` im Gast senken.
- **Fristgesteuerter Kicker** statt 1000 Wakeups/s (`host/vm.c:344-351`): vBlank auf festem Raster als Gerätefrist (`pvg_lite.c:714-732`), Kick pro vCPU auf ihre Timer-Frist, Geräte-Polls nur bei Arbeit, 20-ms-Sicherheits-Tick → ~60/s.
- **Kleinere Cache-Verwaltung** (`machine.h:43-54`, `machine.c:101-119`): ~930 → ~510 MB → mehr Gast-RAM.
- **vCPU-Standard aus P/E-Kernen** (Gerätetabelle): iPhone 3, iPads 4–5.

## Block 3 — Grafik, Speicher, Ein-/Ausgabe
- **GPU-Replay:** Objekt-Cache als C-Array + Seitenwalk-Memo (`pvg_metal.m:1108-1170`; 0,3–1,5 ms/Frame), Command-Buffer in-place (`:2136-2137`), `refresh_pages` abkürzen (`:320-338`), **Cursor als eigene Core-Animation-Ebene** (`:2842-2855`), Präsentation an ProMotion (1/60), undurchsichtige Ebene (`BootDisplay.swift:111-154`).
- **Speicher/Adressraum:** Gast-RAM vor JIT-Metadaten reservieren, IJC-Tabellen nur für gestartete vCPUs, Freigabe im Fehlerpfad (`vm.c:276-292`, `machine.c:104-131`); Ballon vor Hintergrund-Pause; Prefault lesend (`vmapple.c:216`).
- **Disk:** `preadv/pwritev` (`virtio_blk.c:27-47`), Tiefe 8 (`virtio_blk.h:30`), leere Flushes sofort, **TRIM** über `F_PUNCHHOLE` (`:268`).
- Audio-Wakeups nur bei fertigem Puffer (`virtio_snd.c:266`), feste QoS für Hilfs-Threads, UI-Schleifen pausieren während ein Mac läuft.

## Block 4 — Strukturumbauten (nach hvprof)
- **Segmentierter, generationeller Code-Cache ohne Stillstand** (auf #186): keine 13–29 %-Einbrüche nach Flushes.
- **Schnelle SVC/ERET-Thunks** (`translate.c:1728-1736`): 3–6 % bei GUI-Last.
- **Vor-Übersetzung auf E-Kernen** (heiße Ziele, Warmstart relativ zum Kernel-Slide).
- **Thermik-/Stromspar-Politik live** (Verschwendung kappen, Präsentation 1/30 bei Hitze).
- **PGO + ThinLTO**, nur wenn hvprof ≥ ~15–20 % Zeit im Host-C zeigt.

## Block 5 — iPad-Bedienung (Air 4 jetzt, Pro M4/M5 später)
#170, #167, #123 (Trackpad-Klick, flüssiges Scrollen, ein Zeiger in Stage Manager). **Eine Gerätetabelle** (`Hardware.swift`) mit Standardwerten je Gerät, abgeleitet aus RAM und P/E-Kernen:
| Gerät | Gast-RAM | vCPUs | Code-Cache | Bildschirm |
|---|---|---|---|---|
| iPhone 16 Pro (8 GB, 2P+4E) | 3 GB | 3 | 1 GB | 1536×864 |
| iPad Air 4 (A14, 4 GB, 2P+4E) | 2 GB + Ballon | 2 | 512 MB | 1280×720 |
| iPad mit M1–M3, 8 GB | 3 GB | 4 | 1 GB | Performance |
| iPad Pro M4/M5 8 GB | 3 GB | 4 | 1 GB | Performance |
| iPad Pro M4/M5 16 GB | 6–8 GB | 4–5 | 1 GB (ohne EVA Obergrenze) | Performance |
Unbekannte/neue Geräte: Werte automatisch aus RAM und P/E-Kernen. Startwerte; nach dem ersten Log des Geräts justiert. Bei der Kaufentscheidung: iPad Pro mit 16 GB (1/2 TB) bringt für Solstice am meisten.

---

## Einrichtung (einmalig, du)
1. iPhone: Gerätecode, WLAN; **LocalDevVPN** öffnen, verbinden, erlauben.
2. PC: iTunes + iCloud direkt von apple.com.
3. Sideload-App nach Entscheidung (AltServer → AltStore Classic 2.3 → Remote AltServer, oder iloader → SideStore), separate kostenlose Apple-ID.
4. iPhone: Profil vertrauen, **Entwicklermodus** an → Neustart.
5. Solstice-IPA installieren, „App-Erweiterungen behalten“.
6. Solstice öffnen, „Lokales Netzwerk“ + „Mitteilungen“ erlauben, geführt koppeln, macOS installieren.
Dauerhaft: alle 3–5 Tage „Alle aktualisieren“; macOS vorher herunterfahren.

## Was bleibt (Apple-Grenzen)
Einmal PC · Entwicklermodus · Kopplung mit Code + PIN · JIT bei jedem Start (~13 s, automatisch) · LocalDevVPN nach Neustart · Setup-Assistent von Hand, keine Apple-ID in macOS · 7 Tage / 3 Apps · Mac pausiert, wenn Solstice nicht sichtbar · 2 P-Kerne + Hitze = Obergrenze · Lizenz-Grauzone (Eigengebrauch).

## Bewusst weggelassen
Benchmark-/A/B-System, Release-Statistik, öffentliche Quelle, Fork-Doku, eigene Upstream-PRs · Rust-Neuschrieb · xtool · EVA (nur bezahlt) · eigenes VPN (nur bezahlt) · direkt abgebildeter Gastspeicher (5–10× langsamer) · Code-Cache über Kaltstarts speichern · schädliche/wirkungslose Compiler-Flags · Gast-P/E-Topologie, Boot-Args, SIP-Tuning · vCPU-Duty-Cycling, Realtime-Threads · 120 Hz Gast.

## Kritische Dateien
`core/{translate,dispatch,mmu,machine,sysreg,exception}.c`, `core/machine.h`, `host/{enter.S,vm.c,share.c,net_slirp.c}`, `devices/{pvg_metal.m,pvg_lite.c,virtio_blk.c,vmapple.c}`, `ios/Henge/{EngineTuning,Installer,InstallView,HengeApp,SettingsView,Hardware,Machines}.swift`, `ios/Henge/JIT/{JITSetup,JITSetupView}.swift`, `ios/Henge/Native/henge-vm.c`, `Makefile`, `.github/workflows/build-henge.yml`, `ios/scripts/package_ipa.sh`, `tests/`.

## Verification
- **Pro Änderung (CI, gebündelt):** berührte Engine-Tests; Übersetzer-Änderungen + Differential-Fuzzer; SIMD-Gate; iOS-Build grün.
- **Blockende:** volle Engine-Suite einmal, IPA bauen; du nutzt Solstice ~15 min; ich lese den Live-Log: IML an, Gast-RAM-Pfad, keine Jetsam/Panics, Flushes/min, TLBI-Wartezeit, Wakeups/s, Thermik. Block 1 zusätzlich: Ein-Tipp-Start bis Schreibtisch.
- Gerätefehler → `HV_SAFE` bzw. vorige IPA; Ursache als Test nachstellen, dann beheben.

## Detailwissen (vor jedem Block lesen, nur den passenden Teil)
`docs/solstice/`: `pr-triage.md` (PR-Konfliktkarte, Pick-Reihenfolge), `setup-flow.md` (Einrichtungs-/Startablauf mit Zeilen), `perf-knobs.md` (alle HV_*-Knöpfe), `translator.md` (Übersetzer O1–O22 im Detail), `gpu-io-system.md` (Grafik/IO/Strom/Gast-Tuning), `gapfind.md` (Ergänzungen: SIMD-Gate, -mcpu, PV-Spinlocks, MEM-1..12, GFX-1..17), `tools-forks.md` (Werkzeuge, Fork-Commits mit Links), `plan-review.md` (Mängel + Fixes zu 1.x). Pfade dort beziehen sich auf den Repo-Stamm (`7b55730`). Bei Widerspruch gilt PLAN.md.
