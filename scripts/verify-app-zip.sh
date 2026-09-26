#!/usr/bin/env bash
# verify-app-zip.sh <release zip> — refuse a GUI release zip that is not fit to ship.
#
# Vendored verbatim into every GUI repository's scripts/ and called from its
# `verify-release` recipe (check-org checks 10 and 18). It reads the zip users
# download, not the local bundle: what is judged is what ships.
#
# Two things, each of which passed every other gate while wrong:
#
# - macOS metadata. `ditto -c -k` without --norsrc --noextattr writes each
#   file's extended attributes into the zip as "._" AppleDouble entries. Unpacked
#   with a plain `unzip`, they land inside the .app as files, and codesign and
#   Gatekeeper then refuse the bundle ("a sealed resource is missing or
#   invalid"). Finder, ditto and Homebrew merge them back, so nothing noticed:
#   18 of 19 GUI releases carried them (measured 2026-09-27).
# - The app icon. Signing and notarization pass without one, and a menu-bar app
#   never shows in the Dock: m5-system-panel v0.1.0 shipped without one.
#
# Passes only when the zip has no entry named "._*" at any depth and nothing
# under "__MACOSX/", and holds exactly one top-level .app whose Info.plist names
# a CFBundleIconFile, and <app>/Contents/Resources/<that file> (".icns" added
# when the name has no extension) is an entry of the zip — compared as a whole
# entry name — whose first four bytes are the icns magic.
set -euo pipefail

fail() { echo "verify-release: FAIL — $*" >&2; exit 1; }

zip="${1:?usage: verify-app-zip.sh <release zip>}"
[ -f "$zip" ] || fail "release zip missing: $zip"

names=$(unzip -Z1 "$zip") || fail "cannot list $zip"

# macOS metadata entries: "._name" at any depth, or anything under __MACOSX/.
meta=$(awk -F/ '$NF ~ /^\._/ || $1 == "__MACOSX" { print }' <<<"$names")
if [ -n "$meta" ]; then
  n=$(printf '%s\n' "$meta" | awk 'END { print NR }')
  first=$(awk 'NR == 1' <<<"$meta")
  fail "$zip carries $n macOS metadata entries (first: $first) — zip with ditto --norsrc --noextattr"
fi

# Top-level .app directories, one per line (names may contain spaces).
apps=$(awk -F/ 'NF > 1 && $1 ~ /\.app$/ && !seen[$1]++ { print $1 }' <<<"$names")
count=$(printf '%s' "$apps" | awk 'END { print NR }')
[ "$count" -eq 1 ] || fail "$zip holds $count top-level .app bundles, expected 1"
app="$apps"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

unzip -q "$zip" "$app/Contents/Info.plist" -d "$work" 2>/dev/null ||
  fail "$app has no Contents/Info.plist in $zip"
icon=$(plutil -extract CFBundleIconFile raw -o - "$work/$app/Contents/Info.plist" 2>/dev/null) || icon=""
[ -n "$icon" ] || fail "$app's Info.plist names no CFBundleIconFile"
case "$icon" in
  *.*) ;;
  *) icon="$icon.icns" ;;
esac

entry="$app/Contents/Resources/$icon"
# A here-string, not `printf | grep -q`: grep -q exits at the first match, and
# under pipefail the writer's SIGPIPE would turn that match into a failure.
grep -xF "$entry" <<<"$names" >/dev/null || fail "$zip has no $entry"

unzip -q "$zip" "$entry" -d "$work" 2>/dev/null || fail "cannot extract $entry"
magic=$(head -c 4 "$work/$entry")
[ "$magic" = "icns" ] || fail "$entry is not an icns file"

echo "verify-app-zip: OK (no macOS metadata; icon $entry)"
