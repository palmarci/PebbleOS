#!/usr/bin/env bash
# One-shot build/version/deploy for the MiniMed SAKE spike firmware.
#
#   ./spike-build.sh <desc>          build + bundle + share to the phone over kdeconnect.
#   ./spike-build.sh <desc> --no-push    skip the share (just build the versioned .pbz)
#   ./spike-build.sh --configure <desc>  force a waf configure (after Kconfig/registry changes)
#
# Why this exists: the raw Docker one-liner is long, `./waf bundle` always emits the same
# git-describe name (easy to grab a stale one), the versioned copy was manual, and getting the
# file to the phone was a separate step. This does all four. See PROGRESS.md.
set -euo pipefail
cd "$(dirname "$0")"

IMAGE=pebbleos-build:local
BOARD=obelix                          # PT2 / Pebble Time 2 (SiFli)
do_configure=0
push=1
desc=""
for arg in "$@"; do
  case "$arg" in
    --configure) do_configure=1 ;;
    --no-push)   push=0 ;;
    -*)          echo "unknown flag: $arg" >&2; exit 2 ;;
    *)           desc="$arg" ;;
  esac
done
[ -n "$desc" ] || { echo "usage: $0 <desc> [--configure] [--no-push]" >&2; exit 2; }

# Fast path: keep the existing build/c4che configure (incremental) unless one is missing
# or the board/config changed. Re-configure only on --configure or first run.
if [ -d build/c4che ] && ! grep -q "$BOARD" build/c4che/_cache.py 2>/dev/null; then
  do_configure=1
fi
[ -d build/c4che ] || do_configure=1   # never configured yet -> must configure

# Next version = 1 + (max N across build/sake-spike-vN-*.pbz) (numeric, not lexical).
next_ver=$(( $(ls build/sake-spike-v*.pbz 2>/dev/null \
  | sed -n 's#.*/sake-spike-v\([0-9]\{1,\}\)-.*#\1#p' | sort -n | tail -1 | grep -E '^[0-9]+$' || echo 0) + 1 ))

echo ">> building (v$next_ver-$desc)${do_configure:+ [configure]}..."
docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp \
  -v "$PWD":/pebbleos -w /pebbleos "$IMAGE" bash -lc "
    git config --global --add safe.directory /pebbleos
    export PATH=/opt/pebbleos-sdk/arm-none-eabi/bin:\$PATH
    ${do_configure:+./waf configure --board $BOARD -DCONFIG_MINIMED_SAKE_SPIKE=y && }./waf build && ./waf bundle"

# The freshly written bundle is the newest normal_<board>_*.pbz.
fresh=$(ls -t build/normal_${BOARD}_*.pbz | head -1)
out="build/sake-spike-v${next_ver}-${desc}.pbz"
cp "$fresh" "$out"
echo ">> $out"

# Keep this build's loghash dictionary next to the .pbz. PBL_LOG lines are stored hashed, and the
# hashes change between builds -- so without the matching dict, tools/dump_flash_logs.py cannot
# read back a log written by an older firmware. Costs a few hundred KB per flash.
if [ -f build/pebbleos_loghash_dict.json ]; then
  cp build/pebbleos_loghash_dict.json "build/sake-spike-v${next_ver}-${desc}.loghash.json"
fi

if [ "$push" = 1 ]; then
  device=$(kdeconnect-cli -a --id-only 2>/dev/null | head -1)
  if [ -n "$device" ]; then
    kdeconnect-cli -d "$device" --share "$out" >/dev/null && \
      echo ">> shared to phone: $(basename "$out")"
  else
    echo ">> skip share: no reachable kdeconnect device (use --no-push to silence)"
  fi
fi
