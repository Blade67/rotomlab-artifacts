#!/bin/sh
# Spike: can pret's host tools be built statically under musl?
#
# This is the gate on the whole pipeline. RotomLab invokes the decomp build
# with TOOL_NAMES= empty, which stops make compiling these tools and is what
# removes the host C compiler requirement from users' machines. That only
# works if we can build them here instead.
#
# Reports per-tool, and exits non-zero if any tool fails to build or comes out
# dynamically linked. A partial pass is useful information, not a crash.
set -eu

REPO="${1:-https://github.com/pret/pokeemerald}"
NAME=$(basename "$REPO")

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "==> $NAME"
echo "==> cloning $REPO"
git clone --depth 1 --quiet "$REPO" "$WORK/src"
echo "==> at commit $(git -C "$WORK/src" rev-parse HEAD)"

# Read the tool list from upstream rather than hardcoding it. All three repos
# ship a byte-identical make_tools.mk today, but the list is upstream's to
# change and a hardcoded copy would drift silently.
TOOL_NAMES=$(sed -n 's/^TOOL_NAMES *:*= *//p' "$WORK/src/make_tools.mk")
[ -n "$TOOL_NAMES" ] || { echo "FATAL: could not read TOOL_NAMES from make_tools.mk"; exit 1; }
echo "==> TOOL_NAMES: $TOOL_NAMES"
echo

pass=0
fail=0
failed_tools=""

for t in $TOOL_NAMES; do
  printf '%-12s ' "$t"

  if [ ! -d "$WORK/src/tools/$t" ]; then
    echo "MISSING DIRECTORY tools/$t"
    fail=$((fail + 1)); failed_tools="$failed_tools $t"
    continue
  fi

  # CC and CXX, never CFLAGS: gbagfx and rsfont assign CFLAGS = unconditionally,
  # so a command-line override silently drops -DPNG_SKIP_SETJMP_CHECK and
  # -std=c11. CC ?= gcc makes this the safe lever.
  if ! make -C "$WORK/src/tools/$t" CC="gcc -static" CXX="g++ -static" \
       >"$WORK/$t.log" 2>&1; then
    echo "BUILD FAILED"
    sed 's/^/    | /' "$WORK/$t.log" | tail -12
    fail=$((fail + 1)); failed_tools="$failed_tools $t"
    continue
  fi

  bin="$WORK/src/tools/$t/$t"
  if [ ! -f "$bin" ]; then
    echo "BUILT, BUT NO BINARY AT tools/$t/$t"
    echo "    | produced: $(ls "$WORK/src/tools/$t")"
    fail=$((fail + 1)); failed_tools="$failed_tools $t"
    continue
  fi

  # Verify linkage rather than trusting the flags took effect.
  desc=$(file -b "$bin")
  case "$desc" in
    *"statically linked"*) echo "ok  static" ; pass=$((pass + 1)) ;;
    *) echo "DYNAMIC"; echo "    | $desc"
       fail=$((fail + 1)); failed_tools="$failed_tools $t" ;;
  esac
done

echo
echo "==> $NAME: $pass ok, $fail failed"
[ "$fail" -eq 0 ] || echo "==> failed:$failed_tools"
[ "$fail" -eq 0 ]
