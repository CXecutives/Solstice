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
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO build > "$DD.buildlog" 2>&1 || {
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

# Boots one device and installs the app; prints its UDID.
prepare() {
    local udid
    udid="$(xcrun simctl create "Screens $1" "$2" "$RUNTIME")"
    xcrun simctl boot "$udid"
    xcrun simctl bootstatus "$udid" -b > /dev/null
    xcrun simctl status_bar "$udid" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
        --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100 > /dev/null
    xcrun simctl install "$udid" "$APP"
    echo "$udid"
}

# Launches the app with an argument and waits for its marker; prints what the marker says ("timeout" if none).
launch() { # udid container argument
    local marker="$2/tmp/solstice-preview-ready"
    rm -f "$marker"
    xcrun simctl launch --terminate-running-process "$1" "$BUNDLE" -solsticePreview "$3" > /dev/null
    for _ in $(seq 1 200); do
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
        xcrun simctl ui "$udid" appearance "$appearance"
        while read -r name flags; do
            [ -n "$name" ] || continue
            case " $flags " in *" dark-only "*) [ "$appearance" = dark ] || continue ;; esac
            ready="$(launch "$udid" "$container" "$name")"
            [ "$ready" = skip ] && continue
            [ "$ready" = "$name" ] || echo "::warning::$label $appearance $name: not ready ($ready); photographed anyway"
            sleep 0.3
            file="$OUT/$label-$appearance-$name.png"
            xcrun simctl io "$udid" screenshot --type=png "$file" > /dev/null 2>&1
            # simctl photographs the panel as it is mounted: a landscape screen comes out on its side.
            case " $flags " in *" landscape "*)
                w="$(sips -g pixelWidth "$file" | awk '/pixelWidth/ {print $2}')"
                h="$(sips -g pixelHeight "$file" | awk '/pixelHeight/ {print $2}')"
                [ "$w" -lt "$h" ] && sips -r 270 "$file" > /dev/null ;;
            esac
        done < "$OUT/screens.txt"
    done
    xcrun simctl terminate "$udid" "$BUNDLE" > /dev/null 2>&1 || true
    echo "==> $label done at ${SECONDS}s"
}

IPHONE_UDID="$(prepare iPhone "$PHONE")"
IPAD_UDID="$(prepare iPad "$PAD")"
echo "==> booted in ${SECONDS}s"

# The app's own list of screens (Screen.all), from the iPhone.
container="$(xcrun simctl get_app_container "$IPHONE_UDID" "$BUNDLE" data)"
[ "$(launch "$IPHONE_UDID" "$container" list)" = list ] || { echo "the app did not list its screens" >&2; exit 1; }
cp "$container/tmp/solstice-preview-list" "$OUT/screens.txt"
echo "==> $(wc -l < "$OUT/screens.txt" | tr -d ' ') screens"

shoot_all iphone "$IPHONE_UDID" &
phone_job=$!
shoot_all ipad "$IPAD_UDID"
wait "$phone_job"

python3 -I "$IOS/scripts/screens_index.py" "$OUT"
for udid in "$IPHONE_UDID" "$IPAD_UDID"; do xcrun simctl shutdown "$udid" || true; xcrun simctl delete "$udid" || true; done
echo "==> $(ls "$OUT"/*.png | wc -l | tr -d ' ') screenshots in ${SECONDS}s"
