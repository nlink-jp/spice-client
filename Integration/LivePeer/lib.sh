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
