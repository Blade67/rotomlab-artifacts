#!/bin/sh
# check-build-json.sh [file]
#
# Validates build.json on its own, without building or fetching anything.
#
# Every other script in this repository reads build.json through cfg(), which
# fails on the single value it happened to need. A malformed pin file is
# therefore only caught when a script that reads that particular key happens to
# run — and build.json has already been broken once by an edit that nothing
# noticed until a build had been paid for. This is the check that runs first:
# it costs a second, needs no network, and names every problem at once instead
# of the first one reached.
#
# It is a SHAPE check, not a truth check, and the distinction is deliberate.
# Whether a digest is the digest of the file at that URL is decided by
# fetch_verify at download time, which is the only place it can be decided.
# What is checked here is that every field a script will later read exists, has
# the right type and has the right shape — a 40-character lowercase commit, an
# https URL, a filename-safe version, a bare artifact ID — so that "the pin
# file is wrong" is reported as exactly that, in front of the build rather than
# somewhere inside it.
#
# The shapes are not invented here. Each mirrors a guard an existing script
# already applies to the same value (build-host-tools.sh's commit and game-name
# cases, mirror.sh's check_pin, emit-fragment.sh's bare_name), so a value that
# passes here is one those guards will also accept.
#
# The jq program is written to a file from a quoted heredoc rather than inlined
# in a single-quoted shell string, so its prose can contain an apostrophe
# without silently ending the quote.
#
# Usage:
#   check-build-json.sh            check <repo>/build.json
#   check-build-json.sh <file>     check that file
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

BUILD_JSON="${BUILD_JSON:-$ROOT/build.json}"
export BUILD_JSON
. "$SCRIPT_DIR/lib.sh"

need jq

FILE="${1:-$BUILD_JSON}"
[ -f "$FILE" ] || die "no such file: $FILE"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

# ---------------------------------------------------------------------------
# 1. Is it JSON at all?
#
# Separated from the shape check below so a syntax error reports as a syntax
# error, with jq's own line and column, rather than as fifty missing keys.
# ---------------------------------------------------------------------------
if ! jq empty "$FILE" 2>"$WORK/jq.err"; then
  sed 's/^/    | /' "$WORK/jq.err" >&2
  die "$FILE is not valid JSON"
fi
log "ok      $FILE is valid JSON"

# ---------------------------------------------------------------------------
# 2. Shape
#
# One jq program producing one line per problem, so a file with six mistakes
# takes one run to fix rather than six. Empty output means the file is well
# formed.
# ---------------------------------------------------------------------------
cat >"$WORK/shape.jq" <<'JQPROG'
# \A and \z, not ^ and $. jq uses Oniguruma, where $ matches before a
# trailing newline exactly as in Perl, so "ffff...ffff\n" passed a ^...$ digest
# check here and was then rejected by emit-fragment.sh and mirror.sh, whose
# fixed-width `case` globs do see the newline. Nothing bad got through, but the
# preflight failed to catch what it advertises, and this file claims above that
# a value passing here is one those guards will also accept.
def hex40:    type == "string" and test("\\A[0-9a-f]{40}\\z");
def hex64:    type == "string" and test("\\A[0-9a-f]{64}\\z");
# Filename-safe: these become artifact filenames and, through the manifest,
# parts of a URL. Same character class the build scripts enforce.
def safe:     type == "string" and test("\\A[A-Za-z0-9._-]+\\z");
def bare:     safe and . != "." and . != "..";
def https:    type == "string" and startswith("https://");
def nonempty: type == "string" and length > 0;

. as $b |

[
# ---- top level ------------------------------------------------------------
  (["decomps", "posix", "mirrors"][] as $k
   | select($b | has($k) | not)
   | "missing top-level key: .\($k)"),

# ---- decomps --------------------------------------------------------------
  (if ($b.decomps | type) != "object" then "decomps: not an object"
   elif ($b.decomps | length) == 0 then "decomps: empty, so nothing would be built"
   else empty end),

  ($b.decomps // {} | to_entries[] | . as $d |
    # Guarded: without this a decomp whose value is a string aborts the whole
    # program with "Cannot index string with string", which names none of the
    # problems this script exists to name all of.
    if ($d.value | type) != "object" then
      "decomps.\($d.key) is not an object"
    else
    ([ (select($d.key | bare | not)
        | "decomps: key \"\($d.key)\" is not a bare filename-safe name"),

       (select($d.value.repo | https | not)
        | "decomps.\($d.key).repo is not an https URL: \($d.value.repo // "(absent)")"),

       (select($d.value.commit | hex40 | not)
        | "decomps.\($d.key).commit is not a 40-character lowercase hex SHA: \($d.value.commit // "(absent)")"),

       (select(($d.value.games | type) != "array" or ($d.value.games | length) == 0)
        | "decomps.\($d.key).games is not a non-empty array"),

       ($d.value.games // [] | .[] | select(bare | not)
        | "decomps.\($d.key).games contains a name that is not filename-safe: \(.)"),

       (select($d.value.hostToolsId | bare | not)
        | "decomps.\($d.key).hostToolsId is not a bare name: \($d.value.hostToolsId // "(absent)")")
     ][]) end),

  # Game names are the manifest keys RotomLab looks games up by, and
  # emit-fragment.sh maps an artifact back to its decomp through games[0].
  # Two decomps claiming one game name makes both ambiguous.
  ([$b.decomps // {} | .[] | select(type == "object") | .games // [] | .[]]
   | group_by(.) | map(select(length > 1) | .[0])[]
   | "decomps: game name \"\(.)\" is claimed by more than one decomp"),

  # Two decomps sharing a hostToolsId would have the second silently overwrite
  # the first when the fragment is merged into the manifest.
  ([$b.decomps // {} | .[] | select(type == "object") | .hostToolsId // empty]
   | group_by(.) | map(select(length > 1) | .[0])[]
   | "decomps: hostToolsId \"\(.)\" is used by more than one decomp"),

# ---- posix ----------------------------------------------------------------
  (["make", "bash"][] | . as $t |
    ([ (select(($b.posix[$t] | type) != "object")
        | "posix.\($t) is missing or not an object"),
       (select($b.posix[$t].version | safe | not)
        | "posix.\($t).version is not filename-safe: \($b.posix[$t].version // "(absent)")"),
       (select($b.posix[$t].url | https | not)
        | "posix.\($t).url is not an https URL: \($b.posix[$t].url // "(absent)")"),
       (select($b.posix[$t].sha256 | hex64 | not)
        | "posix.\($t).sha256 is not a 64-character lowercase hex digest: \($b.posix[$t].sha256 // "(absent)")"),
       (select($b.posix[$t].licence | nonempty | not)
        | "posix.\($t).licence is missing, and SOURCES.md renders it verbatim")
     ][])),

# ---- mirrors.busybox ------------------------------------------------------
  (select(($b.mirrors.busybox | type) != "object")
   | "mirrors.busybox is missing or not an object"),
  (select($b.mirrors.busybox.version | safe | not)
   | "mirrors.busybox.version is not filename-safe: \($b.mirrors.busybox.version // "(absent)")"),
  (select($b.mirrors.busybox.url | https | not)
   | "mirrors.busybox.url is not an https URL: \($b.mirrors.busybox.url // "(absent)")"),
  (select($b.mirrors.busybox.sha256 | hex64 | not)
   | "mirrors.busybox.sha256 is not a 64-character lowercase hex digest: \($b.mirrors.busybox.sha256 // "(absent)")"),

  # GPLv2-only: the source is not optional and it is not a link, so its pin is
  # exactly as load-bearing as the binary's.
  (select($b.mirrors.busybox.source_url | https | not)
   | "mirrors.busybox.source_url is not an https URL. GPLv2 has no equivalent of GPLv3 6(d), so the source must be published: \($b.mirrors.busybox.source_url // "(absent)")"),
  (select($b.mirrors.busybox.source_sha256 | hex64 | not)
   | "mirrors.busybox.source_sha256 is not a 64-character lowercase hex digest: \($b.mirrors.busybox.source_sha256 // "(absent)")"),
  (select($b.mirrors.busybox.licence | nonempty | not)
   | "mirrors.busybox.licence is missing"),

  (select(($b.mirrors.busybox.applets | type) != "array" or ($b.mirrors.busybox.applets | length) == 0)
   | "mirrors.busybox.applets is not a non-empty array"),
  ($b.mirrors.busybox.applets // [] | .[] | select(bare | not)
   | "mirrors.busybox.applets contains a name that is not a bare applet name: \(.)"),
  ([$b.mirrors.busybox.applets // [] | .[]]
   | group_by(.) | map(select(length > 1) | .[0])[]
   | "mirrors.busybox.applets lists \"\(.)\" more than once"),

# ---- mirrors.devkitarm ----------------------------------------------------
  (select(($b.mirrors.devkitarm | type) != "object")
   | "mirrors.devkitarm is missing or not an object"),
  (select($b.mirrors.devkitarm.version | safe | not)
   | "mirrors.devkitarm.version is not filename-safe: \($b.mirrors.devkitarm.version // "(absent)")"),
  (select($b.mirrors.devkitarm.licence | nonempty | not)
   | "mirrors.devkitarm.licence is missing"),
  (select($b.mirrors.devkitarm.buildscripts_tag | nonempty | not)
   | "mirrors.devkitarm.buildscripts_tag is missing, and it is half the corresponding-source offer"),
  (select($b.mirrors.devkitarm.buildscripts_commit | hex40 | not)
   | "mirrors.devkitarm.buildscripts_commit is not a 40-character lowercase hex SHA. A tag can be moved, so the commit is what makes it an offer: \($b.mirrors.devkitarm.buildscripts_commit // "(absent)")"),

  # RotomLab strips this prefix at extraction and silently drops every member
  # outside it, so an absolute or traversing prefix is not a bad path, it is an
  # empty install with no error.
  (select($b.mirrors.devkitarm.strip_prefix | nonempty | not)
   | "mirrors.devkitarm.strip_prefix is missing"),
  (select(($b.mirrors.devkitarm.strip_prefix // "") | test("^/|\\.\\."))
   | "mirrors.devkitarm.strip_prefix must be a relative path containing no \"..\": \($b.mirrors.devkitarm.strip_prefix)"),

  (select(($b.mirrors.devkitarm.packages | type) != "array" or ($b.mirrors.devkitarm.packages | length) == 0)
   | "mirrors.devkitarm.packages is not a non-empty array, and devkitARM is a metapackage with no files of its own"),
  ($b.mirrors.devkitarm.packages // [] | to_entries[] | . as $p |
    ([ (select($p.value.name | safe | not)
        | "mirrors.devkitarm.packages[\($p.key)].name is not filename-safe: \($p.value.name // "(absent)")"),
       (select($p.value.version | safe | not)
        | "mirrors.devkitarm.packages[\($p.key)].version is not filename-safe: \($p.value.version // "(absent)")"),
       (select($p.value.url | https | not)
        | "mirrors.devkitarm.packages[\($p.key)].url is not an https URL: \($p.value.url // "(absent)")"),
       (select($p.value.sha256 | hex64 | not)
        | "mirrors.devkitarm.packages[\($p.key)].sha256 is not a 64-character lowercase hex digest: \($p.value.sha256 // "(absent)")")
     ][])),
  ([$b.mirrors.devkitarm.packages // [] | .[] | .url // empty]
   | group_by(.) | map(select(length > 1) | .[0])[]
   | "mirrors.devkitarm.packages lists \(.) twice"),
  # The name becomes the cache filename in mirror.sh, so two packages sharing
  # one would download over each other and the merge would see one of them.
  ([$b.mirrors.devkitarm.packages // [] | .[] | .name // empty]
   | group_by(.) | map(select(length > 1) | .[0])[]
   | "mirrors.devkitarm.packages uses the name \(.) more than once"),

# ---- placeholders ---------------------------------------------------------
  # RotomLab ships unpublished values as TODO placeholders and refuses to build
  # against one. build.json is the other side of that boundary: a TODO here
  # would be fetched as a URL or compared as a digest.
  (paths(type == "string" and test("^TODO")) | map(tostring) | join(".")
   | "placeholder value left at .\(.)")
] | .[]
JQPROG

PROBLEMS=$(jq -r -f "$WORK/shape.jq" "$FILE") ||
  die "the shape check itself failed to run against $FILE"

if [ -n "$PROBLEMS" ]; then
  printf '%s\n' "$PROBLEMS" | sed 's/^/  /' >&2
  die "$FILE: $(printf '%s\n' "$PROBLEMS" | wc -l | tr -d ' ') problem(s)"
fi

log "ok      $(jq -r '.decomps | length' "$FILE") decomps, $(jq -r '.mirrors.devkitarm.packages | length' "$FILE") devkitARM packages, $(jq -r '.mirrors.busybox.applets | length' "$FILE") busybox applets"
log "ok      every pin in $FILE is well formed"
