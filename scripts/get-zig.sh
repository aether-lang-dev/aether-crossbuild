#!/bin/sh
# get-zig.sh — fetch the pinned zig toolchain into ./toolchain/.
# zig is a self-contained cross-compiler (compiler + target libcs + macOS SDK
# stubs) — this is the only toolchain the cross-build needs. No system install.

set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TOOLCHAIN="$ROOT/toolchain"
mkdir -p "$TOOLCHAIN"

url=$(grep -E '^zig[[:space:]]' "$ROOT/deps.lock" | awk '{print $3}')
sha=$(grep -E '^zig[[:space:]]' "$ROOT/deps.lock" | awk '{print $4}')
[ -n "$url" ] || { echo "no zig entry in deps.lock" >&2; exit 1; }

tar="$TOOLCHAIN/$(basename "$url")"
if [ ! -f "$tar" ]; then
    echo "fetch zig <- $url" >&2
    curl -fsSL "$url" -o "$tar"
fi
if [ "$sha" != "PIN_ME" ]; then
    got=$(sha256sum "$tar" | awk '{print $1}')
    [ "$got" = "$sha" ] || { echo "zig checksum mismatch: $got != $sha" >&2; exit 1; }
else
    echo "WARNING: zig sha is PIN_ME — skipping checksum (run scripts/pin-hashes.sh)" >&2
fi

# extract (idempotent): produces toolchain/zig-<arch>-<os>-<ver>/zig (zig 0.16+ naming; older zig was <os>-<arch>)
tar xf "$tar" -C "$TOOLCHAIN"
z=$(find "$TOOLCHAIN" -maxdepth 2 -name zig -type f | head -1)
[ -n "$z" ] || { echo "zig binary not found after extract" >&2; exit 1; }
echo "zig ready: $z" >&2
"$z" version >&2

# NOTE: the pinned tarball is linux-x86_64. If you run the cross-build on a
# different HOST (arm64 Linux, macOS), swap the zig URL in deps.lock for that
# host's build — zig's *host* arch must match the machine running provision.sh;
# the *target* is chosen per build and is independent of it.
