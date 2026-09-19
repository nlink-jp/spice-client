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

# $1 = guest log. Requires X to have taken the guest's input devices. The key
# test observes evdev directly, which is one layer below X: it has always passed
# while Xorg ran with zero input devices and no X client could see a keystroke
# (measured 2026-09-18, found by looking at a terminal in the guest, not by the
# gate). Xorg enumerates input only through udev, so this fails closed when the
# guest's udevd or its input driver goes missing.
live_peer_guest_x_has_input() {
    local count
    count="$(sed -n 's/^GUEST xorg input devices: \([0-9][0-9]*\)$/\1/p' "$1" | tail -n 1)"
    test -n "$count" || { echo "live-peer: the guest never reported how many input devices Xorg took" >&2; return 1; }
    test "$count" -ge 2 || { echo "live-peer: Xorg took $count input devices; the keyboard and mouse should both be there" >&2; return 1; }
}

# $1 = guest log. An X client must have received the key the transport test
# injects: keysym 0x61, the letter a. live_peer_guest_saw_key proves the key
# reached the guest kernel, which it did throughout the period when Xorg had no
# input devices and nothing in the guest could be typed into (2026-09-18). This
# is the same key one layer up, where a person would notice it.
live_peer_guest_saw_x_key() {
    grep -c '^XKEY_PRESS keycode=[0-9][0-9]* keysym=0x61$' "$1" > /dev/null \
        || { echo "live-peer: no X client in the guest received the injected a key (keysym 0x61)" >&2; return 1; }
}

# $1 = attempt limit, $2... = the command that starts a peer. podman asks the
# kernel for a free ephemeral loopback port and binds it a moment later, and
# nothing reserves it in between, so another process — often the previous
# phase's peer releasing its own ports — can take it first (seen once in three
# consecutive gate runs, in phase 2 right after phase 1 stopped). No podman
# option holds a port, so a bounded retry with a fresh allocation is the fix
# rather than a workaround. Every other failure passes straight through with its
# status and message, because retrying a real failure only hides it.
live_peer_start_with_retry() {
    local attempts="$1" attempt=1 error status
    shift
    while true; do
        # $? must be read inside the else: after a whole `if` with no taken
        # branch it is the `if` statement's own status, which is always 0.
        if error="$("$@" 2>&1)"; then
            return 0
        else
            status=$?
        fi
        case "$error" in
            *"address already in use"*)
                if [ "$attempt" -ge "$attempts" ]; then
                    echo "live-peer: no free loopback port after $attempts attempts: $error" >&2
                    return 1
                fi
                echo "live-peer: loopback port taken between allocation and bind; retrying ($attempt of $attempts)" >&2
                attempt=$((attempt + 1))
                sleep "${SPICE_CLIENT_LIVE_PEER_RETRY_DELAY:-1}"
                ;;
            *)
                echo "$error" >&2
                return "$status"
                ;;
        esac
    done
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

# $1 = output directory. Per-run X.509 material for the TLS listener (phase 1b):
# a CA, a server certificate it signed (subject O=nlink-jp,CN=spice-client-live-peer,
# SAN 127.0.0.1/localhost), a decoy CA that signed nothing, and subject.txt in
# the form SwiftSpice's host-subject comparison expects. Keys are 0600.
live_peer_make_x509() {
    local dir="$1"
    mkdir -p "$dir"
    chmod 700 "$dir"
    cat > "$dir/openssl.cnf" <<'CNF'
[req]
distinguished_name = dn
prompt = no
[dn]
O = nlink-jp
CN = spice-client-live-peer
[ca_ext]
basicConstraints = critical, CA:TRUE
keyUsage = critical, keyCertSign, cRLSign
CNF
    cat > "$dir/server-ext.cnf" <<'CNF'
basicConstraints = CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = IP:127.0.0.1, DNS:localhost
CNF
    (
        umask 077
        openssl req -x509 -newkey rsa:2048 -nodes -days 2 -config "$dir/openssl.cnf" -extensions ca_ext \
            -subj "/O=nlink-jp/CN=spice-client-live-peer-ca" -keyout "$dir/ca-key.pem" -out "$dir/ca-cert.pem" 2> /dev/null
        openssl req -x509 -newkey rsa:2048 -nodes -days 2 -config "$dir/openssl.cnf" -extensions ca_ext \
            -subj "/O=nlink-jp/CN=spice-client-live-peer-decoy-ca" -keyout "$dir/decoy-ca-key.pem" -out "$dir/decoy-ca-cert.pem" 2> /dev/null
        openssl req -new -newkey rsa:2048 -nodes -config "$dir/openssl.cnf" \
            -subj "/O=nlink-jp/CN=spice-client-live-peer" -keyout "$dir/server-key.pem" -out "$dir/server.csr" 2> /dev/null
        openssl x509 -req -in "$dir/server.csr" -CA "$dir/ca-cert.pem" -CAkey "$dir/ca-key.pem" -CAcreateserial \
            -days 2 -extfile "$dir/server-ext.cnf" -out "$dir/server-cert.pem" 2> /dev/null
    )
    printf 'O=nlink-jp,CN=spice-client-live-peer' > "$dir/subject.txt"
    local name
    for name in ca-cert.pem server-cert.pem server-key.pem decoy-ca-cert.pem subject.txt; do
        test -s "$dir/$name" || return 1
    done
}

# $1 = directory made by live_peer_make_x509. Removes exactly those files.
live_peer_remove_x509() {
    local name
    for name in openssl.cnf server-ext.cnf ca-key.pem ca-cert.pem ca-cert.srl decoy-ca-key.pem decoy-ca-cert.pem \
                server-key.pem server.csr server-cert.pem subject.txt; do
        rm -f "$1/$name"
    done
    rmdir "$1" 2> /dev/null || true
}

# $1 = guest log. Exit 0 once the agent stack started, 2 if it reported an
# error, 1 while neither has happened.
live_peer_agent_status() {
    grep -c '^AGENT_STACK_STARTED\r*$' "$1" > /dev/null 2>&1 && return 0
    grep -c '^AGENT_ERROR ' "$1" > /dev/null 2>&1 && return 2
    return 1
}

# $1 = guest log. The guest must have actually played, so a passing audio test
# cannot rest on a silent path that never started.
live_peer_guest_audio_started() {
    grep -c '^AUDIO_PLAYING\r*$' "$1" > /dev/null
}

# $1 = receipt written by LiveAgentTests, $2 = guest log. Walks the receipt in
# order: a `delivered <token>` line must be followed, later in the log than the
# previous match, by the guest observing that host text's SHA-256; a `withheld
# <token>` must never appear anywhere; a `mode WxH` must be applied by Xorg
# after the previous match, so a startup mode line cannot satisfy a later
# request. Lines of any other shape are ignored.
live_peer_agent_log_matches() {
    python3 - "$1" "$2" <<'PY'
import hashlib, sys
receipt = open(sys.argv[1]).read().splitlines()
log = [line.rstrip("\r") for line in open(sys.argv[2]).read().splitlines()]
def sha(token):
    return hashlib.sha256(f"spice-client host clipboard {token}".encode()).hexdigest()
def find(predicate, start):
    for index in range(start, len(log)):
        if predicate(log[index]):
            return index
    return -1
cursor = 0
for line in receipt:
    parts = line.split()
    if len(parts) == 3 and parts[0] == "file":
        # file <name> <sha256>: the guest must hold those exact bytes. Searched over
        # the whole log and the cursor is left alone: the name carries a per-run
        # UUID, so there is nothing to disambiguate by position, and the guest
        # reports a file only once its writes have settled, which is seconds after
        # the host saw the transfer complete and therefore out of order with the
        # markers around it.
        _, name, digest = parts
        if not any(l.startswith("FILE_TRANSFER_RECEIVED ") and f"name={name} " in l
                   and l.endswith("sha256=" + digest) for l in log):
            sys.exit(f"live-peer: the guest did not report {name} with sha256 {digest}")
        continue
    if len(parts) != 2:
        continue
    kind, token = parts
    if kind == "delivered":
        digest = sha(token)
        index = find(lambda l: l.startswith("CLIPBOARD_OBSERVED ") and l.endswith("sha256=" + digest), cursor)
        if index < 0:
            sys.exit(f"live-peer: delivered token {token} was not observed by the guest after log line {cursor}")
        cursor = index + 1
    elif kind == "withheld":
        digest = sha(token)
        if any(l.endswith("sha256=" + digest) for l in log):
            sys.exit(f"live-peer: withheld token {token} reached the guest")
    elif kind == "mode":
        index = find(lambda l: l == f"XRANDR_MODE {token}", cursor)
        if index < 0:
            sys.exit(f"live-peer: Xorg did not apply mode {token} after log line {cursor}")
        cursor = index + 1
    elif kind == "unapplied":
        # A defect pinned as a fact: the mode must NOT arrive, so that the gate
        # turns red the day the defect is fixed and the records must be updated.
        index = find(lambda l: l == f"XRANDR_MODE {token}", cursor)
        if index >= 0:
            sys.exit(f"live-peer: mode {token} was applied after log line {cursor}; "
                     "the second-resize defect recorded in ADR-0003 looks fixed — "
                     "update LiveAgentTests and the verification record")
PY
}

# $1 = artifacts directory, $2 = guest source directory. Exit 0 when guest.json
# records the current init and build script, so a changed guest is rebuilt.
live_peer_guest_current() {
    test -s "$1/guest.json" || return 1
    python3 - "$1/guest.json" "$(shasum -a 256 "$2/init" | cut -d' ' -f1)" "$(shasum -a 256 "$2/build-in-container.sh" | cut -d' ' -f1)" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
sys.exit(0 if data.get("init_sha256") == sys.argv[2] and data.get("build_sha256") == sys.argv[3] else 1)
PY
}
