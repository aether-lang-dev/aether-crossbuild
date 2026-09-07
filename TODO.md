# TODO

Extension work for aether-crossbuild. The script is structured so adding a
target is a few `case`-arms in `recipes/common.sh` (`map_zig_target`,
`map_autoconf_host`, `map_openssl_target`, `target_extra_cflags`) plus a `MATRIX`
entry — not a rewrite. Add **validated** targets only; a speculative row that
nobody has run rots into a broken row. Prove each new target builds at least one
lib before committing it to `MATRIX`.

## Direction decision (Nic) — is this whole matrix what we want?

Before more targets get added, **Nic needs to decide the direction**. The
current 8-target `MATRIX` was chosen by the person building this out, not ratified
— and only some of it maps to what Aether's CI already treats as "supported."
Three groups need an explicit yes/no, because they carry different maintenance
and provenance costs:

| Group | Targets | Status | Maps to Aether CI? | Decision needed |
|---|---|---|---|---|
| **Core** | linux-gnu ×2, macos ×2 | ✅ proven | Yes (ubuntu + macos are CI-gated) | Keep — uncontroversial |
| **musl** | `x86_64-linux-musl`, `aarch64-linux-musl` | ✅ proven | **No** — not in Aether CI | **Nic: do we want static-Linux builds?** |
| **FreeBSD** | `x86_64-freebsd`, `aarch64-freebsd` | ⚠️ base + zlib/pcre2/openssl proven; nghttp2 deferred (lib port) | **No** — not in Aether CI | **Nic: do we support FreeBSD?** (Paul runs FreeBSD/GhostBSD infra; needs a stored base.txz per CPU) |
| **Windows** | `x86_64-windows`, `aarch64-windows` | ❌ not wired | **Yes** — heavily CI-gated (windows ~ as much as ubuntu) | **Nic: add? It's the one CI-parity gap** (details below) |

The tension to resolve: if the goal is **strict Aether-CI parity**, we'd *drop*
musl+FreeBSD and *add* Windows. But musl (static, distro-independent Linux
binaries) and FreeBSD (Paul's deploy infra) were added for real reasons beyond
CI parity. So the real question for Nic is **"is the goal CI parity, or broader
delivery coverage?"** — that answer decides which of the three groups stay.

Nothing below should be *built* until that direction is set. Each group's
technical notes are kept here so whichever way Nic goes, the work is scoped.

---

## Windows (x86_64 + aarch64) — the CI-parity gap

The one genuine gap. `zig cc` bundles a full Windows target (MinGW-w64 CRT), so
it's turnkey compiler-side — no sysroot — and "deliver a Windows `.exe` from a
Linux agent" is a headline use case (Aether's own CI matrix gates on Windows).

Not a one-liner, though — the four deps map differently on Windows:

- [ ] **`map_zig_target`**: `x86_64-windows` → `x86_64-windows-gnu`,
      `aarch64-windows` → `aarch64-windows-gnu`.
- [ ] **`map_autoconf_host`** (zlib CHOST / pcre2 / nghttp2): `x86_64-w64-mingw32`,
      `aarch64-w64-mingw32`.
- [ ] **`map_openssl_target`**: `mingw64` (x86_64) / `mingw` — openssl's Windows
      Configure targets, not the `darwin*`/`linux-*` ones. Watch for Win32 API
      calls in openssl's build; may need `no-asm` or extra flags on aarch64.
- [ ] **Staging nuance**: Windows import/static libs. We build `--disable-shared`
      so it stays `.a` (MinGW archives), but confirm the linker later wants
      `libfoo.a` not `foo.lib`, and that headers land the same way.
- [ ] **`assert_arch`**: already has a `*windows*:*COFF*|*windows*:*PE32*` arm;
      verify `file(1)` reports COFF for a MinGW `.a` member.
- [ ] **Validate**: cross-build at least pcre2 + openssl to `x86_64-windows` on a
      Linux box and confirm `Mach-O`→COFF/PE members, the way mac was proven.
- [ ] Add both to `MATRIX` in `provision.sh` once green.

**Why it's the strongest case for adding:** Windows is the platform users least
want to build from source themselves, Aether already auto-fetches a MinGW
toolchain on Windows to spare them, and Aether CI gates on it as heavily as
Linux. If we're doing cross-compile delivery at all, "Windows .exe from a Linux
agent" is close to the point of the exercise.

## musl (x86_64 + aarch64) — static-Linux delivery [DECISION: Nic]

**Status: proven** (both build clean; verified distinct ELF x86-64 / aarch64).
Already in `MATRIX`. The open question is whether we *keep* it.

- **The pitch:** musl links a fully static, distro-independent Linux binary —
  "runs on any Linux, no glibc-version roulette." Great for containers, edge, and
  shipping a single binary to a machine you don't control.
- **Against:** not in Aether's CI matrix, so it's coverage *beyond* what the
  language formally supports. Two extra targets to maintain and CI-time to spend.
- **Nic decides:** keep musl ×2, or drop to glibc-only and treat static Linux as
  an on-demand extra? If kept, it's zero further work — it's done and validated.

## FreeBSD (x86_64 + aarch64) — BSD delivery [DECISION: Nic]

**Status (2026-07-21): base sysroot PROVEN, zlib cross-builds; the autoconf
recipes (pcre2/nghttp2/openssl) blocked on a LINK-side CRT gap.** The base path
is no longer untested — `fetch-freebsd-base.sh x86_64 15` extracts a usable
sysroot, `ae build --target=x86_64-freebsd` cross-links + runs REAL aeo on a
FreeBSD-15 box (jail/bhyve substrates detected). A `provision.sh x86_64-freebsd15`
run surfaced two recipe gaps (both twins of the tools/ae.c #1208 FreeBSD fixes —
the recipes were only exercised on Tier-A targets):

- [x] **Gap A (COMPILE) — FIXED:** `target_extra_cflags` emitted only
      `--sysroot`, so `#include <sys/types.h>` failed "file not found" (zlib died
      immediately). `--sysroot` ALONE doesn't add the base's include/lib for a
      FreeBSD target (unlike zig's bundled targets). Fixed to also emit
      `-I$B/usr/include -L$B/usr/lib -L$B/lib`. **zlib now builds + stages.**
- [x] **Gap B (LINK) — FIXED:** configure/openssl link-probe a test executable,
      which on FreeBSD needs CRT objects + real libc.so.7 (`configure: error: C
      compiler cannot create executables`; zig can't supply a FreeBSD libc). Fix:
      `setup_zig_wrappers` takes the base dir and its cc/c++ wrappers add the
      FreeBSD link recipe (`-nostdlib crt1/crti/libc.so.7/crtn`) on LINK
      invocations (`-c` absent), AND rescue zig's cosmetic "libc not available"
      nonzero exit when the output (`-o <f>`, default `a.out`) was written —
      mirroring ae.c's "output exists == linked" (#1216). Baking it into the
      wrapper (not per-recipe LDFLAGS) covers all three build systems uniformly.
      Now **zlib + pcre2 + openssl all cross-build + stage** for x86_64-freebsd15
      (libcrypto.a verified `ELF … (FreeBSD)`, 29 MB). Plus a recipe tweak:
      openssl gets `no-asm` on freebsd (its x86_64 perlasm uses gas syntax zig's
      integrated assembler rejects).
- [ ] **nghttp2 — per-lib port issue (NOT infrastructure, NOT blocking aeo):**
      fails at make with FreeBSD-15 `sys/types.h` `gid_t`/`uid_t` typedef errors
      ("cannot combine with previous type-name") — nghttp2-specific header-order
      poisoning (a bare `#include <sys/types.h>` compiles clean, so it's not a
      base-sysroot bug). Deferred: aeo doesn't need it — nghttp2 is OPTIONAL in
      std.http ("when the build doesn't link libnghttp2 the wrapper compiles to
      no-op"; HTTP/2 SERVER only, and aeo's PVE client is HTTP/1.1). Fix when a
      cross-shipped app actually needs HTTP/2.

AEO STATUS: the three libs aeo needs (openssl for std.cryptography hmac +
std.http.client TLS; zlib; pcre2 not even needed — no regex) now cross-build.
Real-aeo TLS-half cross-compile is unblocked: point CROSSBUILD_SYSROOT at
sysroots/x86_64-freebsd15 and rebuild.

**Original decision framing below.** In `MATRIX`; base + the three aeo-relevant
libs proven; nghttp2 deferred as a lib-specific port.

- **The pitch:** Paul runs FreeBSD / GhostBSD infrastructure; this is real deploy
  surface for him. BSD base is freely redistributable (no Apple-style restriction
  — the safe tier, licensing-wise).
- **The cost:** unlike the turnkey targets, FreeBSD needs a stored `base.txz`
  (~200 MB per CPU) fetched via `scripts/fetch-freebsd-base.sh`, because `zig cc`
  bundles no FreeBSD libc. So it's the one tier with a stored blob and an extra
  provisioning step.
- **Not in Aether CI** — coverage beyond formal support, justified by Paul's infra
  rather than parity.
- **Nic decides:** do we support FreeBSD as a target? If yes, the remaining work
  is:
  - [x] Run `scripts/fetch-freebsd-base.sh x86_64`... confirm the
        base extracts to a usable `--sysroot`.
  - [ ] Prove at least pcre2 + openssl cross-build against the FreeBSD sysroot
        (openssl uses `BSD-x86_64` / `BSD-aarch64` Configure targets — already
        wired in `map_openssl_target`).
  - [ ] Confirm `map_autoconf_host` FreeBSD hosts (`*-unknown-freebsd`) resolve.

## On demand only (don't add speculatively)

`zig cc` can target far more than we should carry. Add these when a real consumer
asks, using the existing recipes as the template:

- [ ] **32-bit ARM Linux** (`arm-linux-gnueabihf`, `arm-linux-musl`) — Raspberry
      Pi / embedded class. musl variant gives a static portable binary.
- [ ] **riscv64-linux** (gnu + musl) — turnkey compiler-side; openssl builds but
      is the usual per-arch adventure.
- [ ] **ppc64le / s390x-linux** — only for enterprise/mainframe asks. Expect
      openssl per-arch friction.
- [ ] **NetBSD / OpenBSD** — same shape as FreeBSD: no bundled zig libc, so each
      needs a base-sysroot fetch (clone `scripts/fetch-freebsd-base.sh`). BSD
      base is freely redistributable, like FreeBSD.

## Explicitly NOT in scope here

- **wasm (`wasm32-wasi`)** — a `ae build --target` concern, not a sysroot one.
  The C deps (openssl especially) don't build for wasm; Aether's `ci-wasm` uses a
  minimal runtime subset. No-external-dep wasm programs cross-compile with `-lm`
  alone and need nothing from this repo.
- **Anything that would require storing Apple SDK material** — see
  WHY-NOT-PUBLISHED.md. macOS system libs come only from bundled `zig cc`.

## Housekeeping / smaller items

- [ ] **nghttp2 for freebsd/windows**: confirm `--without-*` flags still suffice
      (no accidental libxml2/jansson/openssl pickup from the target sysroot).
      `scripts/verify.sh` now covers the link half automatically wherever
      nghttp2 is staged (its probe calls `nghttp2_version`); still open is
      staging nghttp2 for those targets (freebsd nghttp2 is deferred on a
      per-lib header port, see the FreeBSD section).
- [ ] **Parallelism**: `provision.sh --all` builds targets serially; openssl
      dominates each. A `-jN`-across-targets mode could cut wall-clock on a big
      agent, but keep logs per-target legible.
- [x] **A `verify.sh`** — DONE (2026-09-07). `scripts/verify.sh <triple>`: for
      each staged lib, compiles a tiny C probe that calls a real function
      (zlibVersion / pcre2_compile / EVP_* / nghttp2_version / sqlite3_*), links
      it by absolute archive path against the sysroot through the same zig
      wrapper provision.sh uses, and confirms a binary was produced with the
      symbols resolved. Links only (a cross binary can't run on the Linux host).
      Proven on x86_64-freebsd15 (zlib+pcre2+openssl), x86_64-linux-gnu
      (zlib+pcre2+sqlite), x86_64-windows (COFF/PE: zlib+pcre2+sqlite). It
      caught a real one on Windows — pcre2's header defaults to
      `__declspec(dllimport)`, so a static link needs `-DPCRE2_STATIC` (the
      probe sets it; harmless elsewhere), exactly the "right arch but won't
      link" gap this closes.
- [ ] **Run-on-hardware proof**: the one check no Linux agent can do — launch a
      linked mac-arm64 / windows binary on real hardware (or a `macos-14` /
      `windows` CI runner) and confirm it executes. Arch + symbol + libSystem
      evidence is conclusive that it's a valid image, but execution closes it.

## zlib fetch is FLAKY — `zlib.net/fossils` is a mutable URL (pin an immutable mirror) — FIXED 2026-09-07

**FIXED:** `deps.lock` now pins zlib to the immutable GitHub release asset
`https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz`.
The GitHub asset hashes to the SAME `9a93b2b7…` as the old zlib.net/fossils
tarball (byte-identical 1.3.1 source), so ONLY the URL changed — verified via
`scripts/pin-hashes.sh` (all deps still resolve, zlib sha unchanged). This
removes the only mutable-URL dep; the intermittent `zlib checksum mismatch`
flake is gone.

---

**Reported by:** the aeo line, 2026-09-07. Non-deterministically breaks FreeBSD
cross-builds that need zlib (openssl links it; aeo's CLI freebsd bundle was
dropped from the aeo v0.2.0 release because of this — twice).

**Symptom:** `provision.sh` fails at zlib with
`✗ zlib checksum mismatch: got <X> want 9a93b2b7…`. Seen with TWO different
"got" hashes across runs:
- `300594da9d83883ac75ec5f47ef696fe955f8d31eed8a84870f87a09452f0ba7`
- `085caa66962369209d57d758deb61e3db1a0060ce54bb3354e4db0aa32c21ca0`

**Cause:** `deps.lock` pins zlib to
`https://zlib.net/fossils/zlib-1.3.1.tar.gz` — a **mutable** URL. zlib.net
re-generates the fossils tarball (recompression/repackaging), so its sha256
drifts while our pin stays fixed → the verify fails intermittently. (Two
different got-hashes = the source is mutating, not transit corruption.) Note the
OTHER three deps (pcre2, nghttp2, openssl) all use **GitHub release-download**
URLs, which are immutable — only zlib uses the flaky host.

**Fix (one deps.lock line):** point zlib at the immutable GitHub release asset,
same 1.3.1 source:
`https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz`
Then set that entry's sha256 from `scripts/pin-hashes.sh` (it prints the real
sha for every deps.lock URL). Verify the new tarball builds (`provision.sh
x86_64-freebsd15`) before committing. If madler's asset hashes to the SAME
9a93b2b7… as the current pin, only the URL changes.

Low-risk, matches the sibling deps' pattern, and removes the only mutable-URL
dep. Until then, a failed aeo FreeBSD bundle is just this flake — re-run.
