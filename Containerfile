# The build environment for every RotomLab artifact.
#
# Alpine and musl, because everything produced here must run on any Linux
# distribution regardless of its glibc version. A dynamically linked binary
# fails on systems newer or older than this image, and that failure looks
# environmental in exactly the way RotomLab's pristine-baseline heuristic
# would misattribute to a broken toolchain.
FROM alpine:3.22

# This image is not documentation. `release.yml` builds it and runs the entire
# pipeline inside it, so the container described here is the one that produced
# every published byte. The per-artifact workflows (host-tools, posix, mirror,
# fragment) start from the same alpine:3.22 and `apk add` only the subset each
# needs, which keeps an edit to one artifact from rebuilding the others; that
# is a speed decision, and the release path does not take it.
#
# build-base brings gcc, g++, make, binutils and libc-dev.
#   libpng-static/zlib-static: gbagfx AND rsfont both link -lpng -lz
#   g++ static needs libstdc++.a, which build-base provides
#   file: used to verify linkage rather than assume it
#   zstd: devkitPro ships .pkg.tar.zst
#   gzip: GNU tar shells out to it for -z, and both GNU tarballs are .tar.gz
#   bzip2: mirror.sh runs `bzip2 -t` over the busybox source tarball. Its
#          absence was not an error — the check is guarded by `command -v` —
#          so this image previously skipped the one assertion that says the
#          published GPLv2 corresponding source is a readable archive and not
#          something that merely hashes correctly.
RUN apk add --no-cache \
      build-base \
      musl-dev \
      libpng-dev libpng-static \
      zlib-dev zlib-static \
      git make bash file \
      curl jq tar xz gzip zstd bzip2 \
      go

WORKDIR /work
