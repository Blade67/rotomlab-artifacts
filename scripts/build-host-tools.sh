#!/bin/sh
# build-host-tools.sh <decomp-name>
#
# Builds one decomp's own host build tools — preproc, gbagfx, scaninc and the
# rest — statically under musl, and packages them as the artifact RotomLab
# downloads on first run.
#
# This script is what removes the host C compiler requirement from users'
# machines. RotomLab invokes the decomp build with TOOL_NAMES= empty, which
# stops make compiling these tools, and provisions these prebuilt ones into
# tools/<name>/<name> instead. If this produces the wrong thing, the app has no
# fallback: there is no compiler on the user's machine to build them with.
#
# Output, under out/:
#   <game>-hosttools-<version>-linux-amd64.tar.xz
# and one JSON line on stdout carrying everything a manifest entry needs:
#   {"game","artifact","sha256","toolsHash","commit","tools"}
#
# Everything else this script prints goes to stderr, so stdout is exactly that
# one line and can be piped straight into jq.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

BUILD_JSON="${BUILD_JSON:-$ROOT/build.json}"
export BUILD_JSON
. "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<'EOF'
usage: build-host-tools.sh <decomp-name>

  <decomp-name> is a key under .decomps in build.json (pokeemerald,
  pokefirered, pokeruby). The artifact is named after games[0].

environment:
  OUT_DIR             where to write the artifact (default: <repo>/out)
  HOSTTOOLS_VERSION   version string in the artifact name
                      (default: the pinned commit, abbreviated)
EOF
  exit 2
}

DECOMP=${1:-}
[ -n "$DECOMP" ] || usage
[ $# -eq 1 ] || usage

# The name is interpolated into a jq filter below, so it is constrained to
# something that cannot carry filter syntax. It also catches a typo'd argument
# with a clear message instead of a jq parse error.
case "$DECOMP" in
  *[!A-Za-z0-9._-]*|'') die "not a valid decomp name: $DECOMP" ;;
esac

need git make gcc g++ file jq tar xz sed sha256sum go

OUT_DIR="${OUT_DIR:-$ROOT/out}"

REPO=$(cfg ".decomps.\"$DECOMP\".repo")
COMMIT=$(cfg ".decomps.\"$DECOMP\".commit")
GAME=$(cfg ".decomps.\"$DECOMP\".games[0]")

# A short commit is a fine pin; a wrong-length one usually means the value was
# truncated on the way into build.json, and every check below would then be
# comparing against the wrong thing.
case "$COMMIT" in
  ????????????????????????????????????????) : ;;
  *) die "build.json: .decomps.$DECOMP.commit is not a 40-character SHA: $COMMIT" ;;
esac
case "$COMMIT" in
  *[!0-9a-f]*) die "build.json: .decomps.$DECOMP.commit is not lowercase hex: $COMMIT" ;;
esac

# The game name becomes the artifact filename and, through the manifest, part
# of a URL. Held to the same shape as the decomp name so neither can be reached
# by anything build.json does not already say.
case "$GAME" in
  *[!A-Za-z0-9._-]*|'') die "build.json: .decomps.$DECOMP.games[0] is not filename-safe: $GAME" ;;
esac

# The version identifies the artifact's contents, which are determined entirely
# by the pinned commit — nothing else in this script varies. Naming it after
# the commit is therefore truthful, and it keeps the decomp-commit ->
# hosttools-artifact pairing legible from the filename alone, which the design
# requires to be pinned as a pair and never independently.
VERSION="${HOSTTOOLS_VERSION:-$(printf '%s' "$COMMIT" | cut -c1-7)}"
case "$VERSION" in
  *[!A-Za-z0-9._-]*|'') die "HOSTTOOLS_VERSION is not filename-safe: $VERSION" ;;
esac

ARTIFACT="$GAME-hosttools-$VERSION-linux-amd64.tar.xz"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM
SRC="$WORK/src"

log "$DECOMP -> $GAME ($ARTIFACT)"

# ---------------------------------------------------------------------------
# 1. Clone at the pinned commit
#
# `git clone --depth 1` lands on the default branch tip, not on the pin, so the
# shallow clone is assembled by hand: fetch the one commit by its SHA, which
# GitHub allows, and check that object out. Whichever route got us there, HEAD
# is compared against the pin afterwards. Silently building the wrong commit
# would poison the toolsHash, the binaries and the manifest entry together, and
# nothing downstream would notice.
# ---------------------------------------------------------------------------
log "clone   $REPO @ $COMMIT"
mkdir -p "$SRC"
git -C "$SRC" init -q
git -C "$SRC" config advice.detachedHead false
git -C "$SRC" remote add origin "$REPO"

if git -C "$SRC" fetch --quiet --depth 1 origin "$COMMIT" 2>/dev/null; then
  git -C "$SRC" checkout -q --detach FETCH_HEAD
else
  # Servers with uploadpack.allowAnySHA1InWant disabled refuse a fetch by SHA.
  # Falling back costs history we do not want, but a slow correct clone beats a
  # fast wrong one.
  warn "server refused a shallow fetch of $COMMIT; falling back to a full clone"
  git -C "$SRC" fetch --quiet origin
  git -C "$SRC" checkout -q --detach "$COMMIT"
fi

HEAD=$(git -C "$SRC" rev-parse HEAD)
[ "$HEAD" = "$COMMIT" ] || die "checkout landed on the wrong commit
  pinned $COMMIT
  got    $HEAD"
log "at      $HEAD (verified against the pin)"

# ---------------------------------------------------------------------------
# 2. Read TOOL_NAMES from upstream
#
# Never hardcoded. All three repos ship a byte-identical make_tools.mk today,
# but the list is upstream's to change and a hardcoded copy would drift
# silently — publishing an artifact missing a tool the build needs.
# ---------------------------------------------------------------------------
MK="$SRC/make_tools.mk"
[ -f "$MK" ] || die "no make_tools.mk in $DECOMP@$COMMIT"

TOOL_LINE=$(sed -n 's/^TOOL_NAMES *:*= *//p' "$MK" | tr -d '\r')
[ -n "$TOOL_LINE" ] || die "could not read TOOL_NAMES from $MK"
[ "$(printf '%s\n' "$TOOL_LINE" | wc -l)" -eq 1 ] ||
  die "make_tools.mk defines TOOL_NAMES more than once; refusing to guess which wins"
case "$TOOL_LINE" in
  # A continued assignment would be silently truncated to its first line, and
  # the missing tools would only show up as a broken build on a user's machine.
  *\\) die "TOOL_NAMES in $MK is a line continuation; this script only reads one line" ;;
esac

# Normalise whitespace by round-tripping through word splitting, so the JSON
# tools array can be produced with a plain split on single spaces.
# shellcheck disable=SC2086
set -- $TOOL_LINE
TOOL_NAMES="$*"
TOOL_COUNT=$#
[ "$TOOL_COUNT" -gt 0 ] || die "TOOL_NAMES is empty in $MK"
log "tools   $TOOL_COUNT: $TOOL_NAMES"

# ---------------------------------------------------------------------------
# 2b. The parsed list must equal the directories it claims to describe
#
# Every check downstream of the parse above derives from the parse: the build
# loop, the staged count, the extracted count, and the workflow's
# `.tools | length`. They therefore agree with each other by construction —
# and would agree just as contentedly on a list that is too short. The sed
# matches `TOOL_NAMES :=` and `TOOL_NAMES =`; a second assignment spelled
# `TOOL_NAMES += foo` matches nothing, contains no continuation, and defines
# TOOL_NAMES no second time, so every guard above lets it through and the tool
# is silently never built. toolsHash does not catch it either: that hashes the
# sources under tools/, not the list of tools compiled from them. The failure
# would reach a user as one missing binary, thousands of lines into a build.
#
# So the list is checked against something outside itself: the tree it
# describes. Set equality in both directions — a directory with no TOOL_NAMES
# entry is a tool that would not be built, and a TOOL_NAMES entry with no
# directory is a name that cannot be.
#
# tools/agbcc is excluded on both sides. It is a separate pret repository,
# cloned into tools/agbcc only for matching builds, deliberately absent from
# TOOL_NAMES upstream, and excluded from toolsHash for the same reason. Only
# directories are compared: TOOL_NAMES names directories to run make in, and a
# stray regular file in tools/ is not one.
#
# Verified against all three pinned commits: tools/ holds exactly the eleven
# directories TOOL_NAMES lists, no files and no agbcc.
# ---------------------------------------------------------------------------
[ -d "$SRC/tools" ] || die "no tools/ directory in $DECOMP@$COMMIT"
( cd "$SRC/tools" && find . -mindepth 1 -maxdepth 1 -type d ) |
  sed 's|^\./||' | grep -vx agbcc | sort >"$WORK/tools-dirs"
# shellcheck disable=SC2086
printf '%s\n' $TOOL_NAMES | sort >"$WORK/tool-names"

unlisted=$(grep -vxF -f "$WORK/tool-names" "$WORK/tools-dirs" || true)
undirected=$(grep -vxF -f "$WORK/tools-dirs" "$WORK/tool-names" || true)
if [ -n "$unlisted" ] || [ -n "$undirected" ]; then
  die "TOOL_NAMES does not match the directories under tools/ in $DECOMP@$COMMIT.
The parse of $MK and every count derived from it agree with each other, so this
is the only check that can see the difference.
  in tools/ but not in TOOL_NAMES (would never be built):$(printf ' %s' $unlisted)
  in TOOL_NAMES but not in tools/ (cannot be built):$(printf ' %s' $undirected)
  parsed TOOL_NAMES: $TOOL_NAMES
If upstream really did add a tool through a second assignment, this script has
to learn to read it — not have the assertion relaxed."
fi
log "check   TOOL_NAMES equals the $TOOL_COUNT directories under tools/ (agbcc excluded)"

# ---------------------------------------------------------------------------
# 3. toolsHash, on the pristine tree, BEFORE building anything
#
# This ordering is the whole reason the steps are numbered. Every pret tool
# Makefile compiles its sources to a binary *inside the tool's own directory*,
# so hashing after the build would fingerprint a tree containing eleven
# binaries that a user's pristine clone does not have. The published hash could
# then never equal the value the app computes for a fork — for every project,
# silently — surfacing much later as universal custom-source rejection with no
# obvious cause.
# ---------------------------------------------------------------------------
log "hash    computing toolsHash on the pristine tree"
# Built rather than `go run` because tools-hash is its own module: `go run
# ./tools-hash` from the repo root has no module to resolve against.
#
# -buildvcs=false because go build otherwise stamps the enclosing repository's
# git state into the binary, and reading that git state fails outright when the
# checkout is owned by a different uid than the build — exactly the case inside
# a container with the repo bind-mounted. Nothing reads the stamp; this is a
# throwaway helper, and its provenance is the commit this script lives in.
GOTOOLCHAIN=local go build -C "$ROOT/tools-hash" -buildvcs=false -o "$WORK/tools-hash" . ||
  die "could not build tools-hash"
TOOLS_HASH=$("$WORK/tools-hash" "$SRC")
[ -n "$TOOLS_HASH" ] || die "tools-hash produced no output"
log "hash    $TOOLS_HASH"

# ---------------------------------------------------------------------------
# 4/5. Build each tool statically, and verify the linkage rather than assume it
#
# CC and CXX, never CFLAGS: gbagfx and rsfont assign `CFLAGS =` unconditionally,
# so a command-line CFLAGS override silently drops -DPNG_SKIP_SETJMP_CHECK and
# -std=c11. `CC ?= gcc` makes CC the safe lever.
# ---------------------------------------------------------------------------
for t in $TOOL_NAMES; do
  [ -d "$SRC/tools/$t" ] || die "TOOL_NAMES lists $t but there is no tools/$t"

  if ! make -C "$SRC/tools/$t" CC="gcc -static" CXX="g++ -static" \
       >"$WORK/$t.log" 2>&1; then
    sed 's/^/    | /' "$WORK/$t.log" >&2
    die "tools/$t failed to build"
  fi

  bin="$SRC/tools/$t/$t"
  [ -f "$bin" ] || die "tools/$t built but produced no binary at tools/$t/$t
  produced: $(ls "$SRC/tools/$t")"

  # Passing -static does not guarantee it took effect. A dynamically linked
  # binary works here and fails on users' machines.
  require_static "$bin"
  log "build   $t ok (static)"
done

# ---------------------------------------------------------------------------
# 6. Flatten
#
# hosttools.Provision expects a *flat* directory of binaries named after the
# tools: it skips directory entries, then reports "contains no binaries" for a
# directory-of-directories. Publishing the unflattened tree produces exactly
# that error at every user's first run, pointing at the wrong thing.
# ---------------------------------------------------------------------------
STAGE="$OUT_DIR/staging/$GAME"
# Emptied rather than merged: building several decomps into one out/ would
# otherwise let the previous decomp's binaries ride along in this tarball.
rm -rf "$STAGE"
mkdir -p "$STAGE"
for t in $TOOL_NAMES; do
  cp "$SRC/tools/$t/$t" "$STAGE/$t"
  chmod 0755 "$STAGE/$t"
done
log "flatten $TOOL_COUNT binaries -> $STAGE"

# ---------------------------------------------------------------------------
# 7. Verify the staging directory is exactly what was asked for
# ---------------------------------------------------------------------------
for t in $TOOL_NAMES; do
  [ -f "$STAGE/$t" ] || die "$t missing from the staged artifact"
  [ -x "$STAGE/$t" ] || die "$t is not executable in the staged artifact"
done
staged=$(find "$STAGE" -mindepth 1 | wc -l)
[ "$staged" -eq "$TOOL_COUNT" ] ||
  die "staged artifact holds $staged entries, expected exactly $TOOL_COUNT:
$(find "$STAGE" -mindepth 1)"

# ---------------------------------------------------------------------------
# 8. Package, digest, report
# ---------------------------------------------------------------------------
mkdir -p "$OUT_DIR"
TARBALL="$OUT_DIR/$ARTIFACT"
rm -f "$TARBALL"

# Members are named explicitly and the metadata is pinned, so the archive is a
# function of the binaries alone: no "." entry, no build timestamps, no runner
# uid. Two runs of the same pin produce the same bytes.
# shellcheck disable=SC2086
XZ_OPT=-9 tar --sort=name --owner=0 --group=0 --numeric-owner --mtime=@0 \
    -C "$STAGE" -cJf "$TARBALL" -- $TOOL_NAMES

# Extract what was actually written and check its shape, rather than trusting
# that the tar invocation meant what it said. This is the check that catches a
# directory-of-directories before users do.
CHECK="$WORK/check"
mkdir -p "$CHECK"
tar -C "$CHECK" -xf "$TARBALL"
for t in $TOOL_NAMES; do
  [ -f "$CHECK/$t" ] || die "packaged artifact has no regular file $t at its root"
  [ -x "$CHECK/$t" ] || die "packaged artifact entry $t is not executable"
done
extracted=$(find "$CHECK" -mindepth 1 | wc -l)
[ "$extracted" -eq "$TOOL_COUNT" ] ||
  die "packaged artifact extracts to $extracted entries, expected $TOOL_COUNT:
$(find "$CHECK" -mindepth 1)"
require_static $(find "$CHECK" -mindepth 1 -type f)
log "pack    $ARTIFACT ($(wc -c <"$TARBALL") bytes, $TOOL_COUNT flat static binaries)"

SHA=$(sha256_of "$TARBALL")
log "sha256  $SHA"

jq -cn \
  --arg game "$GAME" \
  --arg artifact "$ARTIFACT" \
  --arg sha256 "$SHA" \
  --arg toolsHash "$TOOLS_HASH" \
  --arg commit "$COMMIT" \
  --arg tools "$TOOL_NAMES" \
  '{
     game:      $game,
     artifact:  $artifact,
     sha256:    $sha256,
     toolsHash: $toolsHash,
     commit:    $commit,
     tools:     ($tools | split(" "))
   }'
