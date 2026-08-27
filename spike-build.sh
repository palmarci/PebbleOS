#!/usr/bin/env bash
# One-shot build/version/deploy for the MiniMed SAKE spike firmware.
#
#   ./spike-build.sh <desc>          build + bundle + share to the phone over kdeconnect.
#   ./spike-build.sh <desc> --no-push    skip the share (just build the versioned .pbz)
#   ./spike-build.sh --configure <desc>  force a waf configure (after Kconfig/registry changes)
#
# Why this exists: the raw Docker one-liner is long, `./waf bundle` always emits the same
# git-describe name (easy to grab a stale one), and getting the file to the phone was a
# separate step. This does all of it. See PROGRESS.md.
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
# Share this raw single-slot bundle as-is: a dual-slot repack black-screened
# the watch, while the plain slot0 bundle sideloads and boots.
fresh=$(ls -t build/normal_${BOARD//@/_}_*.pbz | head -1)
out="build/sake-spike-v${next_ver}-${desc}.pbz"
cp "$fresh" "$out"
echo ">> $out"

# The bin's pblboot band (dev 0x80) and the manifest's versionTag are independent.
# Dev channel needs a non-release-form git describe (band 0x80, always boots over stock),
# but the Pebble app only parses a release-form versionTag (vX.Y.Z / -beta / -rc). So:
# keep the binary dev-band, and rewrite the manifest versionTag to a parseable value
# the app accepts for sideload. This is a manifest-only patch, not the dual-slot repack
# that black-screened the watch.
python3 - "$out" <<'PYEOF'
import json, sys, zipfile, tempfile, os
out = sys.argv[1]
tmp = out + ".tmp"
with zipfile.ZipFile(out, "r") as zin, zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as zout:
    for item in zin.infolist():
        data = zin.read(item.filename)
        if item.filename == "manifest.json":
            m = json.loads(data)
            m["firmware"]["versionTag"] = "v9.9.9"
            data = json.dumps(m).encode()
        zout.writestr(item, data)
os.replace(tmp, out)
print(">> manifest versionTag set to v9.9.9 (app-parseable); bin band kept")
PYEOF

# The pblboot priority header (u64 at bytes 8..15) decides which slot boots.
# Bands order dev (0x80) > release (0x01). Enforce dev band: the whole point is a dev
# build that boots over any release image in the alternate slot.
band_info=$(python3 -c "
import zipfile
fw = zipfile.ZipFile('$out').read('pebbleos.bin')
prio = int.from_bytes(fw[8:16], 'little')
band = (prio >> 56) & 0xff
maj, mn, pat = (prio >> 48) & 0xff, (prio >> 40) & 0xff, (prio >> 32) & 0xff
print(f'{band:02x} {maj} {mn} {pat}')
")
read band_hex maj min pat <<<"$band_info"
if [ "$band_hex" != "80" ]; then
  echo ">> ERROR: spike binary is NOT dev band (got $band_hex, want 0x80)."
  echo ">> HEAD got a release-form tag; remove it (git tag -d) so the build stays dev."
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
