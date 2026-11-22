# Übergabe

## Stand (22.11.2026, Block 1)
Code für Block 1 fertig, auf Branch `picks` (wird nach grünem Build nach `main` gemergt).
- Grundausstattung: `CLAUDE.md`, `tools/check.sh` / `tools/check-all.sh`, `tools/simd_gate.py`, Workflow
  `build-henge.yml` (manuell; Eingaben `tests` und `ipa`; ~4 min mit Husk-Cache).
- Übernommen: #214 #121 #166 #207 #188 #187 #161 #142 #137 #73 #183 #215 #109 #209, not-nullptr `4aed49b`
  (zusammengeführt mit #214: 1,5 GB Code-Cache nur mit EVA + >8 GB) und der Log-Stream aus `616435e`
  (ohne Performance-Marks), abetinoco `e4798b0` (vBlank-Uhr, kombiniert mit #161), eigener Pairing-Name.
- #187 ersetzt #207s Seitenleser für Oberflächen (beide behoben dasselbe; #187 folgt Apples Seitentabelle).
- Eigene Änderungen: nur Sequoia 15.6.1; Download ohne JIT, Restore wartet auf JIT; Disk 40–64 GB nach
  freiem Platz; Write-Cache nach Restore wieder an; neuer Mac startet direkt; JIT beim Start standardmäßig an,
  nach Kopplung automatisch weiter; Autostart des letzten Macs mit Schutz nach 2 Fehlstarts;
  Geräteprofil-Tabelle (`Device.profile` in `Hardware.swift`); `HV_SYNC_WAIT=1`, `HV_RANGE_DROP=256`,
  `HV_STATS=30`, teure Diagnosen nur mit `HV_STATS_DEEP`; GPU-Hygiene + Kanal-Retry bei Türklingel;
  Netz weckt nur bei leer→voll; schlankes macOS (Set Up ruft Lighter, inkl. Spotlight/Updates mit Passwort).
- `-mcpu=apple-a14` für alle iOS-Objekte; KVA-Init aus dem Refill-Pfad; `knobs_init` auch für Tests.

## Entscheidungen
Siehe `PLAN.md`. Zusätzlich: Air 4 bekommt 2 GB/2 vCPUs/Large-Screen über die Profiltabelle;
#214 deckelt Gast-RAM ohnehin (≤6,7 GB phys → 2 GB, ≤8,7 GB → 3 GB).

## Offen / zurückgestellt (mit Grund)
- IJC-Tabellen nur für gestartete vCPUs: kostet nur Adressraum, keinen Speicher (calloc, unberührt) →
  erst nach Air-4-Log („largest mapping“) entscheiden (Block 2).
- Festplatten-Wächter (< 6 GB frei → pausieren): noch nicht gebaut; Disk ist jetzt so bemessen, dass sie das
  Gerät nicht füllen kann. TRIM für die Hauptdisk kommt in Block 3.
- Sicherer Modus `HV_SAFE`: noch nicht gebaut (Autostart-Schutz existiert).
- SIMD-Gate: Wurzeln sind voll inline (keine Aufrufe gefunden); prüft SIMD-Register darin.

## Stand 23.11. ~00:00 (Pause für PC-Neustart)
- Block 1 ist in `main`, IPA in `out/Solstice.ipa` (+ `out/Solstice-Basis.ipa` als Rückfall), `out/GetMoreRam.ipa`.
- Welle 1 läuft als 4 Helfer in Worktrees (`.claude/worktrees/…`), je eigener Branch auf origin:
  Übersetzer (`solstice/translator`), Mehrkern/Energie (`solstice/mp-power`), Grafik/IO (`solstice/gpu-io`),
  Code-Cache (`solstice/codecache`). Bei Pause: WIP-Commit + Push. Fortsetzen per Nachricht an den Helfer,
  sonst Branch lesen und neu beauftragen. Merge-Reihenfolge: translator → mp-power → gpu-io → codecache (rebased).
- CI: `san`-Eingabe (UB-Traps) ist in `main`; jeder Helfer muss vor Abgabe `SOLSTICE_SAN=true` grün haben.
- **Sideloading geändert:** AltServer erkannte das iPhone nicht → **iloader → SideStore → Solstice + GetMoreRam**
  (IML per GetMoreRam an `com.henge.app.<TEAM>`, danach Solstice in SideStore „Reinstall“). PLAN.md nennt noch
  AltStore; HANDOFF gilt.
- PC: AltServer, iCloud, iTunes, Bonjour, Apple Application Support, Apple Software Update und der alte
  Apple Mobile Device Support sind deinstalliert. Installiert: **iloader 2.4.2** (winget `nabdev.iloader`) und
  **Apple-Geräte** (Store, `AppleInc.AppleDevices`) – deren Dienst passt zum WinUSB-Treiber `appleusb.inf`
  am iPhone. Vor dem Neustart sah der Dienst auf 127.0.0.1:27015 noch 0 Geräte → nach Neustart prüfen
  (ListDevices-Probe per Python, siehe Sitzung).
- Log-Empfänger nach Neustart neu starten: `py -3 -u tools/henge-log-listen.py --quiet --out henge-stream.log`
  (PC-Adresse <PC-ADDRESS>, Port 7777).

## Stand 23.11. ~00:20 (zweiter Neustart, frischer Start fürs Sideloading)
- Alle Apple-/Sideload-Programme samt Treibern, Ordnern, Registry, Autostart, Firewall-Regeln und gespeicherten
  Apple-ID-Daten entfernt (Skript im Scratchpad `cleanup-apple.ps1`). Grund: iPhone war für den Apple-Dienst nur
  ~10 s sichtbar und verschwand wieder (USB blieb verbunden) → frisch neu einrichten.
- Neu-Installation nach Neustart, in dieser Reihenfolge: Apple-Geräte (Store, winget `9NP83LWLPZ9K`) öffnen →
  iPhone anstecken, „Vertrauen“ → ListDevices-Probe muss 30 s stabil 1 zeigen → iloader (winget `nabdev.iloader`)
  → SideStore → Solstice + GetMoreRam.
- Helfer alle pausiert und gepusht: translator `3c84f83`, mp-power `98e48fb`, codecache `5bf3888`;
  gpu-io ist in `main` gemergt. Nach Neustart: Helfer per Nachricht fortsetzen.

## Als Nächstes
1. Grüner Build → `picks` nach `main`, IPA nach `out/Solstice.ipa`.
2. Besitzer: Einrichtung (PLAN.md „Einrichtung“), IPA über AltStore auf iPhone 16 Pro und iPad Air 4,
   Log-Stream in den Einstellungen auf den PC (`py -3 tools/henge-log-listen.py`).
3. Log auswerten (IML an? largest mapping? Jetsam? Flushes? TLBI-Warten?), dann Block 2 (Übersetzer).
