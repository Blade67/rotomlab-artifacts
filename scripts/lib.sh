#!/bin/sh
# Shared helpers. Source this; do not execute it.
#
# The governing rule here: every byte fetched from the network is verified
# against a digest pinned in build.json before anything touches it. Verifying
# only what we publish would leave the inputs unchecked, which is the half that
# an attacker or a silently-repackaged upstream would actually reach.

BUILD_JSON="${BUILD_JSON:-build.json}"

log()  { printf '==> %s\n' "$*" >&2; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'FATAL: %s\n' "$*" >&2; exit 1; }

# need <cmd>... — fail early and by name rather than midway with "not found".
need() {
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"
  done
}

# cfg <jq-filter> — read a value out of build.json.
cfg() {
  jq -er "$1" "$BUILD_JSON" 2>/dev/null || die "build.json: no value at $1"
}

# fetch_verify <url> <sha256> <dest>
#
# Sends a User-Agent because devkitPro's CDN answers 403 to requests without
# one — verified 2026-08-01. That is also why devkitARM is mirrored rather than
# fetched by RotomLab directly: Go's default client would hit the same wall.
fetch_verify() {
  url=$1; want=$2; dest=$3
  [ -n "$url" ] && [ -n "$want" ] && [ -n "$dest" ] || die "fetch_verify: needs url, sha256, dest"

  if [ -f "$dest" ] && verify_sha256 "$dest" "$want" 2>/dev/null; then
    log "cached  $(basename "$dest")"
    return 0
  fi

  log "fetch   $url"
  mkdir -p "$(dirname "$dest")"
  # Download to a temp name so an interrupted transfer cannot be mistaken for a
  # complete one on the next run.
  curl -fsSL --retry 3 --retry-delay 2 \
       -A 'rotomlab-artifacts (+https://github.com/Blade67/rotomlab-artifacts)' \
       -o "$dest.part" "$url" || die "download failed: $url"

  verify_sha256 "$dest.part" "$want" || {
    got=$(sha256_of "$dest.part"); rm -f "$dest.part"
    die "digest mismatch for $url
  expected $want
  got      $got"
  }
  mv "$dest.part" "$dest"
}

sha256_of() { sha256sum "$1" | cut -d' ' -f1; }

verify_sha256() {
  [ "$(sha256_of "$1")" = "$2" ]
}

# require_static <file>... — every binary we publish must be statically linked,
# so it runs on any distribution regardless of glibc version. Checked rather
# than assumed: passing -static does not guarantee it took effect.
require_static() {
  for f in "$@"; do
    desc=$(file -b "$f")
    case "$desc" in
      *"statically linked"*) : ;;
      *) die "$f is not statically linked: $desc" ;;
    esac
  done
}
