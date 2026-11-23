#!/bin/bash
# Photographs every screen of the app in the simulator, with sample data (ios/Screens): builds ios/screens.yml for the
# simulator, boots an iPhone 16 Pro and an 11-inch iPad Air, and for each screen the app lists, each device and both
# appearances, launches it on that screen, waits for its ready marker and takes a screenshot. Writes
# <device>-<appearance>-<screen>.png and index.html into SCREENS_OUT (default ios/build/screens).
# Runs on a Mac with Xcode and XcodeGen (the Screens job in .github/workflows/build-henge.yml).
set -euo pipefail
IOS="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${SCREENS_OUT:-$IOS/build/screens}"
BUNDLE=com.solstice.screens
SECONDS=0
cd "$IOS"
rm -rf "$OUT" && mkdir -p "$OUT" "$IOS/build"

xcodegen generate --spec screens.yml > /dev/null
DD="$IOS/build/ScreensData"
xcodebuild -project Screens.xcodeproj -scheme Screens -configuration Debug -sdk iphonesimulator \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DD" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build > "$DD.buildlog" 2>&1 || {
    grep -E "error:|Undefined symbols|referenced from|BUILD" "$DD.buildlog" | sort -u | head -100
    echo "==> the simulator build failed" >&2
    exit 1
}
APP="$DD/Build/Products/Debug-iphonesimulator/Solstice.app"
echo "==> built in ${SECONDS}s"

# The newest iOS runtime that offers both devices (an iPhone 16 Pro, else the newest iPhone Pro; the newest 11-inch
# iPad Air), and their device types. Some runtimes are for one device only: those are passed over.
read -r RUNTIME PHONE PAD < <(xcrun simctl list runtimes -j | python3 -I -c 'import json, re, sys
def pick(types, pattern):
    m = [t["identifier"] for t in types if re.search(pattern, t["name"])]
    return m[-1] if m else None
for r in reversed(json.load(sys.stdin)["runtimes"]):
    if r.get("platform") != "iOS" or not r.get("isAvailable"):
        continue
    types = r.get("supportedDeviceTypes", [])
    phone = pick(types, r"^iPhone 16 Pro$") or pick(types, r"^iPhone \d+ Pro$")
    pad = pick(types, r"^iPad Air 11-inch")
    if phone and pad:
        print(r["identifier"], phone, pad)
        break') || true
[ -n "${PAD:-}" ] || { echo "no iOS runtime with an iPhone Pro and an 11-inch iPad Air:" >&2; xcrun simctl list runtimes >&2; exit 1; }
echo "==> $RUNTIME: $PHONE, $PAD"

# A simulator command that may hang gets this many seconds (simctl reads no stdin here: the screen list is on it).
limit() { local s="$1"; shift; perl -e 'alarm shift; exec @ARGV' "$s" "$@" < /dev/null; }

# Boots a device (its first boot sets the system up: minutes), cleans its status bar and installs the app.
prepare() { # label udid
    local t0=$SECONDS
    limit 900 xcrun simctl bootstatus "$2" -b > /dev/null
    echo "==> $1 booted in $((SECONDS - t0))s"
    limit 600 xcrun simctl status_bar "$2" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
        --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100 > /dev/null
    echo "==> $1 status bar set at $((SECONDS - t0))s"
    # The keyboard's first-use introduction (slide to type) would cover the key row.
    limit 60 xcrun simctl spawn "$2" defaults write com.apple.keyboard.preferences DidShowContinuousPathIntroduction -bool true || true
    limit 600 xcrun simctl install "$2" "$APP"
    echo "==> $1 has the app at $((SECONDS - t0))s"
}

# Launches the app with an argument and waits for its marker (wait: tenths of a second); prints what the marker says.
launch() { # udid container argument [wait]
    local marker="$2/tmp/solstice-preview-ready"
    rm -f "$marker"
    limit 60 xcrun simctl launch --terminate-running-process "$1" "$BUNDLE" -solsticePreview "$3" > /dev/null || { echo "launch failed"; return; }
    for _ in $(seq 1 "${4:-120}"); do
        [ -s "$marker" ] && { cat "$marker"; return; }
        sleep 0.1
    done
    echo timeout
}

# Every screen on one device, in both appearances (a session only in dark: it is always dark).
shoot_all() { # label udid
    local label="$1" udid="$2" container ready name flags file
    container="$(xcrun simctl get_app_container "$udid" "$BUNDLE" data)"
    for appearance in light dark; do
        limit 60 xcrun simctl ui "$udid" appearance "$appearance"
        while read -r name flags; do
            [ -n "$name" ] || continue
            [ "$SECONDS" -lt "$DEADLINE" ] || { echo "::warning::$label: out of time, $appearance $name and after not taken"; break 2; }
            case " $flags " in *" dark-only "*) [ "$appearance" = dark ] || continue ;; esac
            ready="$(launch "$udid" "$container" "$name")"
            [ "$ready" = skip ] && continue
            [ "$ready" = "$name" ] || echo "::warning::$label $appearance $name: not ready ($ready); photographed anyway"
            # The app's log, for a screen that was not ready and for each session (it says what the session was doing).
            if [ "$ready" != "$name" ] || [ "${name#session}" != "$name" ]; then
                mkdir -p "$OUT/logs" && cp "$container/Documents/solstice.log" "$OUT/logs/$label-$appearance-$name.log" 2>/dev/null || true
            fi
            sleep 0.3
            file="$OUT/$label-$appearance-$name.png"
            limit 30 xcrun simctl io "$udid" screenshot --type=png "$file" > /dev/null 2>&1 || echo "::warning::$label $appearance $name: no screenshot"
            echo "$label $appearance $name ${SECONDS}s"
            # simctl photographs the panel as it is mounted: a landscape screen comes out on its side.
            case " $flags " in *" landscape "*)
                w="$(sips -g pixelWidth "$file" | awk '/pixelWidth/ {print $2}')"
                h="$(sips -g pixelHeight "$file" | awk '/pixelHeight/ {print $2}')"
                [ -n "$w" ] && [ "$w" -lt "$h" ] && sips -r 270 "$file" > /dev/null ;;
            esac
        done < "$OUT/screens.txt"
    done
    xcrun simctl terminate "$udid" "$BUNDLE" > /dev/null 2>&1 || true
    echo "==> $label done at ${SECONDS}s"
}

# Whatever happens, the app's crash reports go with the screenshots.
diagnose() {
    mkdir -p "$OUT/crashes"
    find ~/Library/Logs/DiagnosticReports -name 'Solstice*' -newer "$DD.buildlog" -exec cp {} "$OUT/crashes/" \; 2>/dev/null || true
    rmdir "$OUT/crashes" 2>/dev/null || true
}
trap diagnose EXIT
# Whatever is left after this many seconds is not photographed, so that what was taken is still uploaded.
DEADLINE=$((SECONDS + ${SCREENS_MINUTES:-40} * 60))

# One device after the other: two at once on the runner made each step several times slower (2026-11-23).
# A device the runner image already has is used if there is one (it may have booted before, which saves minutes).
device() { # label type
    local udid container listed made=""
    udid="$(xcrun simctl list devices -j | python3 -I -c 'import json, sys
runtime, kind = sys.argv[1], sys.argv[2]
d = [x for x in json.load(sys.stdin)["devices"].get(runtime, []) if x.get("deviceTypeIdentifier") == kind and x.get("isAvailable")]
print(d[0]["udid"] if d else "")' "$RUNTIME" "$2")"
    if [ -z "$udid" ]; then udid="$(xcrun simctl create "Screens $1" "$2" "$RUNTIME")"; made=1; fi
    echo "==> $1: ${made:+new }device $udid"
    prepare "$1" "$udid"
    container="$(xcrun simctl get_app_container "$udid" "$BUNDLE" data)"
    if [ ! -s "$OUT/screens.txt" ]; then
        # The app's own list of screens (Screen.all). The first launch after a boot can be slow.
        listed="$(launch "$udid" "$container" list 400)"
        [ "$listed" = list ] || {
            echo "the app did not list its screens ($listed)" >&2
            mkdir -p "$OUT/logs"
            cp "$container/Documents/solstice.log" "$OUT/logs/list.log" 2>/dev/null || true
            limit 30 xcrun simctl io "$udid" screenshot --type=png "$OUT/logs/list.png" > /dev/null 2>&1 || true
            exit 1
        }
        cp "$container/tmp/solstice-preview-list" "$OUT/screens.txt"
        echo "==> $(wc -l < "$OUT/screens.txt" | tr -d ' ') screens"
    fi
    shoot_all "$(echo "$1" | tr '[:upper:]' '[:lower:]')" "$udid"
    limit 120 xcrun simctl shutdown "$udid" || true
    [ -z "$made" ] || limit 120 xcrun simctl delete "$udid" || true
}
device iPhone "$PHONE"
device iPad "$PAD"

python3 -I "$IOS/scripts/screens_index.py" "$OUT"
echo "==> $(ls "$OUT"/*.png | wc -l | tr -d ' ') screenshots in ${SECONDS}s"
