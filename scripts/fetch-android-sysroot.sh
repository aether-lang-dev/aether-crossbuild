#!/bin/sh
# fetch-android-sysroot.sh — populate a lean Android (bionic) sysroot under
# ./bases/<cpu>-android<api>/, needed because zig cc names the Android target
# but ships no bionic. With it, `ae build --target=aarch64-linux-android`
# cross-builds with zig alone: no NDK compiler, no 2 GB NDK on disk.
#
#   ./scripts/fetch-android-sysroot.sh aarch64          # API 29 (Android 10)
#   ./scripts/fetch-android-sysroot.sh aarch64 33       # a higher minimum API
#   ./scripts/fetch-android-sysroot.sh x86_64 29        # the emulator ABI
#
# Source: the Android NDK zip pinned in deps.lock (android-ndk), verified by
# sha256, cached in work/downloads. Only the sysroot slice is extracted:
#   usr/include                              bionic + kernel UAPI + NDK headers
#   usr/lib/<cpu>-linux-android/<api>/       crt*.o and the libc/libm/libdl/...
#                                            stubs a binary links against
#   usr/lib/<cpu>-linux-android/*.a          libc.a, libm.a, libc++, libz, ...
#                                            (static links)
# plus the NDK's NOTICE files, which carry the licences of all of it: bionic is
# BSD/Apache-2.0 (from AOSP), libc++ Apache-2.0 with the LLVM exception, zlib
# the zlib licence, and the kernel headers are bionic's generated, cleaned
# copies. The sysroot is the same on every NDK host, so the Linux zip serves
# macOS and Linux alike (the script only reads files, it runs nothing in it).
# About 30 MB per <cpu, api>; git-ignored like bases/ for FreeBSD.

set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cpu=${1:-}
case "$cpu" in
    aarch64|arm64) cpu=aarch64 ;;
    x86_64|amd64) cpu=x86_64 ;;
    *) echo "usage: $0 <aarch64|x86_64> [api, default 29]" >&2; exit 2 ;;
esac
api=${2:-29}
case "$api" in *[!0-9]*|'') echo "api must be a number, e.g. 29" >&2; exit 2 ;; esac

key=android-ndk
line=$(grep -E "^$key[[:space:]]" "$ROOT/deps.lock") || { echo "no $key entry in deps.lock" >&2; exit 1; }
ver=$(echo "$line" | awk '{print $2}')
url=$(echo "$line" | awk '{print $3}')
sha=$(echo "$line" | awk '{print $4}')

DL="$ROOT/work/downloads"; mkdir -p "$DL"
zip="$DL/$(basename "$url")"
if [ ! -f "$zip" ]; then
    echo "fetch Android NDK $ver <- $url (about 650 MB, once)" >&2
    curl -fsSL "$url" -o "$zip.part" && mv "$zip.part" "$zip"
fi
if [ "$sha" != "PIN_ME" ]; then
    if command -v sha256sum >/dev/null 2>&1; then got=$(sha256sum "$zip" | awk '{print $1}')
    else got=$(shasum -a 256 "$zip" | awk '{print $1}'); fi
    [ "$got" = "$sha" ] || { echo "NDK checksum mismatch: $got != $sha" >&2; exit 1; }
fi

base="$ROOT/bases/$cpu-android$api"
top="android-ndk-$ver"
sr="$top/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
lib="usr/lib/$cpu-linux-android"
stage="$ROOT/work/android-extract"
rm -rf "$stage" "$base"; mkdir -p "$stage" "$base"

echo "extract the $cpu API $api sysroot -> $base" >&2
# The members wanted, as path prefixes inside the zip.
want="$sr/usr/include/
$sr/$lib/$api/
$top/NOTICE
$top/NOTICE.toolchain
$top/source.properties"
python3 - "$zip" "$stage" "$sr/$lib/" "$want" <<'PY'
import os, sys, zipfile
zpath, stage, libdir, want = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4].split("\n")
z = zipfile.ZipFile(zpath)
n = 0
for i in z.infolist():
    name = i.filename
    keep = any(name.startswith(w) for w in want)
    # the static archives that sit directly in usr/lib/<cpu>-linux-android/
    if not keep and name.startswith(libdir) and name.endswith(".a") and "/" not in name[len(libdir):]:
        keep = True
    if not keep or name.endswith("/"):
        continue
    p = z.extract(i, stage)
    mode = (i.external_attr >> 16) & 0o777
    if mode:
        os.chmod(p, mode)
    n += 1
print(f"{n} files", file=sys.stderr)
PY
[ -f "$stage/$sr/$lib/$api/libc.so" ] || {
    echo "the NDK has no $cpu API $api sysroot (no $lib/$api/libc.so); try another API level" >&2
    rm -rf "$base"; exit 1; }
mkdir -p "$base/usr/lib"
mv "$stage/$sr/usr/include" "$base/usr/include"
mv "$stage/$sr/$lib" "$base/usr/lib/$cpu-linux-android"
mv "$stage/$top/NOTICE" "$base/NOTICE.android-ndk"
mv "$stage/$top/NOTICE.toolchain" "$base/NOTICE.android-ndk-toolchain"
mv "$stage/$top/source.properties" "$base/source.properties"
rm -rf "$stage"

echo "Android sysroot ready: $base ($(du -sh "$base" | awk '{print $1}'))" >&2
echo "now: AETHER_SYSROOT=$base ae build --target=$cpu-linux-android app.ae" >&2
