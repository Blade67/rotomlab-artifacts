#!/bin/sh
# mirror.sh
#
# Republishes the two binaries RotomLab does not build: devkitPro's ARM
# toolchain, and upstream busybox's official static build.
#
# Neither can be fetched by RotomLab directly. devkitPro's CDN answers 403 to
# requests without a User-Agent, which Go's default client does not send, and
# devkitARM is not one download in the first place — it is a metapackage with
# no files of its own (ISIZE 0) whose five-package dependency closure has to be
# fetched and merged before there is a toolchain to install. busybox is a
# single file and could in principle be linked upstream, but it is GPLv2-only:
# unlike GPLv3 there is no provision for merely pointing at a source location,
# so the source tarball has to accompany the binary we publish.
#
# Output, under out/:
#   devkitarm-<version>-linux-amd64.tar.xz   (opt/devkitpro/devkitARM prefix intact)
#   busybox-<version>-linux-amd64            (the binary)
#   busybox-<version>.tar.bz2                (its corresponding source)
# and one JSON line on stdout:
#   {"devkitarm":{...},"busybox":{...,"source":{...}}}
#
# Everything else goes to stderr, so stdout is exactly that line and can be
# piped straight into jq.
#
# VERIFY_ONLY=1 mirror.sh <devkitarm-tarball> <busybox-binary> skips the fetch
# and runs only the functional checks against two existing files. CI uses it to
# re-run the identical assertions on a glibc host, so the two sides cannot
# drift apart — and because devkitPro's binaries are dynamically linked glibc
# PIEs (their build, not ours; we cannot make them static), the glibc host is
# the only place `arm-none-eabi-gcc --version` can actually be run.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

BUILD_JSON="${BUILD_JSON:-$ROOT/build.json}"
export BUILD_JSON
. "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<'EOF'
usage: mirror.sh
       VERIFY_ONLY=1 mirror.sh <devkitarm-tarball> <busybox-binary>

  Takes no arguments when mirroring. Versions, URLs and digests all come from
  build.json; nothing is fetched that is not pinned there.

environment:
  OUT_DIR          where to write the artifacts (default: <repo>/out)
  DL_DIR           where to cache verified downloads (default: $OUT_DIR/dl)
  REQUIRE_GCC_RUN  1 to make a failure to execute arm-none-eabi-gcc fatal.
                   Defaults to 0 when mirroring (the musl build container
                   cannot run a glibc PIE) and 1 under VERIFY_ONLY.
  VERIFY_ONLY      1 to only run the functional checks on existing files
EOF
  exit 2
}

# Metadata every pacman package carries at its root. It describes the package,
# not the toolchain, and merging five packages' worth of it would leave five
# files fighting over three names — so it is dropped at extraction and its
# absence asserted afterwards.
PKG_META='.PKGINFO .MTREE .BUILDINFO .INSTALL .CHANGELOG'

# ---------------------------------------------------------------------------
# Checks that run both here and, unchanged, on the glibc host.
# ---------------------------------------------------------------------------

# lexical_clean <absolute-path> — resolve "." and ".." textually, exactly as
# Go's filepath.Clean does, without touching the filesystem. Written out rather
# than shelled to realpath -m because busybox's realpath has no -m, and
# resolving through the filesystem would answer a different question than the
# one RotomLab's extractor asks.
lexical_clean() {
  printf '%s\n' "$1" | awk -F/ '{
    n = 0
    for (i = 1; i <= NF; i++) {
      c = $i
      if (c == "" || c == ".") continue
      if (c == "..") { if (n > 0) n--; continue }
      st[++n] = c
    }
    s = ""
    for (i = 1; i <= n; i++) s = s "/" st[i]
    print (s == "" ? "/" : s)
  }'
}

# escaping_symlinks <absolute-root> — the symlinks RotomLab's untar would
# refuse. It validates where a link points, not just where it lives, and a
# single offender aborts the entire install.
escaping_symlinks() {
  _root=$1
  find "$_root" -type l | while read -r l; do
    t=$(readlink "$l")
    case "$t" in
      /*) r=$t ;;
      *)  r="$(dirname "$l")/$t" ;;
    esac
    r=$(lexical_clean "$r")
    case "$r" in
      "$_root"|"$_root"/*) : ;;
      *) printf '%s -> %s\n' "$l" "$t" ;;
    esac
  done
}

# verify_devkitarm_tree <root> <strip-prefix>
#
# Asserts the merged tree is the shape RotomLab's extractor requires. The
# layout check is the important one: build.json declares stripPrefix
# "opt/devkitpro/devkitARM", and fetch's untar silently *skips* every member
# outside that prefix rather than erroring. A tree assembled one directory
# higher or lower therefore installs as an empty directory and reports nothing,
# and the failure surfaces much later as a toolchain that has no compiler in
# it, with nothing pointing back at this script.
verify_devkitarm_tree() {
  vroot=$1; vprefix=$2
  case "$vroot" in /*) : ;; *) die "verify_devkitarm_tree needs an absolute root: $vroot" ;; esac

  for m in $PKG_META; do
    found=$(find "$vroot" -name "$m" 2>/dev/null | head -n 5)
    [ -z "$found" ] || die "package metadata survived into the merged tree:
$found"
  done
  log "check   no package metadata ($PKG_META) in the merged tree"

  [ -d "$vroot/$vprefix" ] ||
    die "merged tree has no $vprefix
  top level: $(ls "$vroot" 2>/dev/null | tr '\n' ' ')"

  gcc="$vroot/$vprefix/bin/arm-none-eabi-gcc"
  [ -f "$gcc" ] || die "no compiler at $vprefix/bin/arm-none-eabi-gcc
  this is the path RotomLab's extractor produces from stripPrefix $vprefix;
  bin/ holds: $(ls "$vroot/$vprefix/bin" 2>/dev/null | head -n 20 | tr '\n' ' ')"
  [ -x "$gcc" ] || die "$vprefix/bin/arm-none-eabi-gcc is not executable"
  log "check   $vprefix/bin/arm-none-eabi-gcc present and executable"

  # A handful of other binaries the decomp builds invoke by name. Not
  # exhaustive, but a merge that dropped a package would take one of these
  # with it, and "gcc is present" alone would not have noticed.
  for t in arm-none-eabi-as arm-none-eabi-ld arm-none-eabi-objcopy \
           arm-none-eabi-gcc-ar arm-none-eabi-g++; do
    [ -f "$vroot/$vprefix/bin/$t" ] || die "no $t in $vprefix/bin"
  done
  log "check   binutils, g++ and gcc-ar all present alongside it"

  # RotomLab's untar refuses a symlink resolving outside the extraction root,
  # which after stripping is the prefix directory itself. A symlink pointing
  # up and out of it aborts the whole install, so it is caught here instead.
  bad=$(escaping_symlinks "$(lexical_clean "$vroot/$vprefix")")
  [ -z "$bad" ] || die "symlinks resolve outside $vprefix; RotomLab's extractor
rejects these and aborts the install:
$bad"
  log "check   every symlink under $vprefix resolves inside it"

  # Does it actually run? Dynamically linked glibc PIEs, so this only works
  # where a glibc loader exists. Non-fatal when mirroring under musl —
  # reported rather than worked around — and required on the glibc host.
  if "$gcc" --version >"$WORK/gcc.out" 2>&1; then
    log "check   arm-none-eabi-gcc --version: $(head -n1 "$WORK/gcc.out")"
  else
    st=$?
    if [ "$REQUIRE_GCC_RUN" = 1 ]; then
      sed 's/^/    | /' "$WORK/gcc.out" >&2
      die "arm-none-eabi-gcc could not be executed (exit $st)"
    fi
    warn "arm-none-eabi-gcc did not run here (exit $st): $(head -n1 "$WORK/gcc.out")"
    warn "expected under musl — upstream ships dynamically linked glibc PIEs."
    warn "The glibc CI job runs this same check with REQUIRE_GCC_RUN=1."
  fi
}

# verify_busybox <binary>
#
# The applet check is what this exists for. busybox is one binary and the
# manifest symlinks each applet name to it; a name the binary does not
# implement produces a symlink that resolves fine and then exits 1 with
# "applet not found" the first time a decomp recipe calls it — thousands of
# lines into a build log, looking like a broken decomp.
verify_busybox() {
  vbb=$1
  [ -x "$vbb" ] || die "not executable: $vbb"

  require_static "$vbb"
  log "check   busybox: $(file -b "$vbb")"

  "$vbb" --help >"$WORK/bb.help" 2>&1 || true
  ver=$("$vbb" --help 2>&1 | head -n1)
  log "check   busybox --help: $ver"

  "$vbb" --list >"$WORK/bb.list" 2>&1 || die "busybox --list failed"
  have=$(wc -l <"$WORK/bb.list")
  log "check   busybox --list reports $have applets"

  missing=
  for a in $APPLETS; do
    grep -qx -- "$a" "$WORK/bb.list" || missing="$missing $a"
  done
  [ -z "$missing" ] || die "busybox lacks applets RotomLab's manifest names:$missing"
  log "check   all $(printf '%s\n' $APPLETS | wc -l) required applets present:$(printf ' %s' $APPLETS)"

  # The applets are reached through argv[0], not through --list, so at least
  # one is exercised the way the symlinks will reach it.
  ln -sf "$(CDPATH= cd -- "$(dirname -- "$vbb")" && pwd)/$(basename -- "$vbb")" "$WORK/sed"
  got=$(printf 'emerald\n' | "$WORK/sed" 's/emerald/ok/') ||
    die "busybox invoked as 'sed' through a symlink failed"
  [ "$got" = ok ] || die "busybox-as-sed printed '$got', expected 'ok'"
  log "check   invoked as 'sed' through a symlink, it behaves as sed"

  got=$("$vbb" sh -c 'echo hi') || die "busybox sh -c failed"
  [ "$got" = hi ] || die "busybox sh printed '$got', expected 'hi'"
  log "check   busybox sh -c 'echo hi' -> $got"
}

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

need jq file sha256sum find sed grep awk

APPLETS=$(cfg '.mirrors.busybox.applets | join(" ")')
case "$APPLETS" in
  *[!A-Za-z0-9\ ._-]*|'') die "build.json: .mirrors.busybox.applets holds a name that is not a bare applet name: $APPLETS" ;;
esac

STRIP_PREFIX=$(cfg '.mirrors.devkitarm.strip_prefix')

# ---------------------------------------------------------------------------
# VERIFY_ONLY: check files someone else produced, and stop.
# ---------------------------------------------------------------------------
if [ "${VERIFY_ONLY:-}" = 1 ]; then
  [ $# -eq 2 ] || usage
  need tar xz
  REQUIRE_GCC_RUN="${REQUIRE_GCC_RUN:-1}"

  log "verify  $1"
  mkdir -p "$WORK/unpacked"
  tar -C "$WORK/unpacked" -xf "$1" || die "could not extract $1"
  verify_devkitarm_tree "$WORK/unpacked" "$STRIP_PREFIX"

  log "verify  $2"
  verify_busybox "$2"

  log "ok      both mirrors pass every functional check on this host"
  exit 0
fi

[ $# -eq 0 ] || usage

need curl tar xz zstd
REQUIRE_GCC_RUN="${REQUIRE_GCC_RUN:-0}"

OUT_DIR="${OUT_DIR:-$ROOT/out}"
DL_DIR="${DL_DIR:-$OUT_DIR/dl}"
mkdir -p "$OUT_DIR" "$DL_DIR"

# check_pin <version> <sha256> <what> — versions become filenames and, through
# the manifest, parts of a URL; digests that are the wrong shape mean the value
# was mangled on the way into build.json and every later comparison would be
# against the wrong thing.
check_pin() {
  case "$1" in
    *[!A-Za-z0-9._-]*|'') die "build.json: $3 version is not filename-safe: $1" ;;
  esac
  case "$2" in
    ????????????????????????????????????????????????????????????????) : ;;
    *) die "build.json: $3 sha256 is not a 64-character digest: $2" ;;
  esac
  case "$2" in
    *[!0-9a-f]*) die "build.json: $3 sha256 is not lowercase hex: $2" ;;
  esac
}

# ===========================================================================
# 1. devkitARM
# ===========================================================================
DKA_VERSION=$(cfg '.mirrors.devkitarm.version')
case "$DKA_VERSION" in
  *[!A-Za-z0-9._-]*|'') die "build.json: .mirrors.devkitarm.version is not filename-safe: $DKA_VERSION" ;;
esac
case "$STRIP_PREFIX" in
  ''|/*|*..*) die "build.json: .mirrors.devkitarm.strip_prefix is not a relative path: $STRIP_PREFIX" ;;
esac

DKA_ARTIFACT="devkitarm-$DKA_VERSION-linux-amd64.tar.xz"
PKG_COUNT=$(cfg '.mirrors.devkitarm.packages | length')
[ "$PKG_COUNT" -ge 1 ] || die "build.json lists no devkitARM packages"

log "devkitARM $DKA_VERSION: $PKG_COUNT packages -> $DKA_ARTIFACT"

MERGED="$WORK/merged"
mkdir -p "$MERGED"
: >"$WORK/all-members"

i=0
while [ "$i" -lt "$PKG_COUNT" ]; do
  name=$(cfg ".mirrors.devkitarm.packages[$i].name")
  pver=$(cfg ".mirrors.devkitarm.packages[$i].version")
  url=$(cfg ".mirrors.devkitarm.packages[$i].url")
  psha=$(cfg ".mirrors.devkitarm.packages[$i].sha256")
  check_pin "$pver" "$psha" ".mirrors.devkitarm.packages[$i]"
  case "$name" in
    *[!A-Za-z0-9._-]*|'') die "build.json: package $i name is not filename-safe: $name" ;;
  esac
  # The URL is only ever handed to curl, but a non-https one would quietly
  # discard the transport check that the pinned digest is not a substitute for.
  case "$url" in
    https://*) : ;;
    *) die "build.json: package $name url is not https: $url" ;;
  esac

  pkg="$DL_DIR/$name-$pver.pkg.tar.zst"
  fetch_verify "$url" "$psha" "$pkg"

  # Extracted per package rather than straight into the merged tree, so a
  # collision between two packages is detectable at all: extracting into one
  # directory would let the second silently overwrite the first.
  dir="$WORK/pkg/$name"
  rm -rf "$dir"; mkdir -p "$dir"
  # shellcheck disable=SC2086
  ex=""
  for m in $PKG_META; do ex="$ex --exclude=$m"; done
  # shellcheck disable=SC2086
  tar --zstd -C "$dir" $ex -xf "$pkg" || die "could not extract $pkg"

  files=$(find "$dir" -mindepth 1 \! -type d | wc -l)
  tops=$(ls -A "$dir" | tr '\n' ' ')
  log "unpack  $name-$pver: $files entries, top level: $tops"
  [ "$files" -gt 0 ] || die "$name unpacked to nothing but its metadata"

  ( cd "$dir" && find . -mindepth 1 \! -type d | sed 's|^\./||' ) >>"$WORK/all-members"

  i=$((i + 1))
done

# A file two packages both claim would be resolved by whichever was copied
# last, which is an ordering-dependent artifact and not something to ship.
dupes=$(sort "$WORK/all-members" | uniq -d | head -n 20)
[ -z "$dupes" ] || die "packages overlap; the merge would be order-dependent:
$dupes"
log "merge   $(wc -l <"$WORK/all-members") members across $PKG_COUNT packages, no overlaps"

i=0
while [ "$i" -lt "$PKG_COUNT" ]; do
  name=$(cfg ".mirrors.devkitarm.packages[$i].name")
  cp -a "$WORK/pkg/$name/." "$MERGED/"
  i=$((i + 1))
done

# The per-package trees have served their purpose (collision detection); a
# gigabyte and a half of them is worth not carrying through the rest of the run.
rm -rf "$WORK/pkg"

merged_files=$(find "$MERGED" -mindepth 1 \! -type d | wc -l)
[ "$merged_files" = "$(wc -l <"$WORK/all-members")" ] ||
  die "merged tree holds $merged_files members, expected $(wc -l <"$WORK/all-members")"
log "merge   $MERGED: $merged_files members, top level: $(ls -A "$MERGED" | tr '\n' ' ')"

verify_devkitarm_tree "$MERGED" "$STRIP_PREFIX"

# Anything outside the strip prefix is dropped by RotomLab's extractor. Not an
# error — pacman packages routinely ship a licence directory elsewhere — but
# worth naming, because a merge that put the toolchain in the wrong place would
# show up here as the whole tree being "outside".
outside=$(cd "$MERGED" && find . -mindepth 1 \! -type d | sed 's|^\./||' |
          grep -v "^$STRIP_PREFIX/" | head -n 20 || true)
if [ -n "$outside" ]; then
  log "note    members outside $STRIP_PREFIX (dropped on install):"
  printf '%s\n' "$outside" | sed 's/^/          /' >&2
fi

# ---------------------------------------------------------------------------
# Package
#
# --hard-dereference is load-bearing, not tidiness. GCC installs several of its
# drivers as hard links (arm-none-eabi-gcc and arm-none-eabi-gcc-<version> are
# the same inode), and RotomLab's untar handles TypeDir, TypeReg and
# TypeSymlink and *skips everything else* — a hard-link member is silently
# dropped. Whichever of the pair tar happened to emit second would simply not
# exist after install, and which one that is depends on tar's traversal order.
# Dereferencing costs a few duplicated megabytes and removes the failure mode.
#
# The prefix is kept intact rather than stripped here: build.json declares
# stripPrefix opt/devkitpro/devkitARM and RotomLab strips it at extraction, so
# an archive already stripped would have every member skipped.
# ---------------------------------------------------------------------------
TARBALL="$OUT_DIR/$DKA_ARTIFACT"
rm -f "$TARBALL"
TOPS=$(ls -A "$MERGED" | sort | tr '\n' ' ')

# -T4 rather than -T0: multi-threaded xz splits the input into blocks and the
# result depends on the thread count, so -T0 would make the digest a function
# of the runner's core count. -9 single-threaded over a gigabyte of toolchain
# is twenty minutes; this is a few.
# shellcheck disable=SC2086
XZ_OPT='-9 -T4' tar --sort=name --owner=0 --group=0 --numeric-owner --mtime=@0 \
    --hard-dereference -C "$MERGED" -cJf "$TARBALL" -- $TOPS

log "pack    $DKA_ARTIFACT ($(wc -c <"$TARBALL") bytes)"

# Check what was actually written rather than trusting the tar invocation. The
# hard-link assertion is the one that matters: it is the difference between a
# toolchain that installs and one that installs without a compiler driver.
tar -tvf "$TARBALL" >"$WORK/listing" || die "could not list $TARBALL"
hardlinks=$(grep -c '^h' "$WORK/listing" || true)
[ "$hardlinks" -eq 0 ] ||
  die "$DKA_ARTIFACT contains $hardlinks hard-link members; RotomLab's untar
skips them, so those files would be missing after install"
log "check   0 hard-link members (RotomLab's untar would skip them)"

CHECK="$WORK/check"
mkdir -p "$CHECK"
tar -C "$CHECK" -xf "$TARBALL" || die "could not extract the artifact we just wrote"
verify_devkitarm_tree "$CHECK" "$STRIP_PREFIX"
rm -rf "$CHECK" "$MERGED"

DKA_SHA=$(sha256_of "$TARBALL")
log "sha256  $DKA_ARTIFACT $DKA_SHA"

# ===========================================================================
# 2. busybox
# ===========================================================================
BB_VERSION=$(cfg '.mirrors.busybox.version')
BB_URL=$(cfg '.mirrors.busybox.url')
BB_SHA_WANT=$(cfg '.mirrors.busybox.sha256')
BB_SRC_URL=$(cfg '.mirrors.busybox.source_url')
BB_SRC_SHA_WANT=$(cfg '.mirrors.busybox.source_sha256')
check_pin "$BB_VERSION" "$BB_SHA_WANT" ".mirrors.busybox"
check_pin "$BB_VERSION" "$BB_SRC_SHA_WANT" ".mirrors.busybox source"

BB_ARTIFACT="busybox-$BB_VERSION-linux-amd64"
# Upstream's own tarball, republished byte-for-byte under its own name. The
# name is upstream's on purpose: this is not a repackaging, it is the
# corresponding source for the binary next to it, and a name of our invention
# would invite the question of what we changed. Nothing.
BB_SRC_ARTIFACT="busybox-$BB_VERSION.tar.bz2"

log "busybox $BB_VERSION"
fetch_verify "$BB_URL" "$BB_SHA_WANT" "$DL_DIR/$BB_ARTIFACT"
cp "$DL_DIR/$BB_ARTIFACT" "$OUT_DIR/$BB_ARTIFACT"
chmod 0755 "$OUT_DIR/$BB_ARTIFACT"

verify_busybox "$OUT_DIR/$BB_ARTIFACT"

# GPLv2 §3 gives no equivalent of GPLv3 §6(d): pointing at busybox.net is not
# an option the licence offers. The source travels with the binary, in the same
# release, verified against the same kind of pin as everything else.
log "busybox mirroring corresponding source (GPLv2-only: §6(d) has no v2 equivalent)"
fetch_verify "$BB_SRC_URL" "$BB_SRC_SHA_WANT" "$DL_DIR/$BB_SRC_ARTIFACT"
cp "$DL_DIR/$BB_SRC_ARTIFACT" "$OUT_DIR/$BB_SRC_ARTIFACT"

# It is the source, not a 404 page that happened to hash correctly — bunzip2
# reading it end to end is a cheap way to say so. Skipped rather than required
# if bzip2 is absent: the digest is the guarantee, this is the sanity check.
#
# The skip is announced. It was silent before, which is how the documented
# reproduction container came to omit bzip2 and drop this check without anyone
# noticing that the GPLv2 corresponding source was going out unopened.
if command -v bzip2 >/dev/null 2>&1; then
  bzip2 -t "$OUT_DIR/$BB_SRC_ARTIFACT" || die "the busybox source tarball is not valid bzip2"
  log "check   source tarball decompresses cleanly"
elif [ -n "${CI:-}" ]; then
  # In CI the environment is ours: Containerfile and every workflow install
  # bzip2, so its absence is a broken environment rather than someone running
  # this by hand on a minimal box. Nothing that publishes should skip the one
  # check that opens the GPLv2 corresponding source.
  die "bzip2 is not installed, but CI is set. This is the environment that
publishes; it must not skip the check that the busybox source is a readable
archive. Add bzip2 to the image (Containerfile has it)."
else
  warn "bzip2 is not installed, so $BB_SRC_ARTIFACT was NOT opened."
  warn "Its digest matches the pin, but nothing here confirmed it is a readable"
  warn "archive. Install bzip2 (Containerfile has it) to restore the check."
fi

BB_SHA=$(sha256_of "$OUT_DIR/$BB_ARTIFACT")
BB_SRC_SHA=$(sha256_of "$OUT_DIR/$BB_SRC_ARTIFACT")
# These must equal the pins: fetch_verify already checked the downloads, and
# this checks that the copy into out/ did not change them.
[ "$BB_SHA" = "$BB_SHA_WANT" ] || die "busybox binary digest changed on copy"
[ "$BB_SRC_SHA" = "$BB_SRC_SHA_WANT" ] || die "busybox source digest changed on copy"
log "sha256  $BB_ARTIFACT $BB_SHA"
log "sha256  $BB_SRC_ARTIFACT $BB_SRC_SHA"

# ===========================================================================
# 3. Report
# ===========================================================================
jq -cn \
  --arg dkaArtifact "$DKA_ARTIFACT" \
  --arg dkaSha      "$DKA_SHA" \
  --arg dkaVersion  "$DKA_VERSION" \
  --arg dkaPrefix   "$STRIP_PREFIX" \
  --arg bbArtifact  "$BB_ARTIFACT" \
  --arg bbSha       "$BB_SHA" \
  --arg bbVersion   "$BB_VERSION" \
  --arg bbSrc       "$BB_SRC_ARTIFACT" \
  --arg bbSrcSha    "$BB_SRC_SHA" \
  --arg applets     "$APPLETS" \
  '{
     devkitarm: {
       artifact:    $dkaArtifact,
       sha256:      $dkaSha,
       version:     $dkaVersion,
       kind:        "tar.xz",
       stripPrefix: $dkaPrefix
     },
     busybox: {
       artifact: $bbArtifact,
       sha256:   $bbSha,
       version:  $bbVersion,
       kind:     "raw",
       filename: "busybox",
       exec:     true,
       applets:  ($applets | split(" ")),
       source:   { artifact: $bbSrc, sha256: $bbSrcSha }
     }
   }'
