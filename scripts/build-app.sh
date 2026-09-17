#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
swift build --disable-sandbox -c release -Xswiftc -warnings-as-errors
BIN="$(swift build --disable-sandbox -c release --show-bin-path)"
APP="$ROOT/dist/Spice Client.app"
rm -rf "$APP"
rm -f "$APP.notarized"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Licenses"
cp "$BIN/SpiceClient" "$APP/Contents/MacOS/SpiceClient"
cp Resources/Info.plist "$APP/Contents/Info.plist"
for name in SwiftSpice_SwiftSpice SwiftSpice_SpiceMetalCompositor; do
    test -d "$BIN/$name.bundle"
    ditto "$BIN/$name.bundle" "$APP/Contents/Resources/$name.bundle"
done
cp LICENSE NOTICE.md "$APP/Contents/Resources/"
cp Vendor/UPSTREAM.json "$APP/Contents/Resources/Licenses/"
cp Vendor/SwiftSpice/LICENSE "$APP/Contents/Resources/Licenses/SwiftSpice-MIT.txt"
cp Vendor/SwiftSpice/THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/Licenses/"
while IFS= read -r -d '' license; do
    relative="${license#Vendor/SwiftSpice/Artifacts/}"
    mkdir -p "$APP/Contents/Resources/Licenses/$(dirname "$relative")"
    cp "$license" "$APP/Contents/Resources/Licenses/$relative"
done < <(find Vendor/SwiftSpice/Artifacts -path '*/Licenses/*' -type f -print0)
if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$APP/Contents/Resources/"; fi
bash scripts/audit-dylib-links.sh "$APP"
codesign --force --deep --sign - --options runtime --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"
echo "Built local verification application: $APP"
