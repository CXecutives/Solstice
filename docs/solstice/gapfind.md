# Ergänzungen (Lückensuche, 13 Agenten, geprüft)

> Benchmark-/A/B-Teile (MP-1, MP-3, Release-Regel, perf.yml-Gates) sind laut PLAN.md bewusst gestrichen. Wo PLAN.md abweicht, gilt PLAN.md.

# Ergänzungen zum Hyper-Plan (Solstice)

**Legende:** P0 = vor allem anderen, P1 = Release 1–2, P2 = nach Messung, P3 = nur wenn Daten es tragen. „spek.“ = Schätzung ohne Messung.

**IDs:** TC = Toolchain, MEM = Speicher, TR = Übersetzer, PLAT = Gast/Plattform, GFX = Grafik, MP = Mehrkern/Thermik/Energie. Eingearbeitet sind nur die geprüften Befunde, mit den Korrekturen der Gegenprüfung.

**Format je Punkt:** Titel — Mechanismus (Datei:Zeile) — Gewinn — Risiko — Knopf — Prüfung.

---

## 1. Ergänzungen nach Phase

### Phase 0 — Fundament

**Toolchain / Build**
- **[P0] TC-01 Schutz für die Pfade, in denen die Gast-SIMD-Register noch leben**
  - Mechanismus: `hv_helper_thunk`, `hv_ijc_thunk` und `hv_xjump_thunk` sichern nur x0–x17 und NZCV. Danach rufen sie `hv_tlb_refill` bzw. `hv_ijc_resolve` auf, während q0–q31 des Gasts noch in den Host-Registern stehen (enter.S:226-246, :298-317, :375-394; mmu.c:20-22, :853-856).
  - Jeder Compilerwechsel und jedes neue Flag (-O3, LTO, PGO, -mcpu) kann dort `memset`/`memcpy` oder `__llvm_profile_*` einfügen. Folge: stille Korruption von Gast-FP/SIMD.
  - Gate auf dem **gelinkten Endbinary**:
    - Aufrufgraph ab `_hv_tlb_refill` und `_hv_ijc_resolve`.
    - Die heutigen, nur zur Laufzeit abgesicherten Kanten als Baseline committen: `tlb_fill→kva_note→getenv/calloc` (mmu.c:604-611) und `hv_ijc_fill→hv_ucode_add→memset` (mmu.c:201-212, :914).
    - Fehler bei jeder neuen Kante und bei jedem SIMD-Operanden, Regex `\b[vqdshb][0-9]{1,2}\b`.
    - Das Gate läuft für jeden Build-Flavor; `-fprofile-use` schaltet PGSO ein und kann Kopien in libc-Aufrufe verwandeln.
  - Dazu:
    - `kva_note`-getenv/calloc in die Maschinen-Initialisierung verschieben.
    - Dynamischer Test im Differential-Fuzzer: Sentinels in q0–q31, refill- und IJC-lastiges Gastprogramm, danach vergleichen.
    - Für PGO-gen `-mllvm -disable-vp` auf mmu.c.
  - Gewinn: Voraussetzung für alle Toolchain-Punkte.
  - Risiko: keins (nur prüfend).
  - Knopf: CI-Gate `HENGE_SIMD_GUARD`.
  - Prüfung: CI, mit einem absichtlich eingebauten `memset` muss das Gate rot werden.
  - Aufwand: 0,5 Tag.
- **[P1] TC-07 Build-Flavors**
  - Mechanismus: Make ignoriert Flag-Änderungen (Makefile:145). Xcodes Pre-Build ruft `make ios-lib` und den Restore-Build bedingungslos auf (project.yml:113-115). Der Bibliothekspfad ist fest (project.yml:63).
  - Umsetzung:
    - `IB ?= build/ios$(FLAVOR)`
    - Stempeldatei `$(IB)/.flags` als Voraussetzung jedes Objekts
    - `HENGE_ENGINE_LIBDIR` in `LIBRARY_SEARCH_PATHS`
    - `?=` für alle `IOS_*`-Variablen
    - `HENGE_SKIP_PREBUILD=1` in CI
  - Falle: im **selben** Commit lösen, sonst baut Xcodes Pre-Build die Flavor-Bibliothek still mit Standard-Flags neu.
  - Gewinn: Korrektheit von A/B- und PGO-Builds.
  - Prüfung: gen- und use-Build im selben Job; otool zeigt keine `__llvm_prf`-Sektionen im use-Build.
  - Aufwand: 2–3 h.
- **[P1] TC-08 Xcode pinnen, Build-Fingerabdruck**
  - Umsetzung:
    - `sudo xcode-select -s /Applications/Xcode_27.x.app` in jedem Workflow (build-henge.yml:32 hat nur das Label).
    - Xcode- und clang-Version, Flag-Set und profdata-Hash ins Info.plist neben `HengeBuildCommit` (package_ipa.sh:45-46) und in die `HENGE-BENCH`-Zeile.
  - Gewinn: Baselines bleiben stabil; die Rohprofile von llvm-profdata bleiben kompatibel.
  - Aufwand: 1 h.
- **[P1] TC-03 + TR-6 (zusammengelegt) `-mcpu` festlegen**
  - Mechanismus: Der iOS-Build hat kein -mcpu (Makefile:133/136) und wird für apple-a7 gebaut, also ohne LSE. Alle C-RMW-Atomics werden LL/SC-Schleifen (z. B. mmu.c:675, :953, :989; memop.c:426-429; translate.c:401). Der Mac-CI-Build (Makefile:3) läuft dagegen mit apple-m1, CI misst also anderen Code als das Gerät.
  - Umsetzung:
    - `IOS_CPU ?=`, upstream leer, im Fork `-mcpu=apple-a14`. Das ist dieselbe Kernfamilie wie die M1-Runner; apple-a13 wäre die risikolose Untergrenze.
    - In Gen- und Use-Build identisch setzen.
    - CI-Guard: `otool -tv` auf mmu.o, memop.o und dispatch.o muss `ldadd`/`cas*`/`swp` zeigen; Abbruch, wenn sich die -mcpu-Familien von iOS und Mac unterscheiden.
  - Gewinn: 0–1 % (spek.); Hauptwert ist die Vergleichbarkeit von CI und Gerät.
  - Risiko: keins, der JIT setzt LSE ohnehin voraus (translate.c:931, :1161-1165).
  - Knopf: `IOS_CPU` (Build-Zeit).
  - Prüfung: zuerst ein lesender `-###`-Schritt, der `"-target-cpu" "apple-a7"` heute bestätigt.
  - Aufwand: 15 min plus Guard.
- **[P2] TC-09 Flag-Achse in der vorhandenen `perf.yml`-Matrix** (kein neuer Job)
  - Achse: O2/O3, ThinLTO, -mcpu, pgo-use.
  - Zusätzlich ein UBSan-Flavor mit `-fsanitize=undefined -fsanitize-trap=undefined`. Er löst per brk aus und ruft keine Laufzeitbibliothek auf, ist also auch für mmu.c sicher.
  - Kein ASan: 2-MB-HvCpu auf dem Stack (Makefile:119), Gast-Mappings mehrerer GB, JIT-Zugriffe ohne Instrumentierung.
  - Aufwand: 0,5 Tag.
- **[P3] TC-11 CI-Tempo**
  - Upstream-äquivalente Schritte ~4,5 min → ~2–2,5 min.
  - (a) `ios/deps` nach Husk-Tag + `fetch_deps.sh`-Hash cachen und meson/ninja/cargo überspringen (brew bleibt für xcodegen, build-henge.yml:62).
  - (b) Restore-Stack nach Inhalt cachen (touch bzw. `HENGE_SKIP_PREBUILD`, build_ios_restore.sh:38).
  - (c) `make -j`.
  - (d) dmg/agent cachen.
  - (e) `.tipa` streichen.
  - (f) `HOMEBREW_NO_AUTO_UPDATE=1`.
  - Tests als eigener Job, der das Release nicht blockiert. Beschleunigt nur den Entwickler, nicht die Geräterunden.
- **[P3] TC-13** No-op- und schädliche Flags → „Bewusst verworfen“ (siehe 2.). Ein lesender CI-Schritt druckt `-###` (target-cpu, stack-protector, frame-pointer) und `-showBuildSettings`.

**Messmethodik (der größte Hebel dieser Phase)**
- **[P0] MP-1 Testrunde 1 ist so nicht durchführbar → A/B innerhalb einer Sitzung + Nachtmodus + A/A**
  - Problem: ~11 Arme × 3 Paare × 2 × ~30 min ≈ **33 h**. Drei Paare erkennen bei σ≈4 % nur Effekte ab ~12–15 %.
  - (a) Live umschaltbare Knöpfe: Autopilot `knob` → `hv_knob_set` → Flush plus Kick (machine.c:38-47, dispatch.c:944-945). A/B daher innerhalb **eines** laufenden Macs:
    - Segmente ≥2× die Refill-Periode des Code-Caches: **120 s, die ersten 20 s verwerfen**, Reihenfolge ABBA BAAB …
    - Gast-Last als Schleife, einmal per Autopilot `type` gestartet. Iterationszähler ≤1×/s zum Host über 10.0.2.4 bzw. den Freigabeordner (host/share.c, tools/henge-agent.m).
    - Auswertung: Wilcoxon bzw. gepaarter t-Test auf Log-Verhältnissen; kein Bootstrap über n=8.
  - (b) Knöpfe, die einen Neustart brauchen (cpus, Cache, Auflösung, RAM): **Nachtmodus**, ≥4 Boots je Arm, ABBA, Abkühl-Gate, erster Boot nach App-Start wird verworfen.
  - (c) Erster Gerätelauf = **A/A**, 8 Paare, misst σ. Daraus n ≈ ((1,96+0,84)·√2·σ/δ)².
  - Gewinn: 10–20× mehr Entscheidungen pro Runde, jede mit bekannter Nachweisgrenze.
  - Knopf: `BENCH_MODE=interleave|overnight`, `BENCH_SEG_S=120`, `BENCH_DISCARD_S=20`.
  - Prüfung: CI-Unit-Test der Auswertung mit linearer Thermik-Drift (ABBA muss sie aufheben); A/A auf dem Gerät mit Median-Verhältnis innerhalb ±1 %.
  - Aufwand: 2–3 Tage.
- **[P0] MP-3 Vorbedingungen des Benchmarks automatisch prüfen**
  - Automatisch in der App:
    - Start verweigern bei Stromsparmodus (A18 Pro: −61 % Single-Core, −52 % Multi-Core).
    - Segment ungültig bei Wechsel von LPM, scenePhase, thermalState oder Ladegerät.
    - Akkustand und -zustand je Segment loggen, Anstieg markieren.
    - Helligkeit setzt die App (0,35; Minimum beim Abkühlen).
    - Thermik-Gate per Frequenz-Probe (≥97 % der ersten kalten Probe, plus nominal ≥120 s, maximal 15 min) statt nur „nominal“.
  - Manuell, höchstens 3 Punkte:
    - kein LPM;
    - vorher in SideStore „Alle aktualisieren“, dann Hintergrundaktualisierung aus;
    - entweder ohne Kabel mit ≥40 % oder am Kabel mit bereits erreichter 80-%-Grenze.
  - Bluetooth, Mobilfunk und Fokus werden nur geloggt.
  - Knopf: `BENCH_BRIGHTNESS`, `BENCH_ALLOW_CHARGING=0`, `BENCH_MIN_BATT=40`, `BENCH_PROBE_MIN=0.97`.
  - Aufwand: 0,5 Tag.
- **[P1] MP-2 Kennzahlen unabhängig vom Takt**
  - Zusätzlich zu Zeit/Arbeit und nJ/Arbeit (Plan 0.3): **Zyklen und Instruktionen pro Arbeit, nur auf den vCPU-Threads** (`thread_selfcounts` oder `PROC_PIDTHREADCOUNTS`). Spin- und Wartezähler abziehen oder markieren (dispatch.c:255-270, :475-481, :864-871; machine.c:250-280).
  - Hauptkennzahl nur für Code-Größen- und Übersetzer-Knöpfe bei wenig Konkurrenz.
  - **blocks/s nicht für Übersetzer-Knöpfe** (SessionView.swift:654-655, :685), weil SUPERBLOCKS und GROUPS die Blockgröße ändern.
  - „3–5× weniger Varianz“ ist spekulativ, bis das A/A es zeigt.
- **[P1] MP-5 Scheduler-Telemetrie**
  - `PROC_PIDTHREADCOUNTS` (=34, proc_info_private.h:197-227): pro vCPU P-Anteil, effektive GHz pro Leistungsstufe, IPC.
  - `ri_runnable_time`/Wandzeit, Histogramm der WFI-Aufwachlatenz, einmalig `sleep_ok` (dispatch.c:246-252).
  - **Label-Bug:** Die Probe in machine.c:257/:266 hält `TH_STATE_RUNNING` für „auf einem Kern“. Mach meldet aber auch wartende, lauffähige Threads so (thread.c:2049-2050). „off a core“ (dispatch.c:675-680) heißt also nur „blockiert“; Verdrängung bleibt unsichtbar. Abhilfe: Fortschritt der user_time zweimal im Abstand von ~20 µs prüfen.
  - Mit **MP-13**: pvpanic-Ereignisse (vmapple.c:304) und Gast-Neustarts je Arm mit vCPU-Zahl, Thermik und Wartezeit auf einen Kern.
  - Knopf: `HV_SCHED_STATS=1`.
  - Aufwand: 1 Tag.
- **[P1] TC-02 hvprof fertigstellen**
  - Blocker 1: `hv_prof_ios_start` macht `if (started++) return;` vor der HV_PROF_IOS-Prüfung (prof_ios.c:155-157). Folge: nur beim ersten Boot einschaltbar, nie abschaltbar.
  - Blocker 2: Thread-Slots werden nie freigegeben (MAX_THREADS 16, :25, :63-66). Nach 3–4 Kaltstarts werden neue vCPU-Threads still nicht mehr abgetastet.
  - Fix:
    - Start/Stopp per Autopilot, Slots pro Boot zurücksetzen.
    - Profilierter Abschnitt als eigener, **letzter** Boot.
    - Auch die Nicht-vCPU-Threads registrieren: virtio_blk.c:217/278, net_slirp.c:324, vm.c:609, pvg-Queues beim ersten Block (pvg_metal.m:2684-2685).
    - Unstripped Binary und dSYM als Release-Asset.
    - `tools/prof_symbolize.sh` anlegen (fehlt im Repo, prof_ios.c:5).
  - Wert: Entscheidet über TC-04 bis TC-06. Bei <15 % Host-C-Anteil bringen PGO/LTO höchstens ~2 %.
  - Aufwand: 0,5–1 Tag.
- **[P1] TR-5 Übersetzer-Statistik vervollständigen**
  - `helper[]` für CLREX, WFE, EXCEPTION, ERET, FPTRAP und UNDEF ausgeben (bisher nur MEM/MRS/MSR/SYS, dispatch.c:599-602).
  - `wfe_timeouts` neben das vorhandene `wfe_waits` (:714).
  - Zur Übersetzungszeit zählen: LDXR, STXR, LDXP/STXP, CLREX, DSB/DMB nach CRm.
  - Laufzeitfrequenz über HV_PROF-Samples (:502-579), nicht inline.
  - Gate für TR-2, TR-4, TR-7, TR-8, TR-10. Aufwand: XS.
- **[P1] MEM-6 Speicher-Telemetrie** (in 0.3 einfalten; #214 liefert die TASK_VM_INFO-Aufschlüsselung schon)
  - Neu:
    - `host_statistics64(HOST_VM_INFO64)` (free, Kompressor-Seiten, purgeable, swapouts).
    - `kern.entitled_max_task_pmem` (bei EPERM loggen).
    - TASK_VM_INFO `page_table` und die no-footprint-Ledger.
    - Gast-`vm_stat` alle 30 s über den Agenten.
    - Spitzen und Minima in `HENGE-BENCH`.
  - Trennt die Jetsam-Ursachen: Prozesslimit, vm-pageshortage, Kompressor, fc-thrashing.
  - Knopf: `HV_GUEST_VMSTAT=30`.
  - Aufwand: 2–4 h.
- **[P0] GFX-1 Telemetrie der GPU-Pipeline**
  - Der heutige Wert „waiting for the GPU“ misst nur `-commit` (pvg_metal.m:2207-2210, bestätigt in #112).
  - Neu:
    - GPU busy (`GPUEndTime−GPUStartTime`, aus #112);
    - Latenz des Completion-Handlers;
    - Türklingel→Stamp p50/p95;
    - Worker-CPU ms/s;
    - Warteschlangentiefe beim Entnehmen;
    - leere CBs/s;
    - `vm_remap`-Aufrufe;
    - Heap- und Texturkopien in Byte/s je Richtung.
  - Ziel ist die **iOS-Perf-Zeile bzw. HENGE-BENCH**, nicht nur stderr.
  - Encode-Kosten liegen bei 0,07–0,67 s pro 2000 Execs (#193 vs. #112).
  - HUD: zuerst iOS Einstellungen › Entwickler › Graphics HUD prüfen; `developerHUDProperties` nur, wenn das fehlt.
  - Knopf: `HV_PVG_STATS=1`.
  - Aufwand: 1 Tag.
- **[P1] PLAT-11 Gast-Labor auf dem macOS-15-arm64-Runner**
  - Der Runner ist ein VZ-Gast. Protokollieren: `sw_vers`, `hw.model`, `csrutil status`, ob `sysctl kern.ticket_lock_spins` existiert (also CONFIG_PV_TICKET), `pmset -g cap`, Namen und Schreibbarkeit der timer_coalesce-Sysctls, `top`-Rangliste der Daemons.
  - Defaults-Schlüssel per `strings` auf die Einstellungs-Extensions finden, nicht per UI.
  - SIP und App Nap sind dort verstellt (NSAppSleepDisabled), Ergebnisse dazu sind nur Hinweise.
  - Spart mehrere Geräterunden. Aufwand: 0,5 Tag.
- **[P1] MEM-4 Teil 1: CI-Probe auf Doppelzählung der RW-Sicht**
  - Mechanismus: Im SPTM-pmap gutschreibt jeder neu gültige PTE einer internen Seite den phys_footprint, ohne Deduplizierung pro pmap (arm64/sptm/pmap/pmap.c:6830-6917). `vm_remap copy=FALSE` behält use_pmap.
  - Probe: 256 MB anonym anlegen, anfassen, Alias remappen, Alias lesen, Footprint messen (erwartet +256 MB), trimmen.
  - Aufwand: 2 h. Umsetzung folgt in Phase 2.
- **[P3] GFX-16 PVG-Replay-Bench**: als Replay eines auf dem Gerät aufgezeichneten Traces, nicht synthetisch. Vorher `test_pvg_lifecycle` in `perf.yml`, um zu beweisen, dass Metal auf dem xcode-27-Runner läuft. Aufwand: M–L.

### Phase 1 — Stabil, einfach, schnell

**Signieren / Speicher**
- **[P0] MEM-1 increased-memory-limit wirklich signieren**
  - Mechanismus: SideStore 0.7.0-alpha (6032424a) behält in `updateFeatures` nur `team.type.allowedFeatures`. Für kostenlose Teams ist das `[appGroups, interAppAudio]` (SideSign a731c0d5 Feature.swift:78-81), signiert wird mit Profil ∩ App-Entitlements (CodeSignerAPI.swift:95-121). IML wird also gestrichen.
  - **Weg B:** SideStore bleibt, Henge wird **einmal** per **iloader ≥ 2.4.1 „Import IPA“** importiert. isideload PATCHt `INCREASED_MEMORY_LIMIT` an `<bundle>.<teamid>` (app_ids.rs:178-214), also an dieselbe App-ID, die SideStore benutzt.
  - **Weg A** (KORREKTUR): AltStore Classic 2.3.
  - Rückfall: GetMoreRam.
  - Entscheidung nach Log statt Theorie: HengeApp.swift:18 meldet „increased memory limit: yes, limit ~6000 MB“ – auch nach erzwungenem Refresh und nach dem 7-Tage-Neusignieren.
  - Kosten: 2 der 10 App-IDs pro 7 Tage (Henge + HengeJITHelper), daher nur einmal ausführen.
  - Gewinn: Limit ~3,0–3,4 GB (spek.) → ~6144 MB (Forum 834805, 8-GB-16-Pro-Max). Im öffentlichen XNU folgt daraus auch der große (jumbo) Adressraum.
  - Risiko: Apple ändert die Vergabe; ungeklärt, ob iloader und SideStore um das Zertifikat streiten.
  - Aufwand: 1 h (Anleitung).
- **[P0] MEM-2 „largest mapping 5120“ ist das Nicht-Jumbo-Fenster**
  - Rechnung: Fenster 0x300000000–0x458000000 = 5504 MiB, die Probe geht in 512-MB-Schritten → 5120.
  - Laut öffentlichem XNU reicht IML für jumbo (kern_exec.c:4172-4175). Unter iPadOS 27 belegt aber ein Tag-32-Eintrag (SHARED_PMAP) 0x2f4000000–0xfc0000000 (#211). Das iOS-27-Layout ist also unbekannt.
  - Log-Ergänzung: nur TASK_VM_INFO `min_address`/`max_address` neben die vorhandene Startzeile (HengeApp.swift:14). Sicherstellen, dass `log_map('before')` im Log der Runde 1 steht.
  - Zweig: bleibt das iPhone trotz IML ohne Jumbo (~2 GB + 5,4 GB), wird **MEM-5 zu P0**.
  - Aufwand: 1 h.
- **[P1] MEM-3 Sweep des Code-Caches korrigieren**
  - Mechanismus: Die JIT-Region wird nur einmal pro App-Start vergeben.
  - Leistung und Flush-Rate: **1-GB-Region vergeben und `HV_JIT_CAP` 512/768/1024 innerhalb eines Starts** variieren (dispatch.c:43).
  - Speicherwirkung: nur 512 vs. 1024 als ≤2 Neustart-Arme.
  - **1536 MB nicht auf dem iPhone.** 768 in JITBootstrap.swift:68-76 ergänzen (`HENGE_JIT_HOLD_BYTES` ist schon 1,5 GB).
  - Nach O5 hat 768 MB etwa die Flush-Rate von heute 1 GB und spart ~0,4 GB physisch.
  - Knopf: `henge.perf.codeCacheMB`, `HV_JIT_CAP`.
- **[P1/P0 bedingt] MEM-5 Ordnung im Adressraum**
  - (a) Gast-RAM **vor** `hv_machine_init_jit` vergeben oder schon in prepare reservieren. Heute legt Init zuerst ~1,2 GB Records, 8×64 MB IJC-Tabellen und Stashes an, erst danach `vm_allocate ANYWHERE` für das RAM (vm.c:276/292; machine.c:104-131; vmapple.c:177).
  - (b) Tabellen pro CPU nur für gestartete vCPUs (HV_MAX_CPUS=8 → ~550 MB VA).
  - (c) Record-Arrays nach der gemessenen Blockgröße bemessen, zusammen mit O11.
  - Alles im Fehlerpfad von `hv_vm_create` wieder freigeben (#11: nach Fehlschlag nur noch 3584).
  - (d) entfällt, abgedeckt durch #121/#211.
  - P0, wenn MEM-2 kein Jumbo zeigt, sonst P2 als Robustheit.
  - Knopf: `HV_RAM_RESERVE=1`.
  - Prüfung: CI `core-test` mit ncpus 1–4 und virtual_size.
- **[P2] MEM-11 Rückfallpfade härten**
  - NO_FOOTPRINT braucht im öffentlichen XNU ein privates Entitlement (vm_memory_entry.c:1638-1712). Es funktioniert auf dem Gerät, ist aber nicht dokumentiert.
  - Bei Ablehnung: Gast-RAM automatisch bemessen (`os_proc_available_memory` nach Prewarm − 512 MB, auf 256 MB gerundet).
  - Mit IML anonymen Speicher statt Datei bevorzugen (kein Flash-Verschleiß).
  - Ablehnungsgrund auf dem Startbildschirm zeigen.
  - Knopf: `HV_RAM_FALLBACK=anon|file`.
  - Prüfung: `HV_RAM_NO_LEDGER=1`.

**Grafik**
- **[P1] GFX-4 #187 in Phase 1.1 übernehmen**
  - Ersetzt den eigenen Phase-3-Punkt „Zero-Copy Mehr-Ebenen“: lineare Textur je Ebene auf den Gastseiten, kein Hash und kein memcpy pro Exec (pvg_metal.m:2106).
  - #207-Commit 1 entfällt dann; Konflikte mit #188/#207 in `newSurface` auflösen.
  - Gewinn unter 15.6.1 vor allem bei Video und Mehrebenen-Korrektheit; die „Safari-Kacheln“ sind ein macOS-27-Thema.
  - Knopf: `HV_PVG_PLANAR_COPY`. Aufwand: 0,5 Tag.
- **[P1] GFX-2 #161 in zwei Knöpfe aufteilen**
  - `HV_PVG_VBLANK_TS=1` (Zeitstempel +0x68) und `HV_PVG_VBLANK_IRQ=1`, Standard wie in #161 gemessen. IRQ=0 auf 15.6.1 als A/B.
  - Einmalig +0x104 und die Zahl der Event-8 pro 10 s im iOS-Log.
  - **Bei einer späteren #190-Übernahme den 15.x-Pfad behalten**: kein „+0x68 = 0“, kein leeres `vblank()`.
  - Reine Absicherung; die 60 IRQs/s sind Rauschen. Aufwand: 1 h.
- **[P2] PLAT-7 HV_HZ=30/60 in den Sweep**
  - Voraussetzung: `vblank()` cached `HV_HZ`/`HV_PVG_VBLANK` in statics (pvg_lite.c:714-720) → in `hv_knob[]` verschieben, sonst ist das A/B innerhalb einer App-Sitzung ungültig.
  - Nur weniger Compositing-CPU in Bewegung (spek.).
- **[P3] GFX-17 Hygiene-Liste 1.4 ergänzen**
  - `keep`-Arrays als `__strong`-Stack-Arrays (:1401, :1598-1605);
  - Objekttyp in HvObject statt `conformsToProtocol` (:1602);
  - dispatch_data-Destruktor, der das NSData behält (:479/522/555);
  - fprintf bei :1020 drosseln.

**Gast-Tuning (Lighter-Stufen)**
- **[P2] PLAT-3 Stufe A: Autokorrektur und Text-Ersetzungen aus**
  - `NSAutomaticSpellingCorrectionEnabled`, `WebAutomaticSpellingCorrectionEnabled`, Capitalization/Period/Quote/Dash mit `-bool false`; passende `defaults delete` in unlighten (share.c:609-654).
  - Schlüssel für Inline-Vorhersage und Live Text per `strings`/PLAT-11 ermitteln.
  - Gewinn nur bei Tipp-Latenz (spek.); Tipp-Messung in den Benchmark.
- **[P3] PLAT-12 (reduziert)**
  - Stufe B: `defaults -currentHost write /Library/Preferences/com.apple.powerlogd SMCMonitorCadence 0`; `hibernatemode 0` und sleepimage nur, falls vorhanden.
  - Stufe A: UI-Töne aus.
  - `HV_NO_SOUND=1` als Sweep-Punkt (vmapple.c:323, Poll bei :234).
  - **Nicht** `HV_INPUT_ORDER=keyboard`: bricht die Mauseingabe (henge-vm.c:398-411 → vm.c:684-699).
- **[P3] PLAT-16** `timer.tolerance` für die Agent-Timer (henge-agent.m:126-127), zusammen mit #99.
- **[P3] PLAT-2** Low Power Mode im Gast: nur `pmset -g cap` per CI-Probe. VirtualMac2,1 steht nicht auf Apples Liste (support 101613); Gewinn vermutlich 0.

**Scheduling-Standardwerte**
- **[P1] MP-4 vCPU-Standard aus P/E-Zahlen ableiten**
  - Heute 4 an vier Stellen (SessionView.swift:24, HomeView.swift:163, InstallView.swift:18, MacSettingsView.swift:10), Stepper bis 6 (:44).
  - Standard aus `hw.perflevel0/1`. Hypothesen: Telefon 3, Air M3 4, M4 3P 4, M4 4P 5.
  - Stepper-Maximum = min(8, P+E−1).
  - 3 vCPUs liefen auf dem Telefon schon (machine.c:190-192).
  - Neu gegenüber dem Plan: getrennt nach kalt (Min 0–3) und dauerhaft (Min 15–20) messen. Ein Wechsel invalidiert Instant-Resume-Stände einmal (InstantResume.swift:25).
  - Knopf: `HV_CPUS_POLICY`.

**Übersetzer-Kleinkram (XS, gemeinsam ~0,5 Tag)**
- **[P2] TR-4** CLREX inline: `movn x6,#0; str x6,[x28,#EXCL_ADDR]` statt vollem Helper (translate.c:1703-1706 → enter.S:180-211). Spart ~100–150 Zyklen pro CLREX; Häufigkeit gering. Knopf `HV_CLREX_INLINE`.
- **[P2] TR-12a** IJC Way 0: Tag und Code mit einem `ldp x7,x6,[x6]` laden (translate.c:275/279; enter.S:362-367). −1 Wort pro indirektem Sprung; CI zählt deterministisch.
- **[P2] TR-11a** `counter()` in `read_reg` nur in den Timer-Fällen aufrufen (sysreg.c:72, :135-141).
- **[P3] TR-13** ADRP+ADD (gleiches Rd) zu einer Konstante falten (translate.c:657-661). Variante: ADRP + LDR mit Rt==Xd. Knopf `HV_ADRP_FUSE`.
- **[P3] TR-8 (Teil)** `HV_MOVIMM=2`: MOVZ/MOVN, wenn ein Befehl reicht (kein Pool-Load), messbar über `words_pool`. CAS/CASL statt CASAL nur zusammen mit TR-2.

### Phase 2 — Übersetzer & System

**Übersetzer**
- **[P1–P2] TR-3 `HV_TLBT=2`: EL1+PAN-Tabelle unterhalb von x28**
  - Mechanismus: `ubfx; sub T,x28,T,lsl #5`, ohne den Tabellen-ADD (translate.c:137-141). Felder umordnen zu {read_tag, addend, write_tag, exec_tag}, Laden per LDP (`[T,#-32]` bzw. `#-24`).
  - Heute nicht möglich: Felder nicht benachbart (cpu.h:20-25), TLB bei 0x580 außerhalb der LDP-Reichweite.
  - Zerreißen ist unschädlich: Remote-Drops invalidieren alle Tags; den Addend schreibt nur der Besitzer (mmu.c:647, :746-748).
  - Umsetzung: Wrapper-Struct `{HvTlbEntry pan[16384]; HvCpu cpu;}` überall, auch in Tests mit HvCpu auf dem Stack. Dreifacher Layout-Schalter (dispatch.c:20-27). SUB-Form im Exec-Check (translate.c:429-431). Recheck und Refill bauen T neu (:1777-1784).
  - Tabelle 3 ist ungenutzt (cpu.h:104) → 512 KB pro vCPU frei.
  - **Mit O15 gemeinsam entwerfen.**
  - Gewinn: −2 Wörter pro EL1+PAN-Zugriff, +1–3 % in kernellastigen Phasen (spek.).
  - Prüfung: CI-Zählung Wörter/Gastbefehl, Matrix `HV_TLBT 0/1/2 × HV_RECHECK × HV_GROUPS`.
  - Aufwand: 2–3 Tage.
- **TR-9 → Checkliste für O4** (kein eigener Gewinn)
  - `stats.blocks` pro CPU (auch für den Druck-Takt dispatch.c:1120);
  - elchg- und recent-Ringe pro CPU oder hinter `HV_STATS_DEEP` (exception.c:46-54, :114-119);
  - `stat_slow_mem` und `access_pc` nach HvCpu/HvPerCpu (dispatch.c:364, memop.c:649; Tests test_mem.c:196-209, machine.c:567-595, pvg_mac.m:261 anpassen);
  - lesend genutzter Konfigurationsblock (stop_pc, stop_pc2, trace, log, slow_mem, chain, slots) auf 128 B ausgerichtet, weg von geschriebenen Feldern (machine.h:128-131, :242-256).
- **TR-10 (Teil) → in O7a**: `can_refill` schließt RMW aus (translate.c:1087). RMW ist vor dem Zugriff idempotent, ein Neuversuch ab `retry` ist sicher. Knopf `HV_RMW_REFILL`.
- **[P2] TR-1 WFE**
  - (a) Frist = min(now+50 µs, `timer_due`); Timeout setzt **nicht** `exit_req` (dispatch.c:253, :265), treibt also kein `m->tick`.
  - (b) `HV_WFE_YIELD=N`: nach N Timeouts auf demselben (excl_addr, excl_val) `thread_switch` zu einer anderen vCPU (HvPerCpu.thread, machine.h:208).
  - (c) `sleep_ok` und `wfe_timeouts` loggen.
  - Der Teil zu den Geräte-Polls ist schon im Plan.
  - Gewinn unbekannt bis gemessen, nur auf dem Gerät prüfbar.

**Paravirtualisierung im Gast**
- **[P1, günstiges Experiment] PLAT-1 Vmapple-OEM-Hypercalls → PV-Ticket-Locks**
  - Mechanismus: `lck_init_pv` (locks_arm.c:211-221) prüft UID 0x8300ff01 (w0=0x9CBB6EBB, w1=0x9DC9D679, w2=0xAA624E1F, w3=0x3B878185), Revision 0x8300ff03 (w0=1) und Features 0x8300feff für 0xc3000005 (WFK) und 0xc3000006 (KICK). Henge antwortet heute -1 (exception.c:208-211).
  - WFK: x0=0, pc+4, Block beenden, vorhandenes `wait_for_interrupt`; x1=ien optional.
  - KICK: `hv_cpu_wake(target)` (machine.c:334-343, wake_pending ist bereits klebrig, kein neues Feld). Die x1-Werte einmal loggen (phys_id = Index?).
  - **Achtung:** WFK erst nach `ticket_lock_spins`=100 WFE-Runden; bei 50 µs/WFE sind das ~5 ms Spin. Daher `kern.ticket_lock_spins` auf ~5–10 senken, per LaunchDaemon wie PLAT-8 (RW, kern_sysctl.c:5974-5977).
  - Vorher auf dem CI-Runner `sysctl kern.ticket_lock_spins` prüfen.
  - Gewinn: 0–3 % bei 3–4 vCPUs, sonst Energie und Wärme (spek.).
  - Knopf: `HV_PV_TICKET=0|1`.
  - Prüfung: CI-Testprogramm mit exakter Probe-Sequenz und WFK/KICK-Ping-Pong; Zähler wfk/s, kick/s, mittlere Schlafdauer.
  - Aufwand: 1 Tag.
- **[P2–P3] PLAT-8 Timer-Coalescing im Gast**
  - Startwerte: `kern.timer_coalesce_kt/ts_ns_max` 2–4 ms, bg 250–500 ms, tier3 150 ms, fp unverändert (Standard arm_timer.c:276-299).
  - Persistenz: LaunchDaemon-plist `root:wheel 0644`, `launchctl bootstrap system`.
  - Wirkt nur auf Timer ≥8 ms in der Zukunft (slop = Abstand>>3).
  - Vorher Timer-IRQ/s pro vCPU in HV_STATS.

**Kicker / vBlank (Voraussetzung für den fristgesteuerten Kicker)**
- **[P1] GFX-3 vBlank-Uhr**
  - Problem: `vblank()` läuft nur in CPU 0s `tick_locked` (vmapple.c:222-226) mit `next = now + period`. Ergebnis: Drift ~58 Hz und 0–10 ms Jitter, weil `kick_all` geparkte CPUs nicht weckt (machine.c:345-350, dispatch.c:446-457).
  - **„Geräte-Polls nur bei gemeldeter Arbeit“ stoppt die +0x68-Schreibvorgänge → der #161-Sturm käme zurück.**
  - Fix:
    - (a) Raster: `next += period`, verpasste Ticks überspringen, Rasterzeit − cntvoff schreiben.
    - (b) `vblank_next` ist eine Gerätefrist: `tick_locked` liefert min(Timer, vblank) für CPU 0; Kicker und Poll-Gating behandeln sie als fällig. Das ergibt 60 Wakeups/s als Untergrenze des Leerlaufziels.
    - Eigener Host-Thread nur als A/B (`HV_PVG_VBLANK_THREAD`).
    - (c) `HV_HZ`/`HV_PVG_VBLANK` in `hv_knob[]`.
  - Glätte-Gewinn spekulativ. Prüfung: Histogramm der vBlank-Intervalle, „Timer delayed“ im Gast.
  - Aufwand: 0,5 Tag.
- **[P2] MP-11 Checkliste vor dem Kicker-Umbau**
  - Ein „Arbeit bereit“-Signal je Tick-Poll: pl031, board_poll/Netz (vm.c:131-142), pvg_lite_poll, beide blk, xhci, beide Eingaben, snd, vusb, balloon, bdif (vmapple.c:226-237). pvg-Completions wecken schon über GIC (pvg_lite.c:382-387).
  - **Kick pro vCPU auf ihre CNTV-Frist**: `run_loop` prüft den eigenen Timer nur beim Kick oder alle 64 Durchläufe (dispatch.c:969), verketteter Code bleibt lange draußen.
  - Sicherheits-Tick 20 ms.
  - Gerätetest: Einstellungen › Datenschutz › Analysedaten zeigt keine „wakeups_resource“-Berichte (Grenze ~150/s, unbestätigt).
  - Knopf: `HV_KICK_MS=0`, `HV_SAFETY_TICK_MS=20`.

**Scheduling**
- **[P2, gated durch MP-5] MP-6 Gezielte Übergabe**
  - `thread_switch(B_port)` vor dem `__ulock_wait` in `hv_cpu_sync` (machine.c:271-276), danach weiter mit dem Ulock-Wait; ratenbegrenzt, nur auf Seite des Wartenden. In `stop_the_world` statt `sched_yield` (dispatch.c:870).
  - Hilft nur, wenn B wirklich in einer Run-Queue wartet (sched_prim.c:6024-6053).
  - Gewinn: höchstens wenige % eines Kerns. Knopf `HV_SYNC_HANDOFF`.
- **[P2] MP-7 QoS-Deltas** (nur was nicht im Plan steht)
  - `HV_QOS0=ui` mit relpri −1, also unter dem Haupt-Thread;
  - vCPUs ≥ P mit kleinerer relpri bzw. als A/B gegen UTILITY;
  - `IOPOL_IMPORTANT` für die Disk-Worker;
  - `qos_gen`-Hook im Kick-Pfad (dispatch.c:959), damit QoS live umschaltbar ist (für MP-1);
  - **keine Realtime-Threads und keine Work-Intervals.**
  - Wirkung: höhere Priorität für vCPU0, keine garantierte P-Platzierung (CLPC pro Thread-Gruppe).
- **[P2] MP-10 Adaptives WFI-Halt-Polling**
  - Fenster ×2 ab 5 µs bzw. ÷2, maximal 10–20 µs auf dem Telefon.
  - **Nur wenn vCPUs ≤ P-Kerne oder die Runnable-Zeit niedrig ist**, sonst blockiert der Spin einen Kern (dispatch.c:475-481).
  - Aus ab „fair“ und bei LPM. Entscheidung auch über Energie/Arbeit.
  - Knopf: `HV_WFI_SPIN=auto`.

**Speicher**
- **[P1 bedingt] MEM-4 Teil 2: RW-Alias trimmen**
  - Nur wenn die CI-Probe ~+100 % zeigt.
  - **Periodisch** (alle N s, unter `tr_mu`, nach Audit, dass jeder RW-Schreiber, auch Chaining und Unchaining, ihn hält): `vm_protect(rw, NONE)` → `RW`.
  - Nur beim Flush zu trimmen senkt die Spitze nicht.
  - Niemals MADV/Remap auf RX: vom Debugger vorbereitete Seiten lassen sich nicht neu vorbereiten.
  - Auf TXM-Geräten ungetestet → Gerätecheck.
  - CI-Zusatzvariante (spek.): Memory Entry mit `NO_FOOTPRINT` über beide Sichten.
  - Gewinn: bis zur Cache-Größe im Footprint, physisch 0.
  - Knopf: `HV_RW_TRIM=0|1|N`.
- **[P2] MEM-9a Vor dem Pausieren im Hintergrund schrumpfen**
  - Ballon-Ziel setzen (`HV_BG_BALLOON_MB=1024`), bis ~3 s auf CFG_ACTUAL warten, dann pausieren.
  - Optional mit MEM-7-Zap (mmap-Records `MAP_FIXED` neu) und MEM-4-Trim.
  - Gewinn: ~1 GB weniger physisch im Hintergrund. Aufwand: 2 h.
- **[P3] MEM-7** Record-Zap nur als Teil von MEM-9a; die Spitze bleibt unverändert (dispatch.c:37-42).
- **[P3] MEM-8** `HV_READ_CACHE=0` nur als zusätzlicher Arm im geplanten Read-Ahead-A/B (disk.c:26-37). Gewinn spekulativ, eher negativ.

**Grafik**
- **[P2, gated: >200 leere CBs/s] GFX-6 Geordnete Stamp-FIFO statt leerer Command-Buffer**
  - Heute: leerer CB in `finishChannel` (:2079-2085), synchronize doppelt (:1244, :2814).
  - Neu: seq-geordnete Handler (:145-146), synchronize mit eigenem Stamp; #207-Commit 2 nutzt dieselbe FIFO.
  - Gewinn: weniger IRQs und weniger Druck auf das 64-CB-Limit, kaum CPU.
  - Knopf: `HV_PVG_STAMP_FIFO`.
- **[P2, erst messen] GFX-5 `vm_remap` in Läufen**: Läufe vs. Seiten in der Zeile „surface …“ (:1020) und in `map_pages` loggen. Umsetzen nur bei <0,3 Läufen pro Seite (:287-302, :970-977). Puffer direkt auf Gast-RAM nur mit eigenem Knopf und Test mit `HV_RAM_FILE`.
- **[P2, erst messen] GFX-11 Kopie des ganzen Heaps** (:1197-1202): Bytes/s je Richtung, einmal `HV_PVG_HEAP_LOG`. Bereichskopien (`HV_PVG_HEAP_RANGES`) erst ab ~100 MB/s. Flag ist Wert 4 (Bit 2).
- **GFX-8**: Mechanismus des Plans behalten (`afterMinimumDuration` 1/60, Hitze 1/30, Knopf `HV_PVG_PRESENT_HZ`). CAMetalDisplayLink und Phasenkopplung → P3/Forschung. `screen_dirty` bündelt bereits.

**Netz**
- **[P2–P3] PLAT-10 DNS-Blockliste im Host**
  - Prüfung des Namens vor `DNSServiceQueryRecord` (dns_proxy.c:226, :270), NXDOMAIN über `reply(rcode)` (:153-166). Liste in Documents.
  - Allowlist für Apple-Infrastruktur (gs, ocsp, timestamp, Zeit). TCP-DNS und DoH umgehen den Filter.
  - Knopf: `HV_DNS_BLOCK`.
  - Prüfung: A/B der Seitenladezeit.

**Toolchain nach Messung (gated durch TC-02)**
- **[P2, ab ~20 % Host-C-Anteil] TC-04 IR-PGO trainiert auf dem Gerät**
  - Instrumentiertes Release N, danach Release N+1 mit Profil. **Kein zweiter Eintrag in repo.json** (gleiche bundleIdentifier kollidiert vermutlich).
  - Profil: periodisch `__llvm_profile_write_file` alle 60 s und am Benchmark-Ende (iOS beendet Apps ohne atexit). Übertragung über Dateien bzw. iTunes-Dateifreigabe (Info.plist:57, :91).
  - CI: `xcrun llvm-profdata merge` mit gepinntem Xcode; Mismatch-Zähler veröffentlichen.
  - Nur mit echter Gerätelast trainieren. Nicht-Profil-Flags identisch halten. Kein CSPGO.
  - Gewinn: 2–6 % gesamt (spek.).
  - Knopf: `IOS_PGO=off|gen|use`.
- **[P2–P3] TC-05 ThinLTO**
  - `-flto=thin` in `IOS_CFLAGS`, LTO-Cache (`-cache_path_lto`). enter.S bleibt nativ. TC-01 auf dem Endbinary.
  - `LLVM_LTO` optional: erst in DerivedData.buildlog nach `-object_path_lto` sehen.
  - Gewinn 0,5–2 % (spek.), vor allem zusammen mit PGO.
  - Knopf: `IOS_LTO`.
- **[P2] TC-06 Zwei Engines in einer IPA**
  - Günstige Variante: Engine-B-Symbole per generiertem `-include`-Header präfixen, beide statisch linken, glib/slirp teilen, Auswahl über eine Funktionstabelle (`HV_ENGINE=a|b`). Achtung: hvsparse und libhengetl hängen an Engine-Symbolen.
  - Rückfall: abwechselnde Releases aus identischer Quelle.
  - Aufwand: 3–5 Tage.

**App**
- **[P3] MP-12** KeepAlive (#214) erst bei `.inactive` starten, mit Rückfall auf immer an (auch bei Installationen). Zuerst den Sperrknopf-Pfad prüfen. Gewinn ~0.

### Phase 3 — Strukturumbauten
- **[P2] MP-8 Thermik-Politik live** (ersetzt die Phase-3-„vCPU-Drosselung“)
  - Mitteilungen zu thermalState und LPM setzen ein atomares Profil in HvMachine (`henge_vm_set_power_profile`).
  - Stufe 1: Verschwendung kappen (WFI-Spin aus, längeres Stats-Intervall).
  - Stufe 2: Present-Teiler und vCPUs ≥ P auf UTILITY als A/B.
  - critical: Mac pausieren plus Banner.
  - LPM-Banner „Mac etwa halb so schnell“.
  - Beleg richtigstellen: CPU-Stabilität 16 Pro Max ~77 %, GPU ~55–65 %.
  - Knopf: `HV_THERMAL_POLICY=0|1|2`.
- **MEM-12 → Regel für die Speicherdruck-Leiter**: Nur Heaps, die nie Render- oder Compute-Ziel waren (Flag „GPU-written“ pro Heap), werden volatile; vor Wiederverwendung `.empty` prüfen und neu hochladen. CI-Replay-Hash mit erzwungenem Purge.
- **[P3] MEM-9b** `MADV_FREE_REUSABLE` + Lazy-Reload nur im Instant-Resume-Pfad nach vollständigem Save. Alle Gerätethreads stilllegen, nie JIT oder Ringe anfassen, CI-Stress mit `memory_pressure`.
- **[P3] MEM-10** 3,0 vs. 3,5 GB nur bei Reserve laut MEM-6 (Kompressor-Spitze <1 GB, keine Warnung). #214-Grenze überschreibbar machen (`HV_RAM_CAP_MB`). Ballon nach Host-Kompressor steuern (`HV_BALLOON_TRIGGER_MB`), das allein ist der wertvollere Teil.
- **[P3] PLAT-13 → O16 auf Kaltstart erweitern**: Liste heißer Blöcke **relativ zum Kernel-Slide und zur Shared-Cache-Basis** (vm.c:84-105 findet virtBase), Vorübersetzung auf E-Kernen. Kein Festpinnen des Seeds.
- **[P3] GFX-12** Nur loggen (Anzahl Storage-Mode-3, makeBuffer-Flags); memoryless nur bei Treffern (:687, :702).
- **[P3] GFX-13** Library-ms, Relabel-Treffer und doppelte Hashes loggen; LRU Hash→MTLFunction nur bei hohem Anteil (`HV_PVG_DEDUPE`).
- **[P3] GFX-14** In den Plan-Punkt „undurchsichtige Ebene“ einfalten: sRGB→P3 im Present-Shader (`henge.display.direct`); clipShape ist schon kein Thema.
- **[P3] TR-11b** Eigener `-mgeneral-regs-only`-Helper samt Thunk ohne SAVE_FLAGS_FP für reine Speicher-MRS/MSR, erst nach O10/O13. Die 16-B-Kopie in `helper()` (dispatch.c:356) darf nicht im Pfad liegen.
- **[P3] TR-12b** Nur `HV_IJC_BITS` als Knopf (translate.c:272, enter.S:35/:361), wenn fill_kind oder Energie es rechtfertigen.

### Phase 4 — Forschung
- **GFX-9** Pflichtangabe zur Synchronisation für „getrennte Präsentations-Queue“: `MTLSharedEvent` pro Swap, der Presenter wartet vor seinem Pass. Erst, wenn Swap→Present unter Last >1 Frame dauert.
- **GFX-10** Command-Buffer-Bündelung nur aus bereits Gequeuetem; erst bei Queue-Tiefe >1 laut GFX-1. Multi-Queue-Variante gestrichen.
- **TR-2** LL/SC-Fusion nur bei >1 M STXR/s pro vCPU (arm64e-libobjc und xnu nutzen CAS). Livelock-Assert. Aufwand M–L.
- **TR-7** DSB→DMB nur nach Mikrobench (`dsb ish` vs. `dmb ish`) und ≥100 K DSB/s; Audit der lockfreien PVG-Ringe.
- **TR-8** CAS/CASL und das Monitor-STP zusammen mit TR-2. **TR-10** LDXP/STXP inline nur bei ≥20 K/s slow_kind excl.
- **PLAT-4** Lockdown-Mode-A/B erst, wenn ein Zähler für Code-Page-Invalidierungen JIT-Wechsel zeigt; vorher `--js-flags=--jitless` für Electron-Apps.
- **PLAT-5** nur Diagnose: `HV_BOOTARGS="-v keepsyms=1"` über einen synchronen Hook.
- **PLAT-15** `HV_PVG_SDR`: Ersparnis nur bei der GPU-Bandbreite.
- **PLAT-9** `HV_LOG_BUDGET` erst, wenn Runde 1 wiederkehrende Log-Stellen zeigt.
- **PLAT-14** Nur Notiz: Ganz-RAM-Scans (dt_fixup.c:318-391) nur bei Host-Identität; dann auf den boot_args-Baum begrenzen.

### Phase 5 — iPads
- MP-4 liefert den Standard je Gerät (Air M3 4, M4 4/5), Stepper ≤8.
- TC-03 `apple-a14` deckt M3 und M4 ab.
- MEM-1/MEM-3 gelten auch für das 8-GB-Air (dort 1 GB Cache nur mit IML; 1,5 GB nur ab 12 GB RAM).

---

## 2. Plan-Korrekturen

1. **1.3 „SideStore 0.7.0-alpha aktiviert IML automatisch“ ist falsch.** Die KORREKTUR oben hat das erkannt, Abschnitt 1.3, Einrichtung Schritt 3 und die Verification stehen aber noch auf dem alten Stand. → Neu schreiben nach MEM-1 (Weg A oder B, Entscheidung per Log-Kriterium). Die Zahl „~3,0–3,4 GB ohne IML“ als Schätzung kennzeichnen.
2. **0.2 „Zwei Kanäle“, 1.3 „EVA-Experiment“, 1.1 „#211 für EVA-Kanal“, Verification „Log zeigt EVA“** → streichen. Begründung: SideStore und iloader können EVA für kostenlose Teams nicht signieren. #121/#211 sind **für jeden VM-Start** nötig. Verification neu: „IML yes“, TASK_VM_INFO `max_address`, largest mapping.
3. **KORREKTUR „Code nur unter 0x7000000000, Loch ~1080 MiB“** → so belassen, aber als Messpunkt der Runde 1 behandeln (MEM-2). Zusätzlich den Zweig „kein Jumbo trotz IML“ planen (MEM-5 wird P0).
4. **1.4 „Code-Cache 1 GB auf 8-GB-Geräten (#214)“** gilt nur mit IML. Upstream-main ohne #214 wählt ab 5,5 GB Limit **1536 MB**, mit IML also 1,5 GB auf dem Telefon → #214 muss vor dem IML-Fix drin sein, oder das Maximum wird gedeckelt.
5. **Testrunde 1 „Code-Cache 1/1,5 GB“** → `HV_JIT_CAP` 512/768/1024 innerhalb eines Starts; keine 1536 auf dem iPhone (MEM-3).
6. **Testrunde 1 gesamt (~33 h) und Grundsatz 2 „≥3 A/B-Paare“** → Methode MP-1. Die Paarzahl folgt aus dem σ des A/A und der gewünschten Nachweisgrenze. Effekte unter ~5 % entscheiden deterministische CI-Zähler und Zyklen/Arbeit.
7. **Grundsatz 2 „jede Optimierung hinter einem Knopf“** gilt nicht für Compiler-Flags, PGO/LTO und Layout-Änderungen (z. B. HvCpu-Offsets enter.S:19-35, HV_TLBT=2, O5/O11/O15) → TC-06 oder abwechselnde Releases aus identischer Quelle.
8. **Release-Regel „in keiner Kennzahl schlechter“** wird bei Rauschen ständig verletzt → „kein **signifikanter** Rückschritt (95-%-KI) über der Nachweisgrenze; Energie/Arbeit höchstens +2 %“.
9. **Rollen: „iPhone am Ladegerät“** → nein, wegen Ladewärme (MP-3). **Einrichtung Schritt 4 „Hintergrundaktualisierung an“** widerspricht dem Benchmark: vorher „Alle aktualisieren“, während des Benchmarks aus.
10. **0.3 `perf.yml`** misst apple-m1-Code statt des iPhone-Codes (apple-a7) → -mcpu in beiden Builds festlegen, Xcode pinnen (TC-03, TC-08).
11. **0.3 Telemetrie**: „Warten auf GPU“ ist falsch beschriftet (misst `-commit`) → GFX-1. „off a core“ heißt nur „blockiert“ → MP-5.
12. **Phase 2 „PPI-Pegel vor dem Lock prüfen“** ist schon upstream (gicv3.c:395-400) → streichen. Restkosten sind `hv_gicv3_update` und der Lock bei jedem ICC-Zugriff (:77-87, :412-419).
13. **Phase 2 „Geräte-Polls nur bei gemeldeter Arbeit“** würde die vBlank-Schreibvorgänge stoppen (#161-Sturm) und die Gast-Timer-Latenz verlängern → zwingend zusammen mit GFX-3(b), einem Kick pro vCPU auf ihre Frist und dem 20-ms-Sicherheits-Tick (MP-11).
14. **Phase 3 „Zero-Copy für Mehr-Ebenen-Oberflächen“** → in Phase 1.1 #187 übernehmen. Begründung „Safari-Kacheln“ gilt unter 15.6.1 vermutlich nicht.
15. **Phase 3 Hitze-Profil**:
    - „optional vCPU-Drosselung“ → streichen; Duty-Cycling senkt den Durchsatz ohne Effizienzgewinn (MP-8).
    - „30 Hz vBlank“: Die Gast-Bildrate wechselt nur beim nächsten Boot, live geht nur die Host-Präsentation.
    - Die statics in pvg_lite.c:714-720 müssen in `hv_knob[]`.
16. **Phase 2 „Präsentation an ProMotion“**: so lassen. Die Behauptung „Präsentation mit Touch-Rate“ stimmt nicht, `screen_dirty` bündelt schon.
17. **1.1 #161 als ein Knopf** → zwei Knöpfe (GFX-2). **Phase 4 „mehrere Anzeigemodi live“ (#190)** darf +0x68 und `vblank()` für 15.x nicht entfernen.
18. **1.2 „#214 begrenzt ohnehin auf 3072 MB“**: Das ist eine harte Grenze. Für jedes RAM-A/B einen überschreibbaren Knopf `HV_RAM_CAP_MB`.
19. **Bewusst verworfen „Code-Cache über Kaltstarts (KASLR, …)“** → Begründung korrigieren: Blocker sind die absoluten Host-Zeiger; KASLR lässt sich per Rebase relativ zum Slide behandeln (PLAT-13 → O16).
20. **O15 und HV_TLBT=2** ändern beide HvTlbEntry → gemeinsam entwerfen.
21. **0.3 Fuzzer/Matrix**: um SIMD-Sentinel-Test (TC-01), Flag-Achse und UBSan-trap ergänzen (TC-09).
22. **Phase 5 „vCPU-Heuristik 4–5“**: Grenze HV_MAX_CPUS=8 (machine.h:133), Stepper heute bis 6 auf jedem Gerät.
23. **Bewusst verworfen „alle vCPUs user-interactive“**: bleibt. Präzisieren: nur vCPU0 ui mit relpri −1 als A/B; nie Realtime oder Work-Intervals.
24. **KORREKTUR „kein xtool“**: richtig. Den entscheidenden Leistungsgrund ergänzen: IML geht bei kostenlosen Teams verloren (siehe 4.).
25. **Bewusst verworfen ergänzen um:**
    - xtool;
    - No-op-Flags `-fvisibility=hidden`, `-fno-semantic-interposition`, `-fstrict-aliasing`, `-DNDEBUG` (keine asserts), Swift-WMO (schon gesetzt);
    - `-fno-stack-protector` (winziger Gewinn, Schutzschicht für Gast-Parsing; memop.c:522/544/581/699 hat Puffer);
    - schädlich: `-fomit-frame-pointer`, arm64e, `-ffast-math`;
    - ASan, CSPGO;
    - Block- und Schleifenausrichtung auf 64 B (TR-14);
    - Gast-P/E-Topologie (VMAPPLE `MAX_CPU_CLUSTERS 1` → kein AMP, board_config.h:281-307);
    - ECV, DIC, HAFDBS, BF16/I8MM bewerben; SME bleibt versteckt; PAuth lässt sich nicht verstecken (PLAT-6);
    - Boot-Args `serverperfmode` (schädlich, timer_call.c:1138/1581), `cpus=`, `slide=`, `debug=`;
    - SIP vom Host aus abschalten;
    - KASLR-Seed festpinnen;
    - `HV_INPUT_ORDER=keyboard`;
    - Multi-Queue-Replay;
    - Duty-Cycling von vCPUs.
    - Warnung für Nutzer: Rosetta/x86 im Gast ignoriert das TSO-Bit (sysreg.c:201) → Gefahr bei der Speicherordnung.
26. **Testrunde 1, neuer Inhalt**:
    - Log-Punkte: IML, `max_address`, largest mapping, NO_FOOTPRINT ok, `sleep_ok`, helper-Mix, Speicher-, GPU- und Scheduler-Telemetrie.
    - A/A (8 Paare).
    - Danach Live-Sweeps in einer Sitzung: GROUPS, SUPERBLOCKS, HOIST, RECHECK, WFI_SPIN, SYNC_WAIT, JIT_CAP 512/768/1024.
    - Über Nacht: cpus 3 vs. 4, HV_HZ 30/60, Auflösung.
    - Letzter Boot: hvprof.

---

## 3. Was noch fehlt

| Dimension | Lücke | Vorschlag |
|---|---|---|
| **Startzeit** | Kein Profil der Startphasen | Zeitstempel in `HENGE-BENCH`: App-Start → JIT bereit (~13 s) → `hv_vm_create` → erstes Bild → Login-Fenster → Schreibtisch → „settled“ (Gast-Leerlauf <x % über 30 s). Danach O16 als Kaltstart-Variante (PLAT-13). XS. |
| **Dauerbetrieb** | Messung nur 20 min | Kennzahl „Arbeit pro Minute in Min 15–20“ und J/Arbeit (MP-2, MP-4); eine 30-min-Sitzung pro Release (Plan-Stabilitätsziel) im Nachtmodus. |
| **Datenträger-I/O** | Keine Latenz-Messung; Flush-Semantik ungeprüft | virtio-blk-Histogramm (Queue→Completion p50/p99) in HV_STATS. Prüfen, ob Gast-Flushes `fsync` oder `F_FULLFSYNC` auslösen (host/disk.c); auf iOS ist `F_FULLFSYNC` teuer → A/B `HV_FLUSH_MODE`. Spek., S. |
| **Netz** | Kein Durchsatz/Latenz im Benchmark | Fester Download vom Host-Share 10.0.2.4 (ohne Internet-Rauschen) und DNS-Latenz im Benchmark; PLAT-10; MTU/Offload bleibt Phase 4. |
| **Speicher** | Weitgehend abgedeckt | Rest: Jetsam-Ursache automatisch aus `henge-prev.log` und Analytics-JetsamEvent zuordnen (Anleitung zum Kopieren der einen Datei). |
| **Thermik** | Kein Temperatursensor | Frequenz-Probe als Stellvertreter (MP-3/MP-5); thermalState-Verlauf pro Segment. Hauttemperatur bewusst ausgelassen (keine API). |
| **Akku** | Keine Langzeit-Kennzahl | %/h in der 30-min-Sitzung als Release-Kennzahl nur informativ (Akkualterung verfälscht). Energie/Arbeit bleibt maßgeblich. |
| **Mehrkern** | 4 E-Kerne meist ungenutzt, während vCPUs auf P laufen | Forschung Phase 4: asynchrone Übersetzung bzw. Vor-Übersetzung heißer Ziele auf einem E-Kern-Worker (heute übersetzt die vCPU synchron); auch für O12-Tenure nutzbar. Spek., L. |
| **Build/Toolchain** | Abgedeckt (TC-01–13) | – |
| **Messung** | Keine Ergebnis-Historie | `tools/bench_analyze` (CI) parst eingefügte `HENGE-BENCH`-Zeilen und committet sie nach `bench/history.csv` → Regressionen über Releases sichtbar. S. |
| **Regressionen** | Gerät: nur Abschalten per `henge-env.txt` | **Sicherer Modus**: nach 2 Absturz- oder Hängerstarts setzt die App `HV_SAFE=1` (alle Fork-Knöpfe auf upstream-Standard) und meldet das. Ergänzt den Absturzschutz für den Auto-Start. XS. |
| **Absturzfestigkeit als Leistung** | Panic/Jetsam = verlorene Sitzung | MP-13-Zähler; dSYM pro Release (TC-02) für Symbole in Absturzberichten. Automatische Checkpoints bewusst ausgelassen (3 GB Flash-Schreiben je Sicherung); nur MEM-9a im Hintergrund. |
| **Interaktive Latenz** | Nicht gemessen | Touch→Gast-Event→nächster Swap/Present als Histogramm (HV_STATS); wichtiger als fps für „fühlt sich schnell an“. S. |
| **Upstream-Sync** | Layout-Umbauten (HV_TLBT=2, O5, O11, O15, hv_knob) erschweren Rebases | Jede Layout-Änderung als eigener Commit mit Knopf und eigenem Abschnitt in `FORK.md`. Upstream-Engine im wöchentlichen Kopf-an-Kopf (Plan Anspruch 2) mitbauen; Konflikte in `enter.S`-Offsets per `static_assert` auf `offsetof` absichern. |
| **Flash-Verschleiß und Speicherplatz** | Teilweise im Plan (Wächter, TRIM) | Geschriebene GB pro Sitzung (`ri_diskio_byteswritten`) in HENGE-BENCH. XS. |
| **Sicherheit vs. Tempo** | – | Bewusst ausgelassen: alles, was SIP aus oder Seed-Pinning braucht. |

---

## 4. Rolle von xtool

Der verlinkte Repo-Eintrag ist tatsächlich xtool (xtool-org/xtool). Für Solstice taugt es aber nicht.

**Henge lässt sich damit nicht bauen.** Der Build braucht actool für Assets und das Icon-Composer-`.icon`, außerdem hdiutil, Apple libtool, codesign und die Cross-Builds per meson/cargo für iOS. xtool 2.0 ist eine Beta (PR #449 offen, v2.0.0-beta.1 vom 16.11.) und unterstützt unter Linux/WSL keine Asset-Kataloge.

**Als Installationsweg kostet es direkt Leistung.**
- Bei kostenlosen Teams verwirft xtool unbekannte Entitlements (Issue #352). EntitlementTypes kennt weder increased-memory-limit noch EVA, und `upsertApp` löscht unbekannte Capabilities an der App-ID. Henge verliert damit IML und fällt auf das kleine Limit bzw. dateibasierten Gast-RAM zurück.
- Das Präfix `XTL-<id>.` erzeugt eine andere App-ID und einen eigenen Container. Das hieße eine zweite macOS-Installation mit mehreren zehn GB bei ~51 GB frei.
- Dazu kommen verbrauchte App-IDs, USB bei jeder Installation und die Xcode-SDK-Lizenz, die nur Apple-Hardware abdeckt.

**Die beworbenen 2–3× schnelleren Builds** gelten nur unter macOS, nur für die Bauzeit, und haben null Wirkung zur Laufzeit.

Was bliebe: ein lesendes `xtool ds profiles list`, das die geplante Anzeige der Entitlements in der App überflüssig macht. Ein ~5-Zeilen-Patch (IML-Capability-Mapping) würde xtool reparieren, lohnt aber nicht.

**Urteil:** unter „Bewusst verworfen“ eintragen, mit dem IML-Verlust als ausschlaggebendem Grund. Weg bleiben CI (`xcode-27`) plus SideStore bzw. AltStore.

---

## 5. Neue Gesamt-Reihenfolge (Top 25, Gewinn pro Aufwand)

| # | Punkt | Phase | Aufwand | Erwarteter Gewinn / Wert | Prüfung |
|---|---|---|---|---|---|
| 1 | **MEM-1** IML signieren (iloader-Import bzw. AltStore) + Text in Plan 1.3 und Einrichtung | 1 | 1 h | Limit ~3,3 → ~6,1 GB; Voraussetzung für 1-GB-Cache und 3-GB-Mac | Gerät, Log |
| 2 | **MP-3** Vorbedingungen des Benchmarks (LPM, Laden, Helligkeit, Thermik-Probe) | 0 | 0,5 T | Entfernt Störgrößen bis 2× | Gerät |
| 3 | **MP-1** A/B in einer Sitzung + Nachtmodus + A/A, mit Startphasen-Zeitstempeln | 0 | 2–3 T | 10–20× mehr belastbare Entscheidungen pro Runde | CI + Gerät |
| 4 | **TR-5** fehlende Helper-, WFE- und Exklusiv-Statistik | 0 | 2 h | Gate für 5 Übersetzerpunkte | CI |
| 5 | **MEM-6** Speicher-Telemetrie (Host-Kompressor, entitled max, Gast-vm_stat) | 0 | 0,5 T | Trennt die Jetsam-Ursachen | Gerät |
| 6 | **GFX-1** GPU-Telemetrie (GPU busy, Round-Trip, leere CBs, Kopien) | 0 | 1 T | Entscheidet GFX-5/6/10/11/13 | Gerät |
| 7 | **MEM-2** TASK_VM_INFO min/max + log_map in Runde 1 | 1 | 1 h | Klärt Jumbo unter iOS 27 → Zweig MEM-5 | Gerät |
| 8 | **MEM-3** Cache-Sweep per HV_JIT_CAP in einem Start, 768-Option, kein 1536 | 1 | 1 h | Vermeidet bekannten Kill; ~0,4 GB physisch nach O5 | Gerät |
| 9 | **TC-01** SIMD-Gate (Aufrufgraph, Baseline, Sentinel-Test, kva_note verschieben) | 0 | 0,5 T | Schützt vor stiller Gast-FP-Korruption | CI |
| 10 | **TC-07 + TC-08** Flavors, Stempel, Xcode-Pin, Fingerabdruck | 0 | 0,5 T | Gültige A/B- und PGO-Builds, stabile Baselines | CI |
| 11 | **TC-03/TR-6** `IOS_CPU=apple-a14` + otool-Guard | 0 | 0,5 h | 0–1 %; CI wird gerätegetreu | CI |
| 12 | **MP-5 + TC-02** Scheduler-Telemetrie (P-Anteil, GHz, Label-Fix) + hvprof-Start/Stopp | 0 | 1,5 T | Entscheidet vCPU-, QoS-, Handoff- und PGO-Fragen | Gerät |
| 13 | **GFX-4** #187 übernehmen (statt eigenem Zero-Copy in Phase 3) | 1 | 0,5 T | Hash/memcpy bei Video weg; Phase-3-Punkt fällt weg | CI + Gerät |
| 14 | **MEM-5 (a)(b)** Gast-RAM vor JIT-Metadaten, Tabellen pro CPU nur für gestartete vCPUs, Freigabe im Fehlerpfad | 1 | 0,5–1 T | ~1–1,5 GB VA; P0 ohne Jumbo | CI + Gerät |
| 15 | **MEM-4** CI-Probe Doppelzählung (dann ggf. periodischer Trim, +1 T) | 0/2 | 2 h | Bis Cache-Größe Footprint (spek.) | CI → Gerät |
| 16 | **GFX-2** #161-Knopf aufteilen + Schutz vor #190 | 1 | 1 h | Absicherung gegen Rückkehr des IRQ-Sturms | Gerät |
| 17 | **MP-4** vCPU-Standard aus perflevels + Cap; Sweep 3 vs. 4 nachts | 1 | 2 h + Nacht | Sign. unbekannt, 10–25 % möglich (spek.) | Gerät |
| 18 | **PLAT-11** Gast-Labor-Job (PV_TICKET, Sysctls, Keys, Daemon-Rangliste) | 0 | 0,5 T | Spart mehrere Geräterunden | CI |
| 19 | **PLAT-1** PV-Ticket-Hypercalls + `ticket_lock_spins` per LaunchDaemon | 2 | 1 T | 0–3 % bei 3–4 vCPUs, Energie (spek.) | CI + Gerät |
| 20 | **GFX-3 + MP-11** vBlank-Raster als Gerätefrist, Kick auf Frist pro vCPU, Sicherheits-Tick (Voraussetzung für Kicker) | 2 | 1,5 T | Macht den ~1000→~60-Wakeups-Kicker sicher | CI + Gerät |
| 21 | **XS-Bündel** TR-4 CLREX, TR-12a IJC-LDP, TR-11a lazy counter, TR-13 ADRP-Fuse | 1 | 0,5 T | Je klein, deterministisch nachweisbar | CI |
| 22 | **TR-3** `HV_TLBT=2` (mit O15 abgestimmt) | 2 | 2–3 T | −2 Wörter pro EL1+PAN-Zugriff, +1–3 % (spek.) | CI + Gerät |
| 23 | **MEM-9a** Ballon vor Hintergrund-Pause | 2 | 2 h | ~1 GB weniger physisch im Hintergrund, weniger verlorene Macs | Gerät |
| 24 | **MP-8** Thermik-/LPM-Politik live (statt Duty-Cycling) | 3 | 1–2 T | Dauerdurchsatz +? (spek.), richtige Erwartung bei LPM | Gerät (Nacht) |
| 25 | **MEM-11** Rückfallpfade (Auto-Größe, anonym mit IML) + **sicherer Modus** `HV_SAFE` | 1 | 0,5 T | Schutz gegen iOS-Update und Regressionen | CI + Gerät |

**Danach (gated, in dieser Reihenfolge):**
- TC-04 PGO (bei ≥20 % Host-C) → TC-05 ThinLTO → TC-06 Zwei-Engine
- GFX-6 (>200 leere CBs/s) → GFX-5/GFX-11 (nach Messung)
- MP-6/MP-7/MP-10 (nach MP-5)
- TR-1 WFE · PLAT-3 · PLAT-8 · PLAT-10 · PLAT-7
- MEM-7/8/9b/10 · MEM-12-Regel
- TC-09 · TC-11
- Rest P3 (TR-2/7/8/10/11b/12b, GFX-8/9/10/12/13/14/16/17, PLAT-2/4/5/9/12/13/14/15/16, MP-12)