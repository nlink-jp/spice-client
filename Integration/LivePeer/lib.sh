# Shared functions for the live peer gate (ADR-0002). The three checks take
# files in and return an exit status, so Tests/test_live_peer.py can drive them.

# $1 = guest log. The A key down event as the guest's `od -An -tx1` prints it
# (arm64 input_event: type 01 00, code 1e 00, value 01 00 00 00).
live_peer_guest_saw_key() {
    grep -c '01 00 1e 00 01 00 00 00' "$1" > /dev/null
}

# $1 = receipt written by LivePeerTests; the rest = test names that must appear.
live_peer_tests_ran() {
    local receipt="$1" name
    shift
    test -s "$receipt" || return 1
    for name in "$@"; do
        grep -c "^${name}\$" "$receipt" > /dev/null || return 1
    done
}

# $1 = last-pass.json; $2 = expected git HEAD. A pass counts only when it was
# recorded on exactly that commit with a clean tree.
live_peer_pass_matches() {
    test -s "$1" || return 1
    python3 - "$1" "$2" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
ok = data.get("passed") is True and data.get("dirty") is False and data.get("head") == sys.argv[2]
sys.exit(0 if ok else 1)
PY
}

# $1 = image, $2 = Containerfile, $3 = output json. Records what the image
# actually contains: apt versions float, so they are recorded, not pinned.
live_peer_describe_image() {
    local image="$1" containerfile="$2" out="$3" base packages image_id
    base="$(sed -n 's/^FROM \(.*\)$/\1/p' "$containerfile" | head -n 1)"
    packages="$(podman run --rm "$image" dpkg-query -W -f '${Package}=${Version} ' qemu-system-arm qemu-system-modules-spice libspice-server1)"
    image_id="$(podman image inspect --format '{{.Id}}' "$image")"
    printf '{"image": "%s", "image_id": "%s", "base_image": "%s", "packages": "%s", "built": "%s"}\n' \
        "$image" "$image_id" "$base" "${packages% }" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$out"
}
