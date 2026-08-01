# The build environment for every RotomLab artifact.
#
# Alpine and musl, because everything produced here must run on any Linux
# distribution regardless of its glibc version. A dynamically linked binary
# fails on systems newer or older than this image, and that failure looks
# environmental in exactly the way RotomLab's pristine-baseline heuristic
# would misattribute to a broken toolchain.
FROM alpine:3.22

# build-base brings gcc, g++, make, binutils and libc-dev.
#   libpng-static/zlib-static: gbagfx AND rsfont both link -lpng -lz
#   g++ static needs libstdc++.a, which build-base provides
#   file: used to verify linkage rather than assume it
#   zstd: devkitPro ships .pkg.tar.zst
RUN apk add --no-cache \
      build-base \
      musl-dev \
      libpng-dev libpng-static \
      zlib-dev zlib-static \
      git make bash file \
      curl jq tar xz zstd \
      go

WORKDIR /work
