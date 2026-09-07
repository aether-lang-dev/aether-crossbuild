# aether-crossbuild

Maintainer tooling that **cross-builds the external C dependencies** Aether's
standard library links against — `zlib`, `pcre2`, `nghttp2`, `openssl` — for
each supported OS × CPU target, producing per-target **sysroots** that let
`ae build --target=<triple>` link a dependency-heavy Aether program from a
single Linux build agent.

> **This is not a dependency, and it does not ship binaries.** It is a
> *from-source build orchestrator* you run **occasionally, by hand, on trusted
> developer infrastructure**. The sysroots it produces are `.gitignore`d and
> never published — see [WHY-NOT-PUBLISHED.md](WHY-NOT-PUBLISHED.md) for the
> licensing reasoning (short version: we build permissive libraries from source,
> we never touch or store Apple SDK material, and the only redistributable blob
> is the freely-licensed FreeBSD base). End users never run this; they set
> `--target` and their toolchain does the rest.

## Why this exists

Aether compiles to C, so cross-compiling to another OS/CPU is a *link-time*
operation — a Linux x86_64 box can link a mac-arm64 binary without running a
single arm64 instruction. `zig cc` supplies the compiler, the target libc, and
(for macOS) the system-stub SDK, so the **system** libraries come free. But a
program that uses `std.http` or `std.cryptography` also links `openssl`,
`nghttp2`, `zlib`, `pcre2` — third-party libraries that must exist *for the
target* on the build agent. That's what this repo produces.

Programs that use none of those subsystems need no sysroot at all — `ae build
--target=...` links them with `-lm` only. This repo is only for the
dependency-heavy tier.

## The matrix

Four libraries × eight targets. The targets split into two tiers by effort:

| Tier | Targets | Base sysroot needed? |
|---|---|---|
| **A — turnkey** | `x86_64-macos`, `aarch64-macos`, `x86_64-linux-gnu`, `aarch64-linux-gnu`, `x86_64-linux-musl`, `aarch64-linux-musl` | No — `zig cc` bundles libc / macOS SDK stubs |
| **B — needs a base sysroot** | `x86_64-freebsd`, `aarch64-freebsd` (or version-pinned `…-freebsd15`) | Yes — extract FreeBSD `base.txz` once per CPU (BSD-licensed, freely redistributable) |

> **FreeBSD versions.** `zig cc` bundles a FreeBSD-14 libc, so the plain
> `…-freebsd` triple links against 14. Targeting a 15-only kernel surface
> (`sys/jail.h`, `sys/rctl.h`, Capsicum structs) needs the matching base: run
> `./scripts/fetch-freebsd-base.sh x86_64 15` (a version-suffixed `deps.lock`
> pin + `bases/x86_64-freebsd15/`), then `./provision.sh x86_64-freebsd15`. The
> version rides the base-sysroot dir only; the compiler triple stays
> `x86_64-freebsd`.

## Usage

```sh
# One-time: fetch the pinned zig toolchain into ./toolchain/
./scripts/get-zig.sh

# Build all four deps for one target into ./sysroots/<triple>/
./provision.sh aarch64-macos

# Confirm each staged lib actually LINKS (not just "right arch"):
./scripts/verify.sh aarch64-macos

# ...or every target in the matrix (slow — openssl dominates):
./provision.sh --all

# FreeBSD targets need a base sysroot first (one-time per CPU):
./scripts/fetch-freebsd-base.sh aarch64      # populates ./bases/aarch64-freebsd/
./provision.sh aarch64-freebsd
```

Output layout (each target self-contained, ready for `--sysroot`):

```
sysroots/aarch64-macos/
├── include/        # openssl/*, pcre2.h, zlib.h, nghttp2/*
├── lib/            # libcrypto.a libssl.a libpcre2-8.a libz.a libnghttp2.a
└── licenses/       # upstream LICENSE/NOTICE per lib (attribution obligation)
```

Point `ae build` at it:

```sh
ae build --target=aarch64-macos --sysroot="$PWD/sysroots/aarch64-macos" app.ae
```

## Reproducibility

Dependency versions are pinned in [`deps.lock`](deps.lock). Two maintainers
running `./provision.sh <triple>` from the same lock produce byte-comparable
sysroots. Agreeing on the *lock* (versions + recipe) is the coordination point —
not on hoarding or sharing built artifacts.

## Validation status

The cross-build recipe is proven end-to-end for the two riskiest libraries on a
Linux x86_64 host with `zig cc` (no macOS involved):

- **pcre2 → mac-arm64**: `Mach-O 64-bit arm64` static lib. ✅ built & verified.
- **openssl → mac-arm64**: `libcrypto.a` / `libssl.a`, `Mach-O 64-bit arm64`.
  ✅ built & verified — **with a required fix**: openssl's macOS path
  `#include`s `<CommonCrypto/CommonCryptoError.h>`, an Apple-framework header
  `zig cc` does not ship. We disable it with `-DOPENSSL_NO_APPLE_CRYPTO_RANDOM`
  (openssl falls back to `getentropy`/`arc4random`, both in libSystem). This is
  also the right call for the "never touch Apple SDK" policy — see
  `recipes/openssl.sh` and WHY-NOT-PUBLISHED.md.

zlib and nghttp2 use the standard `CHOST` / autoconf `--host` cross patterns and
are wired accordingly; validate on first real run.

## Layout

```
provision.sh              # orchestrator: provision.sh <triple> | --all
deps.lock                 # pinned versions + source URLs + sha256
recipes/
├── common.sh             # zig-cc wrappers, triple↔autoconf-host mapping, helpers
├── zlib.sh   pcre2.sh   nghttp2.sh   openssl.sh
scripts/
├── get-zig.sh            # fetch+verify the pinned zig tarball
├── fetch-freebsd-base.sh # extract FreeBSD base.txz into ./bases/<cpu>-freebsd/
├── pin-hashes.sh         # print each deps.lock URL's real sha256 (keep the lock honest)
└── verify.sh             # verify.sh <triple>: link a probe using each staged lib
WHY-NOT-PUBLISHED.md      # the licensing boundary — read before adding a release
```
