#!/bin/bash
# Prove that Vendor/*.patch really is the whole local change to the vendored
# dependency: fetch the pinned upstream files, apply the patches in the order
# Vendor/UPSTREAM.json lists them, and require the result to equal what is
# checked in.
#
# check-project.py already pins every vendored file and every patch by hash, so
# it catches an edit that nobody recorded. What it cannot see is whether the
# patches explain that edit — a patch can rot into a description of a change
# that is no longer the change. This does need the network, which is why it is
# its own target rather than part of `make test`.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/spice-client-vendor-patches.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT INT TERM

URL="$(python3 -c "import json;print(json.load(open('$ROOT/Vendor/UPSTREAM.json'))['url'])")"
COMMIT="$(python3 -c "import json;print(json.load(open('$ROOT/Vendor/UPSTREAM.json'))['commit'])")"
RAW="${URL%.git}"
RAW="https://raw.githubusercontent.com/${RAW#https://github.com/}/$COMMIT"

# The patches name the files they touch, so a new patch needs no change here.
# A hunk against /dev/null creates the file, so there is nothing to fetch.
python3 - "$ROOT" "$WORK" <<'PY'
import json, pathlib, re, sys
root, work = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
order = [p["file"] for p in json.loads((root / "Vendor/UPSTREAM.json").read_text())["patches"]]
existing, created = [], []
for name in order:
    lines = (root / "Vendor" / name).read_text().splitlines()
    for index, line in enumerate(lines):
        match = re.fullmatch(r"diff --git a/(\S+) b/\1", line)
        if not match:
            continue
        target = created if lines[index + 1] == "--- /dev/null" else existing
        if match.group(1) not in target:
            target.append(match.group(1))
(work / "order").write_text("\n".join(order) + "\n")
(work / "fetch").write_text("\n".join(existing) + "\n" if existing else "")
(work / "created").write_text("\n".join(created) + "\n" if created else "")
PY

# Start from the checked-in sources, then put back the pristine upstream copy of
# every file a patch touches. Files no patch touches are pinned by hash in
# check-project.py, so copying them is not the claim under test here.
mkdir -p "$WORK/tree"
( cd "$ROOT/Vendor/SwiftSpice" && tar cf - Sources Tests ) | ( cd "$WORK/tree" && tar xf - )

while read -r path; do
    [ -n "$path" ] || continue
    mkdir -p "$WORK/tree/$(dirname "$path")"
    curl --fail --silent --show-error --location "$RAW/$path" --output "$WORK/tree/$path"
    echo "fetched $path"
done < "$WORK/fetch"

while read -r path; do
    [ -n "$path" ] || continue
    rm -f "$WORK/tree/$path"
done < "$WORK/created"

while read -r name; do
    [ -n "$name" ] || continue
    echo "applying $name"
    ( cd "$WORK/tree" && patch --silent -p1 < "$ROOT/Vendor/$name" )
done < "$WORK/order"

diff -r "$WORK/tree/Sources" "$ROOT/Vendor/SwiftSpice/Sources"
diff -r "$WORK/tree/Tests" "$ROOT/Vendor/SwiftSpice/Tests"
echo "verify-vendor-patches: the patches reproduce the vendored sources at $COMMIT"
