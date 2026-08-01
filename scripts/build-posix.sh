#!/bin/sh
# build-posix.sh
#
# Builds the vendored POSIX layer: a static GNU make and a static GNU bash.
#
# This is what lets RotomLab run a pret decomp's *real* Makefile on a machine
# with no MSYS2, no developer shell and no system make. The pair ships with the
# app and goes on PATH ahead of whatever the host happens to have.
#
# bash specifically, and not busybox ash: all three decomps open with
#
#     SHELL := bash -o pipefail                 pokeemerald, pokefirered
#     SHELL := /bin/bash -o pipefail            pokeruby
#
# ash has no `pipefail`, so substituting it makes the shell reject its own
# invocation and every recipe line fails before it runs. A real bash is
# therefore a hard requirement of the design, and `-o pipefail` actually
# *working* — not merely being accepted — is the property the whole decision
# rests on. That is why the checks below run the flag for its effect rather
# than grep for it in --help.
#
# Note for whoever wires up the invocation: pokeruby's absolute /bin/bash
# bypasses PATH, so shipping this bash and putting it on PATH satisfies
# pokeemerald and pokefirered but NOT pokeruby — that one needs SHELL
# overridden on the make command line, or the makefile patched. Verified
# against all three pinned commits, top-level and included .mk files alike;
# no other file sets SHELL, and none uses make's `load` directive (which is
# why --disable-load below costs nothing).
#
# Output, under out/:
#   make-<version>-linux-amd64
#   bash-<version>-linux-amd64
# and one JSON line on stdout:
#   {"make":{"artifact","sha256","version"},"bash":{...}}
#
# Everything else goes to stderr, so stdout is exactly that line and can be
# piped straight into jq.
#
# VERIFY_ONLY=1 build-posix.sh <make> <bash> skips the build and runs only the
# functional checks against two existing binaries. CI uses it to re-run the
# identical assertions on a glibc host against the downloaded artifacts, so the
# two sides cannot drift apart.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

BUILD_JSON="${BUILD_JSON:-$ROOT/build.json}"
export BUILD_JSON
. "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<'EOF'
usage: build-posix.sh
       VERIFY_ONLY=1 build-posix.sh <make-binary> <bash-binary>

  Takes no arguments when building. Versions, URLs and digests all come from
  build.json; nothing is fetched that is not pinned there.

environment:
  OUT_DIR      where to write the binaries (default: <repo>/out)
  DL_DIR       where to cache verified tarballs (default: $OUT_DIR/dl)
  VERIFY_ONLY  1 to only run the functional checks on two existing binaries
EOF
  exit 2
}

TAB=$(printf '\t')

# ---------------------------------------------------------------------------
# Functional verification
#
# Linkage is necessary and nowhere near sufficient. A bash that starts, accepts
# -o pipefail and then ignores it would pass a naive check and break every
# decomp build in a way that surfaces as a compiler error three thousand lines
# into a log, nowhere near its cause. So the flag is exercised for its effect,
# in both directions, and then through make.
# ---------------------------------------------------------------------------
verify_posix() {
  vmake=$1; vbash=$2
  [ -x "$vmake" ] || die "not executable: $vmake"
  [ -x "$vbash" ] || die "not executable: $vbash"

  # -- bash runs at all -----------------------------------------------------
  "$vbash" --version >/dev/null 2>&1 || die "bash --version failed"
  log "check   bash --version: $("$vbash" --version | head -n1)"

  out=$("$vbash" -c 'echo hi') || die "bash -c 'echo hi' failed"
  [ "$out" = "hi" ] || die "bash -c 'echo hi' printed '$out', expected 'hi'"
  log "check   bash -c 'echo hi' -> $out"

  # -- the flag is accepted -------------------------------------------------
  "$vbash" -o pipefail -c 'true' || die "bash rejected -o pipefail"
  log "check   bash -o pipefail -c true accepted"

  # -- and, far more importantly, it does something -------------------------
  #
  # `false | true` exits 0 under default POSIX semantics — a pipeline's status
  # is its last command's — and non-zero under pipefail. Both directions are
  # asserted: a shell that failed every pipeline would satisfy the first check
  # alone and be just as wrong.
  st=0
  "$vbash" -o pipefail -c 'false | true' || st=$?
  [ "$st" -ne 0 ] ||
    die "bash accepts -o pipefail but ignores it: 'false | true' exited 0"
  log "check   pipefail on:  'false | true' -> exit $st (non-zero, correct)"

  st=0
  "$vbash" -c 'false | true' || st=$?
  [ "$st" -eq 0 ] ||
    die "without pipefail, 'false | true' must exit 0; this bash exited $st"
  log "check   pipefail off: 'false | true' -> exit $st (correct)"

  # `set -o pipefail` mid-script: the other spelling, and the one a recipe
  # would use if it set the option itself.
  st=0
  "$vbash" -c 'set -o pipefail; false | true' || st=$?
  [ "$st" -ne 0 ] || die "bash ignores 'set -o pipefail'"
  log "check   set -o pipefail inside a script also takes effect (exit $st)"

  # -- make runs at all -----------------------------------------------------
  "$vmake" --version >/dev/null 2>&1 || die "make --version failed"
  log "check   make --version: $("$vmake" --version | head -n1)"

  # -- the combination the decomps actually depend on -----------------------
  #
  # make, our bash, and `SHELL := bash -o pipefail` working together, exactly
  # as the pret Makefiles open. The first target also proves make is running
  # *our* bash and not /bin/sh: $BASH_VERSION comes back empty under dash or
  # ash, so an empty suffix fails the check.
  #
  # Written with printf rather than a heredoc so the recipe prefix is
  # unambiguously a tab; a heredoc that lost its tab to an editor would fail
  # here for a reason that has nothing to do with what is being tested.
  t=$(mktemp -d)
  {
    printf 'SHELL := %s -o pipefail\n\n' "$vbash"
    printf 'which-shell:\n%s@echo "shell-is-bash-$$BASH_VERSION"\n\n' "$TAB"
    printf 'pipeline-ok:\n%s@echo emerald | cat\n\n' "$TAB"
    printf 'pipeline-fails:\n%s@false | true\n' "$TAB"
  } >"$t/Makefile"

  got=$("$vmake" -C "$t" --no-print-directory which-shell) ||
    die "make could not run a recipe with SHELL := $vbash -o pipefail"
  case "$got" in
    shell-is-bash-?*) : ;;
    *) die "make is not running our bash; the recipe printed '$got'" ;;
  esac
  log "check   make + 'SHELL := bash -o pipefail' -> $got"

  got=$("$vmake" -C "$t" --no-print-directory pipeline-ok) ||
    die "make failed on a passing pipeline under pipefail"
  [ "$got" = "emerald" ] || die "pipeline-ok printed '$got', expected 'emerald'"
  log "check   make runs a passing pipeline under pipefail -> $got"

  # The payoff. Under a shell whose pipefail does not reach recipes this target
  # *succeeds*, and the equivalent failure in a real decomp build would be
  # swallowed instead of stopping it.
  st=0
  "$vmake" -C "$t" --no-print-directory pipeline-fails >/dev/null 2>&1 || st=$?
  [ "$st" -ne 0 ] ||
    die "make did not fail on 'false | true' — pipefail is not reaching recipes"
  log "check   make fails a broken pipeline under pipefail (exit $st) — the point of all this"

  rm -rf "$t"
}

# ---------------------------------------------------------------------------
# VERIFY_ONLY: check two binaries someone else built, and stop.
# ---------------------------------------------------------------------------
if [ "${VERIFY_ONLY:-}" = 1 ]; then
  [ $# -eq 2 ] || usage
  need file sha256sum
  require_static "$1" "$2"
  log "static  $1: $(file -b "$1")"
  log "static  $2: $(file -b "$2")"
  verify_posix "$1" "$2"
  log "ok      both binaries pass every functional check on this host"
  exit 0
fi

[ $# -eq 0 ] || usage

need curl jq file tar gzip sed sha256sum make gcc strip

OUT_DIR="${OUT_DIR:-$ROOT/out}"
DL_DIR="${DL_DIR:-$OUT_DIR/dl}"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

JOBS=$(nproc 2>/dev/null || echo 2)

# read_pin <name> — pull version/url/sha256 out of build.json. The version
# becomes part of a filename and, through the manifest, part of a URL, so it is
# held to the same shape as everything else that crosses that boundary.
read_pin() {
  _n=$1
  VERSION=$(cfg ".posix.\"$_n\".version")
  URL=$(cfg ".posix.\"$_n\".url")
  SHA=$(cfg ".posix.\"$_n\".sha256")
  case "$VERSION" in
    *[!A-Za-z0-9._-]*|'') die "build.json: .posix.$_n.version is not filename-safe: $VERSION" ;;
  esac
  case "$SHA" in
    ????????????????????????????????????????????????????????????????) : ;;
    *) die "build.json: .posix.$_n.sha256 is not a 64-character digest: $SHA" ;;
  esac
  case "$SHA" in
    *[!0-9a-f]*) die "build.json: .posix.$_n.sha256 is not lowercase hex: $SHA" ;;
  esac
}

# unpack <tarball> <expected-dir> — extract, then confirm the tree we expected
# is what actually came out, rather than cd-ing into a directory that may not
# be there and building whatever else happens to be lying around.
unpack() {
  tar -C "$WORK" -xzf "$1" || die "could not extract $1"
  [ -d "$2" ] || die "$1 did not unpack to $2
  produced: $(ls "$WORK")"
}

mkdir -p "$OUT_DIR" "$DL_DIR"

# ---------------------------------------------------------------------------
# 1. make
#
# --disable-load drops the `load` directive, which needs dlopen; a statically
#   linked dlopen is a fiction on musl and no pret makefile uses `load`.
# --without-guile keeps the optional Guile embedding out — it would be a
#   dynamic dependency bought for nothing.
# LDFLAGS=-static goes on configure, not on the build line, so configure's own
#   link tests run under the flags the real link will use. Passing it only at
#   build time lets configure conclude things about a dynamic link that are not
#   true of a static one.
# ---------------------------------------------------------------------------
read_pin make
MAKE_VERSION=$VERSION
MAKE_SRC="$WORK/make-$MAKE_VERSION"
MAKE_ARTIFACT="make-$MAKE_VERSION-linux-amd64"

log "make    $MAKE_VERSION"
fetch_verify "$URL" "$SHA" "$DL_DIR/make-$MAKE_VERSION.tar.gz"
unpack "$DL_DIR/make-$MAKE_VERSION.tar.gz" "$MAKE_SRC"

(
  cd "$MAKE_SRC"
  ./configure --disable-nls --disable-load --without-guile \
              CFLAGS="-O2" LDFLAGS="-static"
  make -j"$JOBS"
) >"$WORK/make.log" 2>&1 || {
  sed 's/^/    | /' "$WORK/make.log" >&2
  die "make $MAKE_VERSION failed to build"
}

[ -f "$MAKE_SRC/make" ] || die "make built but produced no binary at $MAKE_SRC/make"
strip "$MAKE_SRC/make"
cp "$MAKE_SRC/make" "$OUT_DIR/$MAKE_ARTIFACT"
chmod 0755 "$OUT_DIR/$MAKE_ARTIFACT"
# Passing -static does not guarantee it took effect: a dynamically linked
# binary works fine here and fails on a user's machine.
require_static "$OUT_DIR/$MAKE_ARTIFACT"
log "make    $(file -b "$OUT_DIR/$MAKE_ARTIFACT")"

# ---------------------------------------------------------------------------
# 2. bash
#
# --without-bash-malloc is mandatory on musl: bash's bundled allocator assumes
#   glibc-ish behaviour and misbehaves otherwise. Alpine's own bash package
#   passes it for the same reason.
# --disable-readline/--disable-history because this bash exists to be SHELL for
#   a Makefile — non-interactive, no terminal. Readline drags in a terminfo
#   library purely to be dead weight, and statically linking ncurses is one
#   more failure mode bought for a feature nothing here invokes.
# --enable-static-link is bash's own switch for this; it sets static flags in
#   places a bare LDFLAGS does not reach. Both are passed, and the result is
#   checked rather than assumed.
# ---------------------------------------------------------------------------
read_pin bash
BASH_PIN=$VERSION
BASH_SRC="$WORK/bash-$BASH_PIN"
BASH_ARTIFACT="bash-$BASH_PIN-linux-amd64"

log "bash    $BASH_PIN"
fetch_verify "$URL" "$SHA" "$DL_DIR/bash-$BASH_PIN.tar.gz"
unpack "$DL_DIR/bash-$BASH_PIN.tar.gz" "$BASH_SRC"

(
  cd "$BASH_SRC"
  ./configure --without-bash-malloc --disable-nls \
              --disable-readline --disable-history \
              --enable-static-link \
              CFLAGS="-O2" LDFLAGS="-static"
  make -j"$JOBS"
) >"$WORK/bash.log" 2>&1 || {
  sed 's/^/    | /' "$WORK/bash.log" >&2
  die "bash $BASH_PIN failed to build"
}

[ -f "$BASH_SRC/bash" ] || die "bash built but produced no binary at $BASH_SRC/bash"
strip "$BASH_SRC/bash"
cp "$BASH_SRC/bash" "$OUT_DIR/$BASH_ARTIFACT"
chmod 0755 "$OUT_DIR/$BASH_ARTIFACT"
require_static "$OUT_DIR/$BASH_ARTIFACT"
log "bash    $(file -b "$OUT_DIR/$BASH_ARTIFACT")"

# ---------------------------------------------------------------------------
# 3. Verify what was built, on the box that built it
# ---------------------------------------------------------------------------
verify_posix "$OUT_DIR/$MAKE_ARTIFACT" "$OUT_DIR/$BASH_ARTIFACT"

# ---------------------------------------------------------------------------
# 4. Report
# ---------------------------------------------------------------------------
MAKE_SHA=$(sha256_of "$OUT_DIR/$MAKE_ARTIFACT")
BASH_SHA=$(sha256_of "$OUT_DIR/$BASH_ARTIFACT")
log "sha256  $MAKE_ARTIFACT $MAKE_SHA"
log "sha256  $BASH_ARTIFACT $BASH_SHA"

jq -cn \
  --arg makeArtifact "$MAKE_ARTIFACT" \
  --arg makeSha      "$MAKE_SHA" \
  --arg makeVersion  "$MAKE_VERSION" \
  --arg bashArtifact "$BASH_ARTIFACT" \
  --arg bashSha      "$BASH_SHA" \
  --arg bashVersion  "$BASH_PIN" \
  '{
     make: { artifact: $makeArtifact, sha256: $makeSha, version: $makeVersion },
     bash: { artifact: $bashArtifact, sha256: $bashSha, version: $bashVersion }
   }'
