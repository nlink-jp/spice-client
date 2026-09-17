#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# The version is git describe output handed down by the Makefile; it is written
# into Info.plist here and read back from the bundle, never stated in sources.
VERSION="${1:?usage: build-app.sh <version>}"
# macOS picks the window chrome generation from the SDK recorded in the binary's
# LC_BUILD_VERSION. The Xcode 27 toolchain stamps the deployment target there
# unless -platform_version names the SDK explicitly. The minimum is read from
# Package.swift so the deployment target is stated once.
MACOS_MIN="$(sed -n -e 's/.*\.macOS(\.v\([0-9][0-9]*\)).*/\1.0/p' -e 's/.*\.macOS("\([0-9][0-9.]*\)").*/\1/p' Package.swift | head -1)"
MACOS_SDK="$(xcrun --sdk macosx --show-sdk-version)"
test -n "$MACOS_MIN" || { echo "build-app: no macOS deployment target in Package.swift" >&2; exit 1; }
test -n "$MACOS_SDK" || { echo "build-app: xcrun could not report the macOS SDK version" >&2; exit 1; }
LINK_FLAGS=(-Xlinker -platform_version -Xlinker macos -Xlinker "$MACOS_MIN" -Xlinker "$MACOS_SDK")
swift build --disable-sandbox -c release -Xswiftc -warnings-as-errors "${LINK_FLAGS[@]}"
BIN="$(swift build --disable-sandbox -c release --show-bin-path)"
python3 scripts/verify-release.py --linked-sdk "$BIN/SpiceClient" --sdk "$MACOS_SDK"
APP="$ROOT/dist/Spice Client.app"
rm -rf "$APP"
rm -f "$APP.notarized"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Licenses"
cp "$BIN/SpiceClient" "$APP/Contents/MacOS/SpiceClient"
sed "s/\${VERSION}/${VERSION}/g" Resources/Info.plist > "$APP/Contents/Info.plist"
if grep -q '${VERSION}' "$APP/Contents/Info.plist"; then echo "build-app: version placeholder not substituted" >&2; exit 1; fi
plutil -lint -s "$APP/Contents/Info.plist"
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
reported="$("$APP/Contents/MacOS/SpiceClient" --version)"
test "$reported" = "Spice Client $VERSION" || { echo "build-app: --version reported '$reported', expected 'Spice Client $VERSION'" >&2; exit 1; }
echo "Built local verification application: $APP ($VERSION, linked against macOS SDK $MACOS_SDK)"
