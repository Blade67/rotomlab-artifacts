#!/bin/sh
# emit-fragment.sh
#
# Assembles manifest-fragment.json from the JSON lines the build scripts emit,
# and — given a RotomLab checkout — proves the result parses by running
# RotomLab's own parser over it.
#
# ---------------------------------------------------------------------------
# Why a patch and not a replacement embedded.json
# ---------------------------------------------------------------------------
# The fragment carries only what this pipeline produces: release URLs, digests,
# the pinned decomp repo and commit, and toolsHash. It carries none of
# makeTargets, romNames, the human-readable game names, or busybox's applet
# list, because none of those are outputs of anything here — they are facts
# about the decomps and about RotomLab, they live in embedded.json, and they
# change on RotomLab's schedule rather than on a release's.
#
# A full replacement would mean this repository keeping a second copy of them.
# The copy would be right on the day it was written, and the first time someone
# fixed a ROM name in RotomLab it would start quietly reverting that fix on
# every release — a regression introduced by pasting, which is the failure mode
# hardest to attribute back to a paste. LeafGreen's ROM is pokeleafgreen.gba
# and not pokefirered-anything, and RotomLab has a dedicated test pinning that;
# a stale copy here would be exactly the sort of thing to get it wrong.
#
# The cost of a patch is that it has to be applied rather than dropped in, and
# that a merge is silent about a key it did not land on. The merge itself is
# one documented jq invocation; the silence is what the checks below exist to
# break.
#
# ---------------------------------------------------------------------------
# Why those checks are positive, and what replaced the one that used to be here
# ---------------------------------------------------------------------------
# This header used to claim that "no TODO placeholder survives the merge" is
# what makes the patch safe: embedded.json shipped every unpublished URL,
# digest and commit as a TODO, so a field the fragment failed to reach stayed
# reading TODO and the check fired.
#
# That was true for exactly one release. embedded.json now carries real values
# for every one of those fields, so nothing in it reads TODO and the check can
# never fire again — it is a guard over a condition that no longer occurs. A
# reviewer demonstrated the hole: move a decomp pin in build.json, omit that
# decomp's --hosttools input, run the command below. Exit 0, every check OK,
# `go test -run Embedded` green — and ruby and sapphire still on the PREVIOUS
# release's URL, commit and toolsHash, silently, in a manifest whose tag
# advertises the new pin set.
#
# The absence check is kept (a genuinely new TODO field would still be caught)
# but it is no longer load-bearing and must not be read as if it were. What
# carries the weight now are three positive assertions — each states something
# that must be TRUE of the merged manifest, so each one keeps failing as the
# manifest fills in rather than going quiet:
#
#   1. Every game build.json pins is covered by a --hosttools input. This is
#      the omission itself, caught before a byte of the fragment is written and
#      without needing a RotomLab checkout to notice.
#   2. Every artifact URL in the MERGED manifest points into this release. The
#      fragment satisfies that trivially — it is the merged file that matters,
#      because an entry the fragment never landed on keeps the old release's
#      URL and looks perfectly well formed.
#   3. Every game in the merged manifest carries the triple this run emitted:
#      commit, hostTools ID and toolsHash all identical to the fragment's. A
#      game that kept its old values fails here even if some other path had
#      refreshed its URL.
#
# ---------------------------------------------------------------------------
# The triple
# ---------------------------------------------------------------------------
# decomp.commit, the host-tools artifact, and toolsHash are emitted together
# from the same JSON line, and the commit in that line is checked against
# build.json's pin before anything is written. They describe one clone: the
# tools were built from that commit and the hash was computed over that tree.
# Pinning them independently — the commit copied by hand, the URL from a
# release page — is the one arrangement that can desynchronise, and the symptom
# would be RotomLab rejecting every custom source tree as non-pristine, for
# every project, with nothing pointing at the manifest.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

BUILD_JSON="${BUILD_JSON:-$ROOT/build.json}"
export BUILD_JSON
. "$SCRIPT_DIR/lib.sh"

# The manifest platform key: RotomLab's platform.Key() is GOOS + "-" + GOARCH,
# and everything this repository publishes is linux/amd64.
PLATFORM=linux-amd64

usage() {
  cat >&2 <<'EOF'
usage: emit-fragment.sh --tag <release-tag>
                        --hosttools <file> [--hosttools <file>]...
                        --posix <file> --mirror <file>
                        [--base-url <url>] [--out <file>]
                        [--validate-against <rotomlab-checkout>]

  <file> arguments are the JSON lines written by build-host-tools.sh,
  build-posix.sh and mirror.sh.

  --tag              the release the artifacts are published under; asset URLs
                     are built from it
  --base-url         override the derived asset URL prefix (no trailing slash)
  --out              where to write the fragment
                     (default: <OUT_DIR>/manifest-fragment.json)
  --validate-against merge the fragment into that checkout's embedded.json and
                     run its own `go test ./internal/manifest/ -run Embedded`.
                     The checkout is never modified: the merge is applied to a
                     throwaway `git archive HEAD` export of it.

environment:
  OUT_DIR            default output directory (default: <repo>/out)
  GITHUB_REPOSITORY  owner/name used to derive --base-url
  GITHUB_SERVER_URL  server used to derive --base-url
EOF
  exit 2
}

TAG=
BASE_URL=
POSIX_JSON=
MIRROR_JSON=
HOSTTOOLS_JSON=
OUT_FILE=
VALIDATE_AGAINST=

while [ $# -gt 0 ]; do
  case "$1" in
    --tag)              [ $# -ge 2 ] || usage; TAG=$2; shift 2 ;;
    --base-url)         [ $# -ge 2 ] || usage; BASE_URL=$2; shift 2 ;;
    --posix)            [ $# -ge 2 ] || usage; POSIX_JSON=$2; shift 2 ;;
    --mirror)           [ $# -ge 2 ] || usage; MIRROR_JSON=$2; shift 2 ;;
    --hosttools)        [ $# -ge 2 ] || usage
                        HOSTTOOLS_JSON="$HOSTTOOLS_JSON $2"; shift 2 ;;
    --out)              [ $# -ge 2 ] || usage; OUT_FILE=$2; shift 2 ;;
    --validate-against) [ $# -ge 2 ] || usage; VALIDATE_AGAINST=$2; shift 2 ;;
    -h|--help)          usage ;;
    *) die "unknown argument: $1" ;;
  esac
done

need jq sha256sum

[ -n "$POSIX_JSON" ]     || die "--posix is required"
[ -n "$MIRROR_JSON" ]    || die "--mirror is required"
[ -n "$HOSTTOOLS_JSON" ] || die "at least one --hosttools is required"
for f in $POSIX_JSON $MIRROR_JSON $HOSTTOOLS_JSON; do
  [ -f "$f" ] || die "no such file: $f"
  jq -e . "$f" >/dev/null 2>&1 || die "not valid JSON: $f"
done

if [ -z "$BASE_URL" ]; then
  [ -n "$TAG" ] || die "--tag is required unless --base-url is given"
  # Release tags become part of a URL. Held to the same shape as everything
  # else that crosses that boundary. A leading '-' is made of legal characters
  # but is read as a flag by everything that later handles the tag, and '.' and
  # '..' are legal ref-name characters that are illegal ref names.
  case "$TAG" in
    -*|.|..|*[!A-Za-z0-9._-]*|'') die "release tag is not a safe URL and ref name: $TAG" ;;
  esac
  BASE_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-Blade67/rotomlab-artifacts}/releases/download/$TAG"
fi
case "$BASE_URL" in
  https://*) : ;;
  *) die "asset base URL is not https: $BASE_URL" ;;
esac
BASE_URL=${BASE_URL%/}

OUT_DIR="${OUT_DIR:-$ROOT/out}"
OUT_FILE="${OUT_FILE:-$OUT_DIR/manifest-fragment.json}"
mkdir -p "$(dirname "$OUT_FILE")"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

# ---------------------------------------------------------------------------
# Shape checks, applied before anything reaches the fragment.
#
# RotomLab's manifest.validate() enforces most of these itself, and the
# validation step below runs it for real. They are repeated here so a bad value
# is named where it entered — "build-posix.sh reported an artifact with a slash
# in it" is a usable message; "manifest: toolchain "make" (linux-amd64)
# filename must be a bare name" three steps later is not.
# ---------------------------------------------------------------------------

# bare_name <value> <what> — RotomLab's isPlainName: no path structure at all.
# Artifact IDs become cache paths, filenames are written into the extraction
# directory, and both reach the filesystem without passing through fetch's path
# guards.
bare_name() {
  case "$1" in
    ''|.|..) die "$2 must be a bare name, not $1" ;;
    */*|*\\*) die "$2 must be a bare name with no path separator: $1" ;;
  esac
}

hex64() {
  case "$1" in
    ????????????????????????????????????????????????????????????????) : ;;
    *) die "$2 is not a 64-character digest: $1" ;;
  esac
  case "$1" in
    *[!0-9a-f]*) die "$2 is not lowercase hex: $1" ;;
  esac
}

FRAGMENT='{"games":{},"toolchains":{},"hostTools":{}}'

# merge_in <json> — fold a piece into the fragment. jq's `*` merges objects
# recursively, which is what lets five games accumulate one at a time.
merge_in() {
  FRAGMENT=$(printf '%s\n%s\n' "$FRAGMENT" "$1" | jq -s '.[0] * .[1]') ||
    die "could not merge fragment piece: $1"
}

# ---------------------------------------------------------------------------
# 1. Host tools, and the games each bundle serves
# ---------------------------------------------------------------------------
# Accumulated so that step 1b can compare what the inputs covered against what
# build.json pins. Word-splitting is safe: every name is bare_name-checked
# before it is appended.
COVERED_GAMES=

for f in $HOSTTOOLS_JSON; do
  game=$(jq -er .game "$f")       || die "$f: no .game"
  artifact=$(jq -er .artifact "$f") || die "$f: no .artifact"
  sha=$(jq -er .sha256 "$f")      || die "$f: no .sha256"
  toolsHash=$(jq -er .toolsHash "$f") || die "$f: no .toolsHash"
  commit=$(jq -er .commit "$f")   || die "$f: no .commit"

  bare_name "$artifact" "$f: artifact filename"
  hex64 "$sha" "$f: sha256"
  hex64 "$toolsHash" "$f: toolsHash"

  # Which decomp produced this? build-host-tools.sh names its artifact after
  # games[0], so that is the key back into build.json.
  decomp=$(jq -er --arg g "$game" \
    '[.decomps | to_entries[] | select(.value.games[0] == $g) | .key] | if length == 1 then .[0] else error("\(length) decomps have games[0] == \($g)") end' \
    "$BUILD_JSON") || die "$f: cannot map game $game back to a decomp in build.json"

  pinned=$(cfg ".decomps.\"$decomp\".commit")
  # The triple, enforced. A JSON line from an older run would otherwise let the
  # published artifact and the manifest's commit describe different trees.
  [ "$commit" = "$pinned" ] || die "$f reports commit $commit for $decomp,
but build.json pins $pinned. The artifact, its toolsHash and the commit have to
describe one clone; re-run build-host-tools.sh against the current pin."

  repo=$(cfg ".decomps.\"$decomp\".repo")
  htid=$(cfg ".decomps.\"$decomp\".hostToolsId")
  bare_name "$htid" "build.json: .decomps.$decomp.hostToolsId"

  merge_in "$(jq -n \
    --arg id "$htid" --arg url "$BASE_URL/$artifact" --arg sha "$sha" \
    --arg plat "$PLATFORM" \
    '{hostTools: {($id): {($plat): {url: $url, sha256: $sha, kind: "tar.xz"}}}}')"

  # Every game the decomp builds gets the same commit, hash and bundle. The
  # list is build.json's, so firered and leafgreen cannot end up disagreeing
  # about which commit their shared host tools came from.
  for g in $(cfg ".decomps.\"$decomp\".games[]"); do
    bare_name "$g" "build.json: .decomps.$decomp game name"
    merge_in "$(jq -n \
      --arg g "$g" --arg repo "$repo" --arg commit "$commit" \
      --arg th "$toolsHash" --arg ht "$htid" \
      '{games: {($g): {
          decomp:    {repo: $repo, commit: $commit},
          toolsHash: $th,
          hostTools: $ht
       }}}')"
    log "game    $g -> $htid @ $commit, toolsHash $toolsHash"
    COVERED_GAMES="$COVERED_GAMES $g"
  done
done

# ---------------------------------------------------------------------------
# 1b. Every game build.json pins was covered by a --hosttools input
#
# The check that makes an omitted input an error rather than a silent hole.
# release.yml derives its --hosttools arguments from build.json and so cannot
# miss one; the developer command in fragment.yml is typed by hand, one
# --hosttools per decomp, and is exactly where a decomp gets left out.
#
# Stated over GAMES rather than over decomps because games are what the
# manifest is keyed by, and a decomp whose games[] gained an entry — a fourth
# ROM built out of pokefirered, say — is the same failure with the same
# symptom: a game keeping the previous release's triple.
#
# This runs before anything is written and needs no RotomLab checkout, so it
# fires on the plain `emit-fragment.sh` invocation too, not only when
# --validate-against is passed.
# ---------------------------------------------------------------------------
missing=
for g in $(cfg '.decomps[].games[]'); do
  case " $COVERED_GAMES " in
    *" $g "*) : ;;
    *) missing="$missing $g" ;;
  esac
done
[ -z "$missing" ] || die "build.json pins games that no --hosttools input covers:$missing
Each would keep whatever URL, commit and toolsHash the previous release left in
embedded.json, while the tag being cut claims to fingerprint the current pin
set. Pass one --hosttools per decomp in build.json — the decomps are:
$(cfg '.decomps | keys[]' | sed 's/^/  /')"
log "check   every game in build.json is covered: $(printf '%s' "$COVERED_GAMES" | wc -w) games"

# ---------------------------------------------------------------------------
# 2. The POSIX layer
#
# Artifact IDs are bare and version-free — "make", not "make-4.4.1". RotomLab
# reads paths["make"] and paths["bash"] by those exact names, so a versioned ID
# would resolve to an empty path and the build would run with the host's make.
# The version lives in the filename and therefore in the URL, which is where it
# belongs: it identifies the download, not the role.
# ---------------------------------------------------------------------------
for tool in make bash; do
  artifact=$(jq -er ".$tool.artifact" "$POSIX_JSON") || die "$POSIX_JSON: no .$tool.artifact"
  sha=$(jq -er ".$tool.sha256" "$POSIX_JSON")        || die "$POSIX_JSON: no .$tool.sha256"
  bare_name "$artifact" "$POSIX_JSON: .$tool.artifact"
  hex64 "$sha" "$POSIX_JSON: .$tool.sha256"

  # kind "raw" with a filename, not an archive: these are bare binaries, and
  # manifest.validate() hard-fails a raw download that declares no filename
  # because the installed name would otherwise come from a cache temp path.
  merge_in "$(jq -n \
    --arg id "$tool" --arg url "$BASE_URL/$artifact" --arg sha "$sha" \
    --arg plat "$PLATFORM" \
    '{toolchains: {($id): {($plat): {
        url: $url, sha256: $sha, kind: "raw", filename: $id, exec: true
     }}}}')"
  log "tool    $tool -> $artifact"
done

# ---------------------------------------------------------------------------
# 3. The mirrors
#
# stripPrefix comes from mirror.sh's own report rather than from build.json, so
# the manifest states the layout of the tarball that was actually written. The
# two cannot disagree even if build.json's strip_prefix were edited without
# re-running the mirror.
#
# busybox's applet list is deliberately not emitted: it belongs to RotomLab's
# manifest, not to this pipeline. It is checked instead — see validate below.
# ---------------------------------------------------------------------------
dka_artifact=$(jq -er .devkitarm.artifact "$MIRROR_JSON")
dka_sha=$(jq -er .devkitarm.sha256 "$MIRROR_JSON")
dka_prefix=$(jq -er .devkitarm.stripPrefix "$MIRROR_JSON")
bare_name "$dka_artifact" "$MIRROR_JSON: .devkitarm.artifact"
hex64 "$dka_sha" "$MIRROR_JSON: .devkitarm.sha256"
[ -n "$dka_prefix" ] || die "$MIRROR_JSON: empty stripPrefix"

bb_artifact=$(jq -er .busybox.artifact "$MIRROR_JSON")
bb_sha=$(jq -er .busybox.sha256 "$MIRROR_JSON")
bb_filename=$(jq -er .busybox.filename "$MIRROR_JSON")
bare_name "$bb_artifact" "$MIRROR_JSON: .busybox.artifact"
bare_name "$bb_filename" "$MIRROR_JSON: .busybox.filename"
hex64 "$bb_sha" "$MIRROR_JSON: .busybox.sha256"

merge_in "$(jq -n \
  --arg url "$BASE_URL/$dka_artifact" --arg sha "$dka_sha" \
  --arg prefix "$dka_prefix" --arg plat "$PLATFORM" \
  '{toolchains: {devkitarm: {($plat): {
      url: $url, sha256: $sha, kind: "tar.xz", stripPrefix: $prefix
   }}}}')"
log "tool    devkitarm -> $dka_artifact (stripPrefix $dka_prefix)"

merge_in "$(jq -n \
  --arg url "$BASE_URL/$bb_artifact" --arg sha "$bb_sha" \
  --arg name "$bb_filename" --arg plat "$PLATFORM" \
  '{toolchains: {busybox: {($plat): {
      url: $url, sha256: $sha, kind: "raw", filename: $name, exec: true
   }}}}')"
log "tool    busybox -> $bb_artifact"

# ---------------------------------------------------------------------------
# 4. Write it
# ---------------------------------------------------------------------------
printf '%s\n' "$FRAGMENT" | jq . >"$OUT_FILE"
log "wrote   $OUT_FILE"

# ---------------------------------------------------------------------------
# 5. Validate against RotomLab's real parser
#
# A fragment that fails Parse on paste is worse than no fragment: it arrives
# looking authoritative and turns into a debugging session in the wrong
# repository. So the merge is performed here and RotomLab's own test is run
# over the result, in a throwaway export of the checkout — `git archive HEAD`
# rather than a copy, so nothing can be written back to it and the validation
# runs against committed state rather than whatever happens to be in the tree.
# ---------------------------------------------------------------------------
[ -n "$VALIDATE_AGAINST" ] || {
  log "note    no --validate-against given; the fragment has NOT been run"
  log "note    through RotomLab's parser. Pass a checkout to prove it parses."
  exit 0
}

need git go tar
RL=$(CDPATH= cd -- "$VALIDATE_AGAINST" 2>/dev/null && pwd) ||
  die "no such directory: $VALIDATE_AGAINST"
BASE_MANIFEST="$RL/internal/manifest/embedded.json"
[ -f "$BASE_MANIFEST" ] || die "$RL is not a RotomLab checkout: no internal/manifest/embedded.json"

before=$(git -C "$RL" status --porcelain; git -C "$RL" rev-parse HEAD)

# The merge, in the form it would be applied by hand. `*` recurses into
# objects, so games.<id>.decomp.commit lands without disturbing makeTargets,
# and arrays are replaced wholesale — which is why no array is emitted.
MERGED="$(dirname "$OUT_FILE")/embedded.merged.json"
jq -s '.[0] * .[1]' "$BASE_MANIFEST" "$OUT_FILE" >"$MERGED" ||
  die "merge failed"
log "merge   $BASE_MANIFEST * $(basename "$OUT_FILE") -> $MERGED"

sv=$(jq -er .schemaVersion "$MERGED")
[ "$sv" = 1 ] || die "merged manifest declares schemaVersion $sv; this script
writes the shape schemaVersion 1 describes and has not been reviewed against $sv"

# ---- not load-bearing: the placeholder sweep --------------------------------
#
# embedded.json shipped every unpublished value as a TODO placeholder, once,
# before the first release. It contains none today, so this can only fire for a
# field added to embedded.json in future and left as a placeholder. Worth a
# line; worth nothing as a completeness guarantee. The two checks after it are
# the ones that hold.
leftover=$(jq -r '[paths(type == "string" and startswith("TODO"))
                   | map(tostring) | join(".")] | .[]' "$MERGED")
[ -z "$leftover" ] || die "the merge left placeholders unfilled:
$(printf '%s\n' "$leftover" | sed 's/^/  /')
Each is a field this fragment was supposed to supply."
log "check   no TODO placeholder survives the merge (vacuous today; see header)"

# ---- every artifact URL points into the release being cut -------------------
#
# The check that catches a merge which did not land. An entry the fragment
# never touched keeps the URL, digest and kind the PREVIOUS release wrote —
# well formed, downloadable, and describing bytes built from a different pin
# set. Nothing about its shape is wrong, so no shape check can see it; the only
# thing wrong with it is which release it belongs to.
#
# Every toolchain and every host-tools bundle in this manifest is published by
# this pipeline, and release.yml rebuilds all of them on every release, so
# "not under this release" has no legitimate case today. Compared against
# BASE_URL rather than against the bare tag so that the --base-url path is held
# to the same rule.
#
# Two futures would make this check wrong, and both should change it
# deliberately rather than by weakening it in response to a red build:
#
#   - an artifact fetched from somewhere other than this pipeline (an upstream
#     AppImage, say). That needs an explicit allowlist of IDs, not a relaxed
#     prefix, so the exception is named and reviewable.
#   - an incremental release that republishes only what changed. That is a
#     different release model, and it removes the one property this check
#     relies on: that a URL still pointing at an older tag can only mean the
#     merge did not land.
stale=$(jq -r --arg base "$BASE_URL/" '
  [ (.toolchains // {} | to_entries[] | {sect: "toolchains", id: .key, plats: .value}),
    (.hostTools  // {} | to_entries[] | {sect: "hostTools",  id: .key, plats: .value}) ]
  | .[] as $e
  | $e.plats | to_entries[]
  | select(((.value.url // "") | startswith($base)) | not)
  | "\($e.sect).\($e.id) (\(.key)): \(.value.url // "<no url>")"' "$MERGED")
[ -z "$stale" ] || die "the merged manifest carries artifact URLs that are not
in the release being cut:
$(printf '%s\n' "$stale" | sed 's/^/  /')
Expected every URL under: $BASE_URL/
An entry the fragment did not land on keeps the previous release's URL. It
parses, it downloads, and it is the wrong build — which is why this is checked
on the MERGED file and not on the fragment, where it would be trivially true."
log "check   every artifact URL in the merged manifest is under $BASE_URL/"

# ---- the triple moves together, per game ------------------------------------
#
# commit, host-tools bundle and toolsHash describe one clone (see the header).
# Two of the three are checked against sources OUTSIDE this fragment — the
# commit and repo against build.json, which is what the release tag
# fingerprints — so a game that quietly kept its old values cannot pass by
# agreeing with a fragment that never mentioned it. toolsHash has no second
# source by construction: it is computed over the cloned tree at build time, so
# it is checked against what this run emitted, which is the assertion that the
# hash in the manifest came from this run at all.
drift=$(jq -s -r '
  .[0] as $m | .[1] as $f | .[2] as $b
  | ($b.decomps | to_entries
     | map(.value as $d | $d.games[] | {key: ., value: $d})
     | from_entries) as $pin
  | $m.games | to_entries[]
  | .key as $k | .value as $g
  | ($pin[$k] // null) as $p
  | ($f.games[$k] // null) as $fg
  | [ (if $p == null
       then "\($k): in the manifest, pinned by no decomp in build.json"
       else empty end),
      (if $p != null and $g.decomp.commit != $p.commit
       then "\($k): manifest commit \($g.decomp.commit) but build.json pins \($p.commit)"
       else empty end),
      (if $p != null and $g.decomp.repo != $p.repo
       then "\($k): manifest repo \($g.decomp.repo) but build.json says \($p.repo)"
       else empty end),
      (if $fg == null
       then "\($k): this run emitted no commit, bundle or toolsHash for it"
       else empty end),
      (if $fg != null and $g.toolsHash != $fg.toolsHash
       then "\($k): manifest toolsHash \($g.toolsHash) but this run computed \($fg.toolsHash)"
       else empty end),
      (if $fg != null and $g.hostTools != $fg.hostTools
       then "\($k): manifest hostTools \($g.hostTools) but this run built \($fg.hostTools)"
       else empty end),
      # `// ""` so a game with no hostTools at all reports as a missing bundle
      # rather than aborting the program with "cannot index object with null".
      # manifest.validate() would reject it too, but this check runs first and
      # has to survive input the parser has not seen yet.
      (if ($m.hostTools[$g.hostTools // ""] // null) == null
       then "\($k): names host-tools bundle \($g.hostTools), which the manifest does not define"
       else empty end) ]
  | .[]' "$MERGED" "$OUT_FILE" "$BUILD_JSON")
[ -z "$drift" ] || die "the commit/bundle/toolsHash triple does not move together:
$(printf '%s\n' "$drift" | sed 's/^/  /')
Each of the three describes one clone of one decomp at one commit. A game left
behind at the previous release keeps all three of its old values, which is
self-consistent and wrong."

# Games built from one decomp must not disagree, or two projects out of one
# repository would claim different provenance.
split=$(jq -r '[.games | to_entries[]
                | {ht: .value.hostTools, c: .value.decomp.commit, t: .value.toolsHash}]
               | group_by(.ht)
               | map(select((map({c, t}) | unique | length) > 1))
               | .[] | tostring' "$MERGED")
[ -z "$split" ] || die "games sharing a host-tools bundle disagree about which
clone it came from:
$(printf '%s\n' "$split" | sed 's/^/  /')"
log "check   every game carries this run's commit, bundle and toolsHash together"

# makeTargets and romNames must have identical key sets. manifest.validate()
# checks it too; doing it here names the game and mode rather than reporting a
# parse failure after the merge has already been written out.
bad=$(jq -r '.games | to_entries[]
        | . as $e
        | (($e.value.makeTargets // {} | keys) - ($e.value.romNames // {} | keys)) as $a
        | (($e.value.romNames // {} | keys) - ($e.value.makeTargets // {} | keys)) as $b
        | select(($a | length) > 0 or ($b | length) > 0)
        | "\($e.key): makeTargets-only=\($a) romNames-only=\($b)"' "$MERGED")
[ -z "$bad" ] || die "makeTargets and romNames disagree:
$bad"
log "check   every game's makeTargets and romNames have identical key sets"

# Every applet the merged manifest names must be one mirror.sh confirmed the
# published busybox actually implements. This is the other half of not emitting
# the applet list: RotomLab keeps ownership of it, and this pipeline refuses to
# publish a busybox that cannot satisfy it.
verified=$(cfg '.mirrors.busybox.applets')
unverified=$(jq -r --argjson v "$verified" \
  '[.toolchains.busybox // {} | .[] | .applets // [] | .[]] - $v | .[]' "$MERGED")
[ -z "$unverified" ] || die "the manifest names busybox applets that mirror.sh
never verified against the published binary:$(printf ' %s' $unverified)
Add them to .mirrors.busybox.applets in build.json and re-run mirror.sh, which
checks them against 'busybox --list'."
log "check   every applet the manifest names was verified against the binary"

# ---- the real parser -------------------------------------------------------
SCRATCH="$WORK/rotomlab"
mkdir -p "$SCRATCH"
git -C "$RL" archive HEAD | tar -x -C "$SCRATCH" ||
  die "could not export $RL at HEAD"
cp "$MERGED" "$SCRATCH/internal/manifest/embedded.json"

log "verify  go test ./internal/manifest/ -run Embedded  (in a scratch export)"
# Output captured rather than piped: a pipeline's status is its last command's,
# so `go test | sed || die` would report sed's success and pass a failing test.
if ( cd "$SCRATCH" && go test ./internal/manifest/ -run Embedded -v -count=1 ) \
     >"$WORK/gotest.log" 2>&1; then
  sed 's/^/    | /' "$WORK/gotest.log" >&2
else
  sed 's/^/    | /' "$WORK/gotest.log" >&2
  die "the merged manifest does not parse: RotomLab's own test rejected it"
fi

# The checkout is validation input, never a target. Verified rather than
# asserted, because "I only read it" is exactly the claim worth checking.
after=$(git -C "$RL" status --porcelain; git -C "$RL" rev-parse HEAD)
[ "$before" = "$after" ] || die "the RotomLab checkout changed during validation.
  before: $before
  after:  $after"
log "ok      $RL is byte-for-byte as it was found"
log "ok      the fragment merges into a manifest RotomLab's own parser accepts"
