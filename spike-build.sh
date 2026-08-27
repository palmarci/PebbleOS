#!/usr/bin/env bash
# One-shot build/version/deploy for the MiniMed SAKE spike firmware.
#
#   ./spike-build.sh <desc>          build + bundle + share to the phone over kdeconnect.
#   ./spike-build.sh <desc> --no-push    skip the share (just build the versioned .pbz)
#   ./spike-build.sh --configure <desc>  force a waf configure (after Kconfig/registry changes)
#
# Why this exists: the raw Docker one-liner is long, `./waf bundle` always emits the same
# git-describe name (easy to grab a stale one), the single-slot bundle needs re-packing into
# the app's dual-slot layout, and getting the file to the phone was a separate step. This does
# all five. See PROGRESS.md.
set -euo pipefail
cd "$(dirname "$0")"

IMAGE=pebbleos-build:local
BOARD=obelix@pvt                      # PT2 / Pebble Time 2 (SiFli), production revision
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
    ${do_configure:+./waf configure --board $BOARD -DCONFIG_RELEASE=y -DCONFIG_MINIMED_SAKE_SPIKE=y && }./waf build && ./waf bundle"

# The freshly written bundle is the newest normal_<board normalized>_*.pbz
# (BOARD_NORMALIZED strips the @revision, e.g. obelix@pvt -> obelix).
fresh=$(ls -t build/normal_${BOARD//@/_}_*.pbz | head -1)
out="build/sake-spike-v${next_ver}-${desc}.pbz"
# The Pebble app sideloads dual-slot pbzs by the *alternate* slot (the app asks
# for the slot not currently running), so a single-slot root-manifest bundle
# fails with "No manifest for slot <n>". Repackage into the slot0/slot1 layout.
python3 tools/make_dual_slot_pbz.py "$fresh" "$out"
echo ">> $out"

# The pblboot priority header (u64 at bytes 8..15) decides which slot boots.
# A dev band (0x80) always beats any release band (0x01), so the spike builds
# must stay on the dev band or a stock image in the other slot could win.
# Dev can silently flip to release if HEAD gets a plain vX[.Y[.Z]] (or -beta/-rc) tag,
# because pblboot.py only treats exact release tags as release-band. Fail loudly.
band_hex=$(python3 -c "
import zipfile
fw = zipfile.ZipFile('$out').read('slot0/tintin_fw.bin')
print(hex((int.from_bytes(fw[8:16], 'little') >> 56) & 0xff))
")
if [ "$band_hex" != "0x80" ]; then
  echo ">> ERROR: pblboot boot-priority band is $band_hex, not dev (0x80). Refusing to ship."
  echo ">> HEAD got a release-form tag (vX[.Y[.Z]][-beta/rcN])? pblboot.py treats those as release band."
  exit 1
fi
echo ">> pblboot boot-priority band: dev (0x80)"

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
