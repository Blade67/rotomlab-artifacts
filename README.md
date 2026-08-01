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

## Sources and licensing

GNU Make, GNU Bash, and GCC (inside devkitARM) are licensed under the GPL. Publishing built
binaries obliges us to provide the corresponding source.

Every component is built from **unmodified, pinned upstream releases** by the scripts in
this repository. `SOURCES.md` records, for each release, the exact upstream URL and SHA-256
of every source tarball and the container image used to build it. Nothing here is patched.

The decomp build tools come from the [pret](https://github.com/pret) decompilation
projects, at the commits pinned in `build.json`.

## Reproducing a build

Everything needed is in this repository: `build.json` pins every input, and the scripts in
`scripts/` are what CI runs. There is no hidden state.
