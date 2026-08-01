# rotomlab-artifacts

Build artifacts for [RotomLab](https://github.com/Blade67/rotomlab), a Pokémon Gen 3 ROM
hack editor.

This repository contains **no application code**. It exists to build and publish the
binaries RotomLab downloads on first run, so that users need no development environment of
their own — no devkitARM install, no MSYS2, and no host C compiler.

## Why this repository is separate, and public

RotomLab's source repository is private. GitHub release assets on a private repository
require authentication to download, and RotomLab fetches its toolchain with a plain
unauthenticated request. Artifacts therefore have to live somewhere public.

Keeping them here also keeps several hundred megabytes of binaries out of the source
repository's release history, and gives GPL corresponding-source a natural home.

## What gets published

| Artifact | Contents |
|---|---|
| `<game>-hosttools-*.tar.xz` | The decomp's own build tools (`preproc`, `gbagfx`, `scaninc`, …), prebuilt |
| `make-*` | GNU Make, statically linked |
| `bash-*` | GNU Bash, statically linked |
| `busybox-*` | Upstream's official static build, mirrored |
| `devkitarm-*.tar.xz` | devkitPro's ARM toolchain, repackaged with a stable layout |
| `manifest-fragment.json` | Ready-to-paste manifest entries with real URLs and digests |

Everything is built in Alpine against musl and statically linked, so the binaries run on
any Linux distribution regardless of its glibc version.

## Releases

`.github/workflows/release.yml` is manually dispatched and runs the whole pipeline in one
go: it builds the container from `Containerfile`, runs every script inside it, re-runs each
script's own verification suite on the glibc runner, and publishes the lot.

Tags are `artifacts-<YYYY-MM-DD>-<first 8 hex of sha256(build.json)>`.

Each asset already names itself — a host-tools tarball carries the decomp commit it was
built from, `make` and `bash` carry their upstream versions — so the tag does not repeat
any of that. What it adds is the one thing no filename carries: a fingerprint of the *set*
of pins the release was cut from. `build.json` is exactly that set, so two tags ending in
the same eight characters were built from identical inputs, and any pin change makes them
differ. The date leads because tags sort lexically. The release is created on a specific
commit of this repository, named in the release body and reachable through the tag, which
pins the build scripts as well as the pins.

An existing tag is refused rather than overwritten: a shipped manifest pins these asset
URLs *by digest*, so replacing assets under a live tag turns working installs into digest
mismatches.

## Sources and licensing

GNU Make, GNU Bash, busybox and GCC (inside devkitARM) are licensed under the GPL.
Publishing built binaries obliges us to provide the corresponding source — and the three
cases are not discharged the same way, which is why [`SOURCES.md`](SOURCES.md) spells each
one out rather than listing URLs and leaving it there:

- **`make` and `bash`** are built here from unmodified pinned tarballs by
  `scripts/build-posix.sh`. GPLv3 §6(d) permits offering the source from a network
  location, which is what their pinned URLs and digests are.
- **`busybox`** is upstream's own static build, mirrored. It is GPLv2-**only**, and v2 has
  no §6(d): linking to busybox.net is not a way to comply. Its source tarball is therefore
  published in the same release as the binary.
- **devkitARM** is devkitPro's build of *patched* GCC, binutils and newlib. Nothing here
  compiles it, and the corresponding source is devkitPro's tree — not ftp.gnu.org's
  releases of the same version numbers. `SOURCES.md` points at their `buildscripts`
  repository at the pinned tag and commit.

`SOURCES.md` is generated from `build.json` by `scripts/gen-sources.sh`, and CI fails if
the two disagree: a corresponding-source notice that describes something other than what
shipped is worse than none.

The decomp build tools come from the [pret](https://github.com/pret) decompilation
projects, at the commits pinned in `build.json`, compiled unmodified.

## Reproducing a build

Everything needed is in this repository: `build.json` pins every input, and the scripts in
`scripts/` are what CI runs. There is no hidden state.
