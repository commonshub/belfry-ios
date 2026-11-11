#!/usr/bin/env bash
# Boots an iPhone simulator, installs the built app and captures the main screens in demo mode
# (seeded data, nothing leaves the device). Usage: scripts/screenshots.sh <path to Belfry.app> <out dir>
set -euo pipefail
APP="$1"
OUT="$2"
BUNDLE=sh.belfry.app
mkdir -p "$OUT"

pick() {
  xcrun simctl list devices available -j | python3 -c '
import json, sys
d = json.load(sys.stdin)["devices"]
names = ["iPhone 16 Pro", "iPhone 16", "iPhone 15 Pro", "iPhone 17 Pro"]
for want in names:
    for rt, devs in sorted(d.items(), reverse=True):
        for x in devs:
            if x["name"] == want and "iOS" in rt:
                print(x["udid"]); sys.exit(0)
for rt, devs in d.items():
    for x in devs:
        if x["name"].startswith("iPhone") and "iOS" in rt:
            print(x["udid"]); sys.exit(0)
'
}
UDID=$(pick)
echo "simulator $UDID"
xcrun simctl boot "$UDID" || true
xcrun simctl bootstatus "$UDID" -b
xcrun simctl status_bar "$UDID" override --time "9:41" --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3 || true
xcrun simctl install "$UDID" "$APP"

shot() { # name screen appearance
  xcrun simctl ui "$UDID" appearance "$3" || true
  xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
  if [ "$2" = "signin" ]; then
    xcrun simctl launch "$UDID" "$BUNDLE" >/dev/null
  else
    xcrun simctl launch "$UDID" "$BUNDLE" -demo -screen "$2" >/dev/null
  fi
  sleep "${WAIT:-6}"
  xcrun simctl io "$UDID" screenshot "$OUT/$1.png"
  echo "captured $1"
}

shot 01-sign-in signin light
shot 02-channels channels light
shot 03-feed feed light
shot 04-thread thread light
shot 05-details details light
shot 06-invite invite light
shot 07-messages messages light
shot 08-conversation conversation light
shot 09-email mail light
shot 10-search search light
shot 13-pulldown pulldown light
shot 14-message-menu menu light
shot 15-delete-confirm delete light
shot 16-edit edit light
shot 17-thread-screen threadscreen light
shot 18-channel-search chsearch light
shot 19-add-menu add light
shot 20-pod pod light
shot 21-proposal proposal light
shot 22-event event light
shot 11-feed-dark feed dark
shot 12-channels-dark channels dark
xcrun simctl ui "$UDID" appearance light || true
