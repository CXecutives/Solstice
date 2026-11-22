# Werkzeuge und Fork-Ernte

> Agenten-Bericht vom 22.11.2026 (Analyse von Henge main 7b55730). Zeilenangaben beziehen sich auf diesen Stand. Wo PLAN.md abweicht, gilt PLAN.md.

I couldn't find a better tool than the current one for most links. The changes worth making are which sideloader you use, which anisette server you use, and one entitlement you can't have. Tags: **[V]** checked against code, release notes, an Apple page or a live probe; **[R]** a user report in an issue; **[I]** my inference; **[B]** blog or SEO claim. All dates are 2026.

## Part 1: Best tool per link

| Link | Pick | Key evidence | Avoid / alternatives |
|---|---|---|---|
| a) Loopback VPN | **LocalDevVPN 1.3.0** (App Store, Coxson Engineering, Aug 31; source at [jkcoxson/LocalDevVPN](https://github.com/jkcoxson/LocalDevVPN), last commit Nov 10) | [V] It only swaps packet source/destination and routes just 10.7.0.1/32, with the default route excluded. URL scheme `localdevvpn://enable` or `disable?scheme=X` calls back after 1 s. Shortcuts actions exist (1.0.1 enable, 1.1.2 stop). | StosVPN is its predecessor ([SideStore/StosVPN](https://github.com/SideStore/StosVPN), last commit Mar 31). WireGuard setups and em_proxy (last push Dec 2024) are legacy. Surge, Loon and Clash modules or router reflectors work but use up your one VPN slot. |
| a') Own VPN extension in Solstice | **Not possible on a free team** | [V] [Apple's capability table](https://developer.apple.com/help/account/reference/supported-capabilities-ios) (modified Nov 18): Network Extensions and Personal VPN are paid-program only. [V] [SideSign Entitlement.swift](https://github.com/SideStore/SideSign/blob/main/Sources/Models/Entitlement.swift) lists `networkExtensions` only in `paidEntitlements`. | Could ship as a paid-team-only option. PR #192's "Device address" setting (skip the VPN) has never been run on a device; worth one experiment. |
| b) JIT enabler | **Henge's built-in StikJIT helper** (StikJIT 2.0.0, Oct 31) with on-device pairing; **StikDebug 3.2.2** (Nov 8) as fallback | [V] 3.2.2 notes say "Fix Utsuro, Henge, and MeloCafe". Henge is auto-assigned `universal.js` (SUPPORTED_APPS.md). [R] [#162](https://github.com/Leviidev/Henge/issues/162): the StikDebug flow froze the app and the built-in helper fixed it. [R] [StikDebug #497](https://github.com/StikDebug/StikDebug/issues/497) (iOS 27.2.1, Nov 21): attach didn't take until the universal script was assigned. | JITStreamer-EB is archived (Mar 2025), SideJITServer is iOS 17 only (last push Jan 2025), Jitterbug archived 2022. A PC-side attach via pymobiledevice3 works [R #497]. Apparition is new and immature. No speed benchmark between the two picks exists. |
| c) Sideloader | **AltStore Classic 2.3.x + AltServer for Windows 1.8.x + Remote AltServer** as daily driver; **iloader 2.4.2** (Nov 20) for USB dev pushes and pairing files | [V] AltStore 2.3 (Sep 30): install and refresh with no PC over Wi-Fi + LocalDevVPN. [R] [SideStore #1616](https://github.com/SideStore/SideStore/issues/1616): AltStore 2.3 keeps increased-memory-limit on a free account. [V] iloader 2.4.1 (Oct 28) turns the memory entitlement on by default, and its `isideload` registers app extensions. [V] Leviidev in [#19](https://github.com/Leviidev/Henge/issues/19): SideStore and AltStore both keep get-task-allow. | **SideStore 0.7.0-alpha** (Sep 15; nightly Oct 27) drops increased-memory-limit on free accounts. #1616 and [SideSign PR #4](https://github.com/SideStore/SideSign/pull/4) are still open; workaround is [GetMoreRam](https://github.com/hugeBlack/GetMoreRam). **Impactor 2.7.3** (Nov 17) is good: registers app plugins, requests the memory entitlement, refreshes from the PC. **Sideloadly 0.71/0.72** is closed source, needs the apple.com iTunes, and doesn't document the memory entitlement. **xtool** is a build/deploy CLI (WSL), not a refresher. **AltStore PAL** needs notarized distribution builds, which have no get-task-allow, so no JIT [I]. |
| d) Pairing files | **On iOS 27, on-device pairing** (Henge: Settings › Developer Mode › "Pair with Henge", device passcode first, per [#222](https://github.com/Leviidev/Henge/issues/222); StikDebug 3.2.0 does it too) | [V] [StikDebug guide](https://github.com/StikDebug/StikDebug-Guide/blob/main/pairing_file.md): on-device method is iOS 27+, the PC method is iloader. [V] [idevice_pair v1.2.0](https://github.com/jkcoxson/idevice_pair) (Nov 16): "Promptless RPPairings", wireless pairing on iOS 27+. | A PC is still needed for AltStore's Remote AltServer pairing (USB once) and for putting a file into SideStore (iloader). jitterbugpair only makes the old lockdown pairing; avoid. |
| e) Windows USB stack | **iTunes from apple.com (64-bit direct download)** | [V] AltServer and Sideloadly both require the non-Store iTunes (AltServer also needs the apple.com iCloud). iloader and Impactor only need Apple Mobile Device Support (idevice talks to 127.0.0.1:27015). | [V] iloader's link `apple.co/ms` points to the **Microsoft Store** iTunes, which breaks AltServer. The Apple Devices app is accepted by iloader and Apparition, not by AltServer. xtool on WSL needs usbipd or the iTunes relay. |
| f) Anisette | **Mac-based servers: mac-ani.jkcoxson.com (iloader's default since 2.4.0) or new.ani.sidestore.io** | [V] Since about Oct 12, Apple rejects the Linux/Android-based v3 server's headers with -80045 ([anisette-v3-server #61](https://github.com/Dadoum/anisette-v3-server/issues/61), open). My probe at about 20:50 UTC today: ani.sidestore.io returned **502**; mac-ani.jkcoxson.com and ani.iloader.app returned 200. | Self-hosting the Docker v3 server is unreliable right now. A server operator sees your IP and the provisioning session, not your password [I]. Apparition's doc says a Mac you own is the most stable source. |
| g) Build, IPA and logs | Upstream `.github/workflows/build-henge.yml` on the free `xcode-27` runner, then install the IPA on the phone through AltStore/SideStore, then read logs over the network | [V] Henge sets `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace`, so henge.log shows in Files and in Apple Devices/iTunes file sharing. not-nullptr's log stream (616435e) sends the log live over TCP to a PC. | xtool 2.0-beta can't build Henge on WSL yet (no asset catalogs; Henge also needs Metal and the macOS SDK for its sample programs). |

### Notes behind the table

- **LocalDevVPN, staying connected [V/I]:**
  - It only has to be up while JIT is being turned on at each launch. Henge claims its JIT region, the debugger detaches, and the region stays (observed in oliverames' notes). It also has to be up for AltStore/SideStore installs and refreshes.
  - Henge already opens `localdevvpn://enable?scheme=henge` itself when the tunnel is down (`C:/Users/owner/AppData/Local/Temp/claude/09d7ec978abda851/a4153b16-327b-44b9-a024-ab3d3e5fe0ef/scratchpad/henge-src/Henge/ios/Henge/JIT/JITSetup.swift`, lines 188–193 and 499–530).
- **LocalDevVPN, after reboot and battery [I]:**
  - Its on-demand rule matches the IPs as domain names, so it probably won't start by itself for raw-IP connections. Plan on the URL call or a Shortcuts automation after a reboot.
  - Battery cost is probably negligible since only one /32 route goes through it, but I found no measurement anywhere.
- **The whole chain is fragile on cellular or filtered networks [R]:** LocalDevVPN can show "Connected" while traffic goes out over cellular (#19, and Henge's retry logic). The first Developer Disk Image download fails with TLS errors behind proxies or campus networks.
- **Extended virtual addressing is paid-only [V]** (same Apple table). This matters a lot for a free-team Solstice build:
  - Generated code only runs below 0x7000000000, and the largest hole there is about 1080 MiB.
  - Take [not-nullptr 4aed49b](https://github.com/not-nullptr/Henge/commit/4aed49b) (don't default the code cache to 1.5 GB without that entitlement).
  - Don't take [PR #78](https://github.com/Leviidev/Henge/pull/78) (1536 MB code-cache fallback) for free builds.
- **Free-account budget:** 3 active apps and 10 App IDs per 7 days. Henge costs 2 App IDs (the app plus HengeJITHelper.appex). The built-in helper saves a StikDebug app slot. LocalDevVPN comes from the App Store and costs nothing.
- **Pairing and sideloader traps:**
  - [V] A new pairing replaces the old one with the same host identifier (Henge source comment; [Madeira docs/JIT.md](https://github.com/willfaust/Madeira/blob/main/docs/JIT.md)). Give Solstice its own pairing host name, as [Monolith 51d4d82](https://github.com/MakrSas/Monolith/commit/51d4d82) did, so it doesn't knock out Henge's pairing. Changing the passcode invalidates all pairings.
  - [V] Madeira's docs say sideloaders that change the bundle ID break the background-task identifier used during pairing, which leaves only about 30 s in the background. Henge uses the same `$(PRODUCT_BUNDLE_IDENTIFIER).pairing.*` mechanism.
  - [R] "The provisioning profile is banned" (0xe8008024) has been reported since Aug 29 ([AltStore #1775](https://github.com/altstoreio/AltStore/issues/1775), [iloader #991](https://github.com/nab138/iloader/issues/991)). The only known fix is a new Apple ID, so keep a spare.
  - [I] Signing with several tools on one Apple ID can revoke each other's certificates. Let one tool own the certificate (iloader can import its certificate into SideStore).
- **Suggested combination:**
  1. Install the apple.com iTunes and iCloud.
  2. Install AltStore Classic 2.3 with AltServer for Windows and set up Remote AltServer (pairs over USB once).
  3. Get LocalDevVPN from the App Store and use Henge's built-in helper with on-device pairing.
  4. Build on GitHub Actions and install new builds on the phone through AltStore. No PC needed after the first setup.
  - Use iloader only for pairing-file and certificate housekeeping, or USB pushes.
  - Known AltStore Remote AltServer bugs: [#1866](https://github.com/altstoreio/AltStore/issues/1866) (stale pairing; fix with Reset and re-pair) and [#1870](https://github.com/altstoreio/AltStore/issues/1870) (UDID).
  - Fallback: SideStore installed by iloader, plus GetMoreRam.

## Part 2: Henge fork survey

**Method:** 234 forks, 149 pushed after Nov 10.
- 33 default branches are ahead of upstream (`7b55730`).
- I also compared about 300 non-default branches.
- Both "Veyron" forks return 404, so I couldn't read them.
- [oliverames' Nov 13 fork scan](https://github.com/oliverames/Henge/blob/main/docs/research/fork-scan-2026-11-13.md) is worth reusing; it includes the scan script.
- Upstream has merged nothing since #205 (Nov 15). About 80 PRs are open.

**Ranked forks to harvest:**

1. **[oliverames/Henge](https://github.com/oliverames/Henge)** (138 commits ahead). All of these are open PRs:
   - [#186](https://github.com/Leviidev/Henge/pull/186) (+1085/−159): segmented code-cache ring, cheaper eviction, hot system registers inlined. Evictions measured on an iPhone Duo at 112–268 ms each, about 1% of wall time; no proven speed gain.
   - [#188](https://github.com/Leviidev/Henge/pull/188) (+249/−26): GPU delete-task fix and compiled pipelines kept across launches.
   - [#192](https://github.com/Leviidev/Henge/pull/192) (+452/−46): reads TXM from the device tree (Duo logs), LiveContainer support (untested), route-based VPN check, device address setting.
   - [#189](https://github.com/Leviidev/Henge/pull/189): sturdier JIT script.
   - [#187](https://github.com/Leviidev/Henge/pull/187): multi-plane surfaces.
   - [#134](https://github.com/Leviidev/Henge/pull/134): profiler.
   - [#176](https://github.com/Leviidev/Henge/pull/176): -O3 and network batching; Mac only, not tried on a device.
   - Its [performance notes](https://github.com/oliverames/Henge/blob/main/docs/research/performance-iphone-duo.md) find about 35% of translated-code time on three software-TLB loads, plus thermal-driven TLB-acknowledgement waits.
2. **[lemmylin/Henge](https://github.com/lemmylin/Henge)**:
   - [#214](https://github.com/Leviidev/Henge/pull/214) (+237/−5): background keep-alive, memory given back under pressure, sizing for 8 GB devices. The problem was diagnosed on an iPad Pro M4.
   - [#218](https://github.com/Leviidev/Henge/pull/218) (+47/−8): engine defaults. iPhone result is directional only and it's a draft: TLB-acknowledgement waits went from 76% of a core to 4–9%.
   - Also #215, #216, #217, #219.
3. **[Tomba247/Henge](https://github.com/Tomba247/Henge)** (branches `henge-perf`, `perf-night`, `league-el0`). None of these are PRs:
   - [2797ea5](https://github.com/Tomba247/Henge/commit/2797ea5) (+1/−1): 8192-entry TLB, which attacks the TLB hotspot. 12 bits was too small on the phone.
   - [a3ca070](https://github.com/Tomba247/Henge/commit/a3ca070): compact exit stubs.
   - [a218623](https://github.com/Tomba247/Henge/commit/a218623): cross-page jump data moved to the literal pool.
   - [2f8b1e0](https://github.com/Tomba247/Henge/commit/2f8b1e0) and [2d9fa9d](https://github.com/Tomba247/Henge/commit/2d9fa9d): more system registers handled inline.
   - [5af8fe0](https://github.com/Tomba247/Henge/commit/5af8fe0): GPU render targets for object type 12 (League of Legends).
   - Refresh-time fix [#161](https://github.com/Leviidev/Henge/pull/161) is a PR.
   - **Negative result tested on a device:** direct-mapped guest memory made the Mac 5–10x slower ([3c50320](https://github.com/Tomba247/Henge/commit/3c50320)). Keep PR #157's version of it off.
4. **[liukaixiang817](https://github.com/liukaixiang817/Henge)**: [#121](https://github.com/Leviidev/Henge/pull/121) (+201/−4) releases address reservations before sizing guest RAM. Verified on a device: the largest mapping went from 2.5 to 16.9 GB. Take it over #169, #211 and the other copies. [#51](https://github.com/Leviidev/Henge/pull/51) is an experimental Rosetta engine.
5. **[Elvis-Luo](https://github.com/Elvis-Luo/Henge)**: [#207](https://github.com/Leviidev/Henge/pull/207) (+176/−9) fixes the "signal 4" crash from GPU surfaces over 64 MB; must-have. [#206](https://github.com/Leviidev/Henge/pull/206) is Rosetta 2 (+848). [#209](https://github.com/Leviidev/Henge/pull/209) fixes scroll drift.
6. **[bradenriggins](https://github.com/bradenriggins/Henge)**: one-line defaults, measured on a Mac only:
   - [#81](https://github.com/Leviidev/Henge/pull/81) superblocks on: −1.9 s cold boot.
   - [#80](https://github.com/Leviidev/Henge/pull/80) CPU thread priority: −1.6 s.
   - [#74](https://github.com/Leviidev/Henge/pull/74): shared-folder visibility from 69 s to 5 s.
   - [#73](https://github.com/Leviidev/Henge/pull/73): fixes the macOS 27.2 install panic.
   - #78 conflicts with the free-team limit (see Part 1).
7. **[clyecao `perf/vm-optimizations`](https://github.com/clyecao/Henge/tree/perf/vm-optimizations)** (53 commits, not PRs, **no sign of device testing, committed today**). Rich but high risk:
   - Perf batches 1–3: [1731aa9](https://github.com/clyecao/Henge/commit/1731aa9) (+169), [5e8148e](https://github.com/clyecao/Henge/commit/5e8148e) (+683), [8534a75](https://github.com/clyecao/Henge/commit/8534a75) (+531). These cover tuned defaults, conditional ISB, a Bloom filter, TLB dirty bitmaps, interrupt-controller bitmasks, scattered disk I/O and GPU batching.
   - Micro-benchmarks [2c6745c](https://github.com/clyecao/Henge/commit/2c6745c).
   - Instruction-encoding validator [4ec5628](https://github.com/clyecao/Henge/commit/4ec5628) (+11.7k lines, adds VIXL tables).
8. **[eltomato89](https://github.com/eltomato89/Henge)**: [#166](https://github.com/Leviidev/Henge/pull/166) (+22/−6) uses only a RemotePairing port that is open on this device; same idea as DrRamm's [#130](https://github.com/Leviidev/Henge/pull/130). Also #167, #170 and `docs/performance-notes.md`.
9. **[not-nullptr `feat/perf`](https://github.com/not-nullptr/Henge/tree/feat/perf)** (128 commits behind): 4aed49b (+9/−2, free-team critical) and [616435e](https://github.com/not-nullptr/Henge/commit/616435e) (+976, live log stream).
10. **[zightning-code `perf-build`](https://github.com/zightning-code/Henge/tree/perf-build)**: no original engine code, just CI fixes. Useful as a ready merge of #161, #168, #176, #186, #188, #207 and #211.

**Also useful:**
- [Gohro's #164](https://github.com/Leviidev/Henge/issues/164): grouped memory accesses were about 11% faster on an iPad mini (measured on the device).
- [abetinoco e4798b0](https://github.com/abetinoco/Henge/commit/e4798b0): steadier display refresh timing.
- Monolith 51d4d82 (distinct pairing host).

**Conflicts:**
- [m7830380-cyber f48b012](https://github.com/m7830380-cyber/Henge/commit/f48b012) puts back the task-ID shift that #188 removes. #188 is backed by Apple's own code, so take #188.
- Don't take lunarduststudio's removal of the thermal throttle (from oliverames' scan).

**The forks you named:**
- lemmylin and oliverames: high value.
- not-nullptr: medium (two commits).
- dajgduyqwgdq: low (one CI commit, plus a copy of #209).
- CORBENDALLAS111: low for performance. It has 20 commits ahead plus about 10 branches of input, Pencil, Apple Account and Ventura GPU churn, mostly AI-generated; [0eadeb8](https://github.com/CORBENDALLAS111/Henge/commit/0eadeb8) (GPU surface mappings) is maybe worth a look.
- Chenyu550: only a build fix already covered by #168.
- zightning-code: integration reference only.
- cucaichuadien-tech: only a subset of #186.
- stride-praline's #196–#204 (5k–25k lines each, squashed, no PR descriptions) aren't reviewable.

**Competitors:** nothing beats Henge at macOS on iOS.
- [UTM runs macOS guests only on Apple-silicon Macs](https://docs.getutm.app/guest-support/macos/), not on iOS.
- [Monolith](https://github.com/MakrSas/Monolith) is a Henge fork that adds HomePod, HomeView and Watch guests; broader, but no better at macOS.
- [Madeira](https://github.com/willfaust/Madeira) runs Windows games through FEX and Wine. It uses the same built-in StikJIT approach, and its docs are a good JIT reference.
- Tuxedo (Debian), Lintel (Windows board) and the Android ports aren't macOS competitors.
