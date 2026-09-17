#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
test "$(uname -m)" = arm64
xcrun swift --version
WORK="$(mktemp -d "${TMPDIR:-/tmp}/spice-client-metal.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
printf '#include <metal_stdlib>\nusing namespace metal;\nkernel void probe(device uint *out [[buffer(0)]]) { out[0] = 1; }\n' > "$WORK/probe.metal"
sh Vendor/SwiftSpice/Plugins/CompileMetalShaders/compile-metal.sh "$WORK/probe.metal" "$WORK/probe.air" "$WORK/probe.metallib"
test -s "$WORK/probe.metallib"
echo 'Metal compilation verified.'
