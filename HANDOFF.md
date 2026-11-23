# Übergabe

## Stand (23.11.2026, letzter Durchlauf)
Solstice ist fertig gebaut: alles in `main`, nur noch `main` (lokal und auf origin), keine Helfer-Worktrees.
Final-IPA: `out/Solstice.ipa` aus `tools/check-all.sh` (alle Engine-Tests normal, mit den ausgelieferten
Einstellungen + ThinLTO und mit UB-Traps; Fuzzer; SIMD-Gate; iOS-Build). Offen ist nur der Gerätetest.

## Was drin ist
- **Basis (Block 1):** Henge `7b55730` + #214 #121 #166 #207 #188 #187 #161 #142 #137 #73 #183 #215 #109 #209,
  not-nullptr `4aed49b` und Log-Stream `616435e`, abetinoco `e4798b0`. Nur macOS 15.6.1; Ein-Tipp-Start
  (JIT automatisch, Autostart mit Schutz nach 2 Fehlstarts, Sicherheitsmodus `HV_SAFE`), Disk 40–64 GB nach Platz.
- **Übersetzer:** kompakte Slow-Paths (−22 % Code), Groups v2 (Standard an), 8192-TLB, Refill für alle Formen,
  Systemregister/CLREX inline, IJC per LDP, ADRP+ADD gefaltet.
- **Mehrkern/Energie:** Statistik pro CPU, kürzere TLBI-Wartezeiten (`HV_SYNC_WAIT=1`, `HV_RANGE_DROP=256`),
  fristgesteuerter Kicker (~35–45 statt 1000 Wakeups/s), PV-Ticket-Locks, WFE bis zur Timer-Frist.
- **Leichter Pfad:** SVC/ERET/WFE ohne SIMD-Sicherung (`core/light.c`, ~92 Befehle weniger pro Paar), kein ISB bei
  Treffern im eigenen Sprung-Cache, billigere Dispatcher-Ausgänge.
- **Code-Cache:** segmentiert und generationell, ohne Stillstand; Größe nach Gerät (4 GB: 384 MB, 6–8 GB: 768 MB,
  12–16 GB: 1,5 GB mit EVA sonst 1 GB).
- **Speicher:** Block-Records 80→40 B, Slots 64→48 B, Tabellen nur für gestartete CPUs, RAM vor den Engine-Tabellen
  reserviert, `henge_vm_trim()` vor der Hintergrund-Pause; Ballon nach System-Reserve (`Device.profile.headroomMB`,
  1-s-Sampler in `KeepAlive.swift`) statt erst bei iOS-Warnung.
- **Hitze/Strom (`PowerPolicy.swift`):** Stromsparmodus → kein WFI-Spin; heiß → Bildausgabe 30 Hz; kritisch → Pause,
  weiter erst im Vordergrund und kühler.
- **Grafik/IO:** Objekt-Cache per Index, Zeiger-Ebene, Present-Pacing, vBlank-Periode pro Mac; Disk preadv/QD8/TRIM;
  Netz weckt nur bei leer→voll.
- **Gast:** Set Up ruft nur `tune` (unsichtbar: keine Hintergrund-Updates, kein Power Nap, LaunchDaemon mit
  Ticket-Spins 8 und Timer-Slack für Hintergrund-QoS/Tier 3). Sichtbares (Animationen, Spotlight, Siri …) nur über
  den optionalen Befehl „Lighter macOS“; `unlighten` nimmt alles zurück.
- **iPad:** #170 Trackpad-Klick, #167 Zwei-Finger-Scrollen, #123 Stage Manager (USB-Absolutzeiger).
- **Prüfung:** `tools/shipped_env.py` erzeugt die ausgelieferten Einstellungen aus `EngineTuning.swift` für CI;
  `tools/simd_gate.py` liest Aufrufe aus den BR26-Relokationen (vorher sah es keine).

## Entscheidungen (mit Grund)
- **Impactor statt SideStore:** beantragt `increased-memory-limit` selbst, registriert die JIT-Erweiterung; SideStores
  Anisette-Server war ausgefallen. Preis: Auffrischen alle 7 Tage über den PC (automatisch per WLAN, wenn er läuft).
- **macOS sieht aus wie immer** (Wunsch des Besitzers): nur Unsichtbares automatisch.
- **Stromsparmodus halbiert die Bildrate nicht** (iOS selbst bleibt bei 60 Hz); 30 Hz nur bei Hitze.
- **HV_HOIST_CHECK aus:** +2,3–2,5 % Code im Fuzzer-A/B (Grenze 2 %). **Superblocks aus:** mehr Code, ungemessen.
- **Weggelassen:** Vor-Übersetzung auf E-Kernen, Lazy-FP, TLBT=2, PGO, flüchtige GPU-Heaps, RW-Alias-Trim,
  vBlank-Gating – Risiko ohne Gerätedaten, Gewinn unbekannt.
- **Bildgröße:** Air 4 startet mit „Larger“ (1280×888), iPhone mit 1536×864; pro Mac unter „Size“ änderbar.

## Sideloading auf diesem PC
- Apples USB-Filter (Treiber 552) stürzt am **Chipsatz-USB** ab → iPhone/iPad **hinten an den Prozessor-USB**
  (AMD USB 3.10) und Treiber **538** (Microsoft Update Catalog). `tools/windows-sideload.ps1` (ein UAC-Klick, Gerät
  eingesteckt) entfernt iTunes-App und LocalSend, behält Apple Mobile Device Support, pinnt 538, versteckt 552.
- Impactor 2.7.3 portable: `%LOCALAPPDATA%\Programs\Impactor\Impactor.exe` (Desktop/Startmenü), Anisette
  `mac-ani.jkcoxson.com`. iloader ist entfernt.

## Als Nächstes (Besitzer)
1. Gerät hinten einstecken, `tools/windows-sideload.ps1` ausführen.
2. Impactor → Apple-ID → `out/Solstice.ipa` (erst iPhone 16 Pro, dann iPad Air 4; SideStore vom iPhone löschen) →
   Entwickler vertrauen → Entwicklermodus → Solstice öffnen → JIT-Kopplung → macOS installieren (≥ 40 GB frei).
3. Log-Stream an den PC: `py -3 -u tools/henge-log-listen.py --quiet --out henge-stream.log` (<PC-ADDRESS>:7777).
   Im Log prüfen: IML an, keine Jetsam-Beendigung, Ballon-Schritte („memory“), „code cache:“, „power“.
