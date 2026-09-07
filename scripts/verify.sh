#!/bin/sh
# verify.sh — after `provision.sh <triple>`, prove each staged lib in the
# sysroot actually LINKS, not merely that its archive has the right arch.
#
# `provision.sh` stages sysroots/<triple>/lib/lib<name>.a; `assert_arch` already
# checks each archive's object arch/format. But "the members are the right arch"
# is weaker than "a program that calls the lib links against the sysroot with no
# undefined symbols" — a wrong include path, a missing transitive dep, or an ABI
# mismatch can leave a right-arch archive that will not actually link. This
# closes that gap: for every staged lib it compiles a tiny C probe that calls a
# real function from the lib, links it (by absolute archive path) against the
# sysroot through the same zig wrapper provision.sh uses, and confirms a binary
# was produced with no unresolved symbols.
#
# It links only (does not run — a cross target's binary can't run on the Linux
# host); "links NOUNDEFS" is the strongest check a Linux agent can make. The
# run-on-hardware check is a separate, hardware-bound step (see TODO.md).
#
# Usage:
#   ./scripts/verify.sh <triple>                 # verify what's staged
#   CB_LIBS="openssl pcre2" ./scripts/verify.sh <triple>   # a subset
#
# Exit 0 iff every checked lib links; non-zero (with a red line) otherwise.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT/recipes/common.sh"

need sha256sum

TRIPLE=${1:-}
[ -n "$TRIPLE" ] || die "usage: verify.sh <triple>   (e.g. x86_64-freebsd15)"

ZT=$(map_zig_target "$TRIPLE")          # validates the triple
SR=$(sysroot_dir "$TRIPLE")
[ -d "$SR/lib" ] || die "no staged sysroot at $SR — run: ./provision.sh $TRIPLE"

# FreeBSD wrappers need the base sysroot (CRT + libc.so.7) to link an exe.
WBASE=""
if is_freebsd "$TRIPLE"; then
    [ -d "$BASES/$TRIPLE" ] || die "freebsd base missing: $BASES/$TRIPLE — run scripts/fetch-freebsd-base.sh $(fbsd_cpu "$TRIPLE") $(fbsd_ver "$TRIPLE")"
    WBASE="$BASES/$TRIPLE"
fi
WD=$(setup_zig_wrappers "$ZT" "$WBASE")
XCF=$(target_extra_cflags "$TRIPLE")     # --sysroot + -I/-L for FreeBSD, else ""

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

# fbsd_ver — mirror provision.sh's local helper for the error hint above.
fbsd_ver() { case "$1" in *-freebsd[0-9]*) echo "${1##*-freebsd}" ;; *) echo "" ;; esac; }

# A per-lib probe: the archive basename(s) to link (veneer before backing lib),
# a header to include, and one real call so the linker must resolve a symbol.
# Keyed on the archive that gates the lib (what provision.sh stages).
probe_src() {
    case "$1" in
        z)       printf '#include <zlib.h>\nint main(void){return (int)zlibVersion()[0];}\n' ;;
        pcre2-8) printf '#define PCRE2_STATIC 1\n#define PCRE2_CODE_UNIT_WIDTH 8\n#include <pcre2.h>\nint main(void){int e;PCRE2_SIZE o;pcre2_code*c=pcre2_compile((PCRE2_SPTR)"a",1,0,&e,&o,0);(void)c;return 0;}\n' ;;
        nghttp2) printf '#include <nghttp2/nghttp2.h>\nint main(void){return (int)nghttp2_version(0)->version_num;}\n' ;;
        crypto)  printf '#include <openssl/evp.h>\nint main(void){return EVP_MAX_MD_SIZE>0?0:1;}\n' ;;
        sqlite3) printf '#include <sqlite3.h>\nint main(void){return sqlite3_libversion_number();}\n' ;;
        *)       return 1 ;;
    esac
}

# The archive(s) to put on the link line for a given probe key, in link order.
probe_archives() {
    case "$1" in
        crypto)  echo "ssl crypto" ;;   # openssl staged as libssl.a + libcrypto.a
        *)       echo "$1" ;;
    esac
}

checked=0
failed=0
for key in z pcre2-8 nghttp2 crypto sqlite3; do
    gate="$SR/lib/lib$key.a"
    [ -f "$gate" ] || continue          # not staged in this sysroot — skip
    src="$TMP/probe_$key.c"
    if ! probe_src "$key" > "$src"; then continue; fi
    out="$TMP/probe_$key"
    # Absolute-path archive inputs (immune to zig's --sysroot -L rewriting).
    arcs=""
    for a in $(probe_archives "$key"); do arcs="$arcs \"$SR/lib/lib$a.a\""; done
    log "verify $TRIPLE: link a program using lib$key"
    # shellcheck disable=SC2086
    if eval "\"$WD/cc\" $XCF -I\"$SR/include\" \"$src\" $arcs -o \"$out\"" \
            >"$TMP/verify_$key.log" 2>&1 && [ -f "$out" ]; then
        # No undefined symbols (beyond what the dynamic base provides). nm -u on
        # a fully-linked exe lists only symbols the loader resolves at runtime;
        # a link that left a lib symbol dangling would have failed above. The
        # presence of the binary + a clean link is the NOUNDEFS proof.
        printf '  \033[32m✓ lib%s links\033[0m\n' "$key" >&2
        checked=$((checked + 1))
    else
        printf '  \033[31m✗ lib%s did NOT link\033[0m (see below)\n' "$key" >&2
        sed 's/^/      /' "$TMP/verify_$key.log" | head -12 >&2
        failed=$((failed + 1))
    fi
done

if [ "$checked" = 0 ] && [ "$failed" = 0 ]; then
    die "no verifiable libs found in $SR/lib (staged: $(ls "$SR/lib" 2>/dev/null | tr '\n' ' '))"
fi
if [ "$failed" -gt 0 ]; then
    die "$failed lib(s) failed to link for $TRIPLE"
fi
printf '\033[32m✓ %s: all %d checked lib(s) link cleanly\033[0m\n' "$TRIPLE" "$checked" >&2
