#!/bin/sh
# common.sh — shared helpers for the cross-build recipes.
# Sourced by provision.sh and each recipes/<lib>.sh. POSIX sh.
#
# Provides:
#   ROOT / WORK / SYSROOTS / BASES / TOOLCHAIN   directory globals
#   ZIG                                          path to the pinned zig binary
#   setup_zig_wrappers <triple>                  makes cc/ar/ranlib/etc for a target
#   map_autoconf_host <triple>                   -> aarch64-apple-darwin, etc.
#   map_openssl_target <triple>                  -> darwin64-arm64-cc, etc.
#   lock_field <name> <col>                      read deps.lock (col: version|url|sha)
#   fetch_verify <name>                          download+checksum+extract; echoes srcdir
#   stage_lib <triple> <libfile>...              copy .a into sysroots/<triple>/lib
#   stage_headers <triple> <dir-or-file>...      copy headers into .../include
#   stage_license <triple> <lib> <file>...       copy LICENSE/NOTICE into .../licenses/<lib>
#   die <msg> / log <msg> / need <cmd>

set -eu

# --- directories (ROOT is the repo root; recipes are one level down) ----------
# A caller that already knows the repo root (e.g. scripts/verify.sh, one level
# down like recipes/) can export ROOT before sourcing this file; honour it.
# Otherwise derive from $0: provision.sh sits at ROOT, a recipe in recipes/.
if [ -z "${ROOT:-}" ]; then
    _here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
    case "$_here" in
        */recipes) ROOT=$(dirname -- "$_here") ;;
        *)         ROOT="$_here" ;;
    esac
fi
export ROOT
WORK="$ROOT/work"
SYSROOTS="$ROOT/sysroots"
BASES="$ROOT/bases"
TOOLCHAIN="$ROOT/toolchain"
DL="$WORK/downloads"
mkdir -p "$WORK" "$SYSROOTS" "$BASES" "$DL"

# --- logging ------------------------------------------------------------------
log() { printf '  \033[36m▸\033[0m %s\n' "$*" >&2; }
die() { printf '  \033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "required tool not found: $1"; }

# --- zig toolchain ------------------------------------------------------------
# Find the pinned zig extracted under toolchain/ (scripts/get-zig.sh puts it there).
find_zig() {
    if [ -n "${ZIG:-}" ] && [ -x "${ZIG:-}" ]; then echo "$ZIG"; return; fi
    z=$(find -L "$TOOLCHAIN" -maxdepth 2 -name zig -type f 2>/dev/null | head -1 || true)
    [ -n "$z" ] || die "zig not found under $TOOLCHAIN — run ./scripts/get-zig.sh first"
    echo "$z"
}
ZIG=$(find_zig)
export ZIG

# Build cc/ar/ranlib wrapper scripts that pin `-target <triple>` for a target.
# openssl and autoconf both invoke $CC many times with their own flags; a sticky
# wrapper is more robust than exporting a multi-word $CC. Echoes the wrapper dir.
#
# Optional 2nd arg `<base>`: a FreeBSD base sysroot dir. When given, the cc/c++
# wrappers add the FreeBSD LINK recipe (-nostdlib + CRT objects + real libc.so.7)
# on LINK invocations only — i.e. when `-c` is absent. This is what makes a
# configure "can the C compiler create executables?" probe (and any exe link)
# succeed: zig cc can't supply a FreeBSD libc, and the base's usr/lib/libc.so is
# a GROUP linker script naming absolute /lib paths that don't exist on the build
# host, so we point at the versioned /lib/libc.so.7 directly. Mirrors tools/ae.c's
# fbsd_link (#1216). On a compile (`-c`) the link flags are omitted (crt objects
# passed to a compile-only cc would error). No base -> unchanged (Tier A).
setup_zig_wrappers() {
    _triple=$1
    _base=${2:-}
    _wd="$WORK/wrappers/$_triple"
    mkdir -p "$_wd"
    # FreeBSD link tail (empty unless a base sysroot was supplied).
    _fbsd_link=""
    if [ -n "$_base" ]; then
        _fbsd_link="-nostdlib $_base/usr/lib/crt1.o $_base/usr/lib/crti.o $_base/lib/libc.so.7 $_base/usr/lib/crtn.o"
    fi
    # cc / c++: pin the target. On FreeBSD, add the link recipe when NOT compiling
    # (-c absent) so exe links + configure probes resolve libc/_start. AND treat
    # zig's cosmetic "error: libc not available" nonzero exit as success WHEN the
    # output file was actually written (ld.lld linked it fine; zig reserves that
    # message for targets it can't supply a libc for — which is why we bring our
    # own). Mirrors ae.c's "output exists == linked" (#1208). Without the exit
    # rescue, configure's exe probe fails on the exit code despite a valid binary.
    for _tool in cc c++; do
        cat > "$_wd/$_tool" <<EOF
#!/bin/sh
_link='$_fbsd_link'
# no FreeBSD base (Tier A) OR a compile-only invocation: plain passthrough.
if [ -z "\$_link" ]; then exec "$ZIG" $_tool -target $_triple "\$@"; fi
for a in "\$@"; do [ "\$a" = "-c" ] && exec "$ZIG" $_tool -target $_triple "\$@"; done
# link: capture -o <out> (default a.out — configure's probe omits -o), add the
# CRT recipe, rescue a written-output nonzero exit (zig's cosmetic "libc not
# available"). Run in the cwd so a.out lands where configure looks.
_out='a.out'; _p=0
for a in "\$@"; do
    if [ "\$_p" = 1 ]; then _out="\$a"; _p=0; continue; fi
    [ "\$a" = "-o" ] && _p=1
done
"$ZIG" $_tool -target $_triple "\$@" \$_link
_rc=\$?
[ "\$_rc" -ne 0 ] && [ -s "\$_out" ] && exit 0
exit "\$_rc"
EOF
    done
    # ar / ranlib / strip: zig provides llvm equivalents. ranlib on some upstreams
    # gets passed macOS-specific flags (e.g. -c) that llvm-ranlib rejects; swallow
    # unknown single-letter opts defensively.
    cat > "$_wd/ar" <<EOF
#!/bin/sh
exec "$ZIG" ar "\$@"
EOF
    cat > "$_wd/ranlib" <<EOF
#!/bin/sh
# drop leading macOS-style flags llvm-ranlib doesn't accept; keep the archive arg
for a in "\$@"; do
    case "\$a" in -*) shift; continue ;; *) break ;; esac
done
exec "$ZIG" ranlib "\$@"
EOF
    cat > "$_wd/strip" <<EOF
#!/bin/sh
exec "$ZIG" strip "\$@" 2>/dev/null || true
EOF
    chmod +x "$_wd"/cc "$_wd"/c++ "$_wd"/ar "$_wd"/ranlib "$_wd"/strip
    echo "$_wd"
}

# --- target-triple mappings ---------------------------------------------------
# Our canonical triples (as passed to provision.sh and, later, ae build --target):
#   x86_64-macos aarch64-macos
#   x86_64-linux-gnu aarch64-linux-gnu x86_64-linux-musl aarch64-linux-musl
#   x86_64-freebsd aarch64-freebsd

# The exact string zig's -target wants (mostly identical; macos gets -none abi
# so system libs resolve from the bundled SDK stubs).
map_zig_target() {
    case "$(fbsd_canon "$1")" in
        x86_64-macos)        echo "x86_64-macos-none" ;;
        aarch64-macos)       echo "aarch64-macos-none" ;;
        x86_64-linux-gnu)    echo "x86_64-linux-gnu" ;;
        aarch64-linux-gnu)   echo "aarch64-linux-gnu" ;;
        x86_64-linux-musl)   echo "x86_64-linux-musl" ;;
        aarch64-linux-musl)  echo "aarch64-linux-musl" ;;
        x86_64-freebsd)      echo "x86_64-freebsd" ;;
        aarch64-freebsd)     echo "aarch64-freebsd" ;;
        x86_64-windows)      echo "x86_64-windows-gnu" ;;
        aarch64-windows)     echo "aarch64-windows-gnu" ;;
        *) die "unknown target triple: $1" ;;
    esac
}

# The autoconf --host value (for zlib CHOST / pcre2+nghttp2 --host).
map_autoconf_host() {
    case "$(fbsd_canon "$1")" in
        x86_64-macos)        echo "x86_64-apple-darwin" ;;
        aarch64-macos)       echo "aarch64-apple-darwin" ;;
        x86_64-linux-gnu)    echo "x86_64-linux-gnu" ;;
        aarch64-linux-gnu)   echo "aarch64-linux-gnu" ;;
        x86_64-linux-musl)   echo "x86_64-linux-musl" ;;
        aarch64-linux-musl)  echo "aarch64-linux-musl" ;;
        x86_64-freebsd)      echo "x86_64-unknown-freebsd" ;;
        aarch64-freebsd)     echo "aarch64-unknown-freebsd" ;;
        x86_64-windows)      echo "x86_64-w64-mingw32" ;;
        aarch64-windows)     echo "aarch64-w64-mingw32" ;;
        *) die "no autoconf host for: $1" ;;
    esac
}

# openssl's ./Configure target name (openssl has its own naming scheme).
map_openssl_target() {
    case "$(fbsd_canon "$1")" in
        x86_64-macos)        echo "darwin64-x86_64-cc" ;;
        aarch64-macos)       echo "darwin64-arm64-cc" ;;
        x86_64-linux-gnu|x86_64-linux-musl)     echo "linux-x86_64" ;;
        aarch64-linux-gnu|aarch64-linux-musl)   echo "linux-aarch64" ;;
        x86_64-freebsd)      echo "BSD-x86_64" ;;
        aarch64-freebsd)     echo "BSD-aarch64" ;;
        x86_64-windows)      echo "mingw64" ;;
        aarch64-windows)     echo "mingw64" ;;
        *) die "no openssl target for: $1" ;;
    esac
}

# Is this a FreeBSD target (needs a base sysroot under bases/)?
is_freebsd() { case "$1" in *-freebsd|*-freebsd[0-9]*) return 0 ;; *) return 1 ;; esac; }

# Canonical (version-STRIPPED) triple for the zig/autoconf/openssl mappers, which
# name a target by OS not OS-version: x86_64-freebsd15 -> x86_64-freebsd. A triple
# with no version suffix passes through unchanged. (The version lives only in the
# base-sysroot dir; zig/autoconf don't take a FreeBSD version.)
fbsd_canon() {
    case "$1" in
        *-freebsd[0-9]*) echo "$1" | sed "s/[0-9]*$//" ;;  # strip trailing version
        *) echo "$1" ;;
    esac
}

# Extra CC flags a target needs (e.g. --sysroot for freebsd). Echoes flags or "".
target_extra_cflags() {
    _t=$1
    if is_freebsd "$_t"; then
        _b="$BASES/$_t"
        [ -d "$_b" ] || die "FreeBSD base sysroot missing: $_b — run scripts/fetch-freebsd-base.sh first"
        # NB: for a FreeBSD target, `--sysroot` ALONE does not make zig cc search
        # the sysroot's usr/include and usr/lib (unlike its bundled targets) — the
        # -I/-L must be explicit, or a source #include <sys/types.h> fails
        # "file not found". Same finding as tools/ae.c's run_cross_build (#1208).
        printf -- "--sysroot=%s -I%s/usr/include -L%s/usr/lib -L%s/lib" "$_b" "$_b" "$_b" "$_b"
    else
        printf ""
    fi
}

# Run ./configure with CC/AR/RANLIB from the wrapper dir, passing CFLAGS ONLY
# when non-empty. An empty `CFLAGS=` in the env corrupts some autoconf link
# probes (pcre2's in particular leaks the source-dir basename into $ac_link and
# reports "C compiler cannot create executables"). Usage:
#   run_configure <wrapperdir> <extra-cflags> <srcdir> -- <configure args...>
run_configure() {
    _wd=$1; _cf=$2; _src=$3; shift 3
    [ "$1" = "--" ] && shift
    # Defensive: autoconf reads LIBS/LDFLAGS/CPPFLAGS from the environment into
    # its link probe ($ac_link). The orchestrator's own selector used to be
    # named LIBS, which leaked a bare lib name into `cc conftest.c <name>` and
    # broke the compiler-works check. Clear the autoconf-magic vars so nothing
    # from our environment can contaminate a probe. (Selector is now CB_LIBS.)
    if [ -n "$_cf" ]; then
        ( cd "$_src" && unset LIBS LDFLAGS CPPFLAGS \
            && CC="$_wd/cc" AR="$_wd/ar" RANLIB="$_wd/ranlib" CFLAGS="$_cf" \
               ./configure "$@" )
    else
        ( cd "$_src" && unset LIBS LDFLAGS CPPFLAGS \
            && CC="$_wd/cc" AR="$_wd/ar" RANLIB="$_wd/ranlib" \
               ./configure "$@" )
    fi
}

# --- deps.lock access ---------------------------------------------------------
LOCK="$ROOT/deps.lock"
# lock_field <name> <version|url|sha>
lock_field() {
    _n=$1; _f=$2
    _line=$(grep -E "^$_n[[:space:]]" "$LOCK" | head -1) || true
    [ -n "$_line" ] || die "no deps.lock entry for '$_n'"
    # columns: name version url sha
    case "$_f" in
        version) echo "$_line" | awk '{print $2}' ;;
        url)     echo "$_line" | awk '{print $3}' ;;
        sha)     echo "$_line" | awk '{print $4}' ;;
        *) die "lock_field: bad field '$_f'" ;;
    esac
}

# --- fetch + verify + extract -------------------------------------------------
# fetch_verify <name> <target>  -> echoes a freshly-extracted source dir.
#
# The extraction dir is PER-TARGET (work/src/<target>/<name>): configure/make
# mutate the source in place (zlib renames zconf.h.in -> zconf.h, etc.), so a
# shared work/src/<name> across targets means a second target — or a concurrent
# `provision.sh` — clobbers or half-consumes the first's tree. Keeping it
# per-target makes builds independent and lets `provision.sh --all` (or two
# hand-run invocations) coexist safely.
fetch_verify() {
    _n=$1
    _t=${2:-common}
    _url=$(lock_field "$_n" url)
    _sha=$(lock_field "$_n" sha)
    # Name-prefixed cache key: collision-safe if two deps ever share a basename
    # (e.g. FreeBSD amd64/arm64 base.txz). Matches scripts/pin-hashes.sh.
    _tar="$DL/$_n-$(basename "$_url")"
    if [ ! -f "$_tar" ]; then
        log "fetch $_n <- $_url"
        curl -fsSL "$_url" -o "$_tar" || die "download failed: $_url"
    fi
    if [ "$_sha" = "PIN_ME" ]; then
        log "WARNING: $_n sha is PIN_ME — skipping checksum (run scripts/pin-hashes.sh)"
    else
        _got=$(sha256sum "$_tar" | awk '{print $1}')
        [ "$_got" = "$_sha" ] || die "$_n checksum mismatch: got $_got want $_sha"
    fi
    _ex="$WORK/src/$_t/$_n"
    rm -rf "$_ex"; mkdir -p "$_ex"
    tar xf "$_tar" -C "$_ex" --strip-components=1 || die "extract failed: $_tar"
    echo "$_ex"
}

# --- staging into the target sysroot -----------------------------------------
sysroot_dir() { echo "$SYSROOTS/$1"; }

stage_lib() {
    _t=$1; shift
    _d="$(sysroot_dir "$_t")/lib"; mkdir -p "$_d"
    for f in "$@"; do [ -f "$f" ] && cp -f "$f" "$_d/" || die "stage_lib: missing $f"; done
}
stage_headers() {
    _t=$1; shift
    _d="$(sysroot_dir "$_t")/include"; mkdir -p "$_d"
    for h in "$@"; do
        if [ -d "$h" ]; then cp -Rf "$h/." "$_d/"; else cp -f "$h" "$_d/"; fi
    done
}
stage_license() {
    _t=$1; _lib=$2; shift 2
    _d="$(sysroot_dir "$_t")/licenses/$_lib"; mkdir -p "$_d"
    for f in "$@"; do [ -f "$f" ] && cp -f "$f" "$_d/" || true; done
}

# Assert a staged archive is actually for the target arch (Mach-O arm64 etc.).
# Best-effort: uses `file` on an extracted member.
assert_arch() {
    _t=$1; _lib=$2
    command -v file >/dev/null 2>&1 || return 0
    _tmp="$WORK/archck"; rm -rf "$_tmp"; mkdir -p "$_tmp"
    ( cd "$_tmp" && "$ZIG" ar x "$_lib" 2>/dev/null || true )
    # -quit stops at the first match so `find` never writes into a closed pipe
    # (the old `find | head -1` raised a harmless-but-alarming SIGPIPE on big
    # archives like libcrypto.a). Fall back to a plain glob if -quit is absent.
    _o=$(find "$_tmp" -name '*.o' -print -quit 2>/dev/null || true)
    [ -n "$_o" ] || _o=$(ls "$_tmp"/*.o 2>/dev/null | head -1 || true)
    [ -n "$_o" ] || return 0
    # Report just the file(1) description (`-b`), not the temp path, for a clean log.
    _desc=$(file -b "$_o" 2>/dev/null || file "$_o")
    case "$_t:$_desc" in
        *macos*:*Mach-O*|*linux*:*ELF*|*freebsd*:*ELF*|*windows*:*COFF*|*windows*:*PE32*)
            log "arch ok: $(basename "$_lib") -> $_desc" ;;
        *)
            log "WARNING: $(basename "$_lib") arch looks unexpected for $_t: $_desc" ;;
    esac
}
