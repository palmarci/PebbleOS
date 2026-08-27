#!/usr/bin/env bash
# One-shot build/version/deploy for the MiniMed SAKE spike firmware.
#
#   ./spike-build.sh <desc>          build + bundle + share to the phone over kdeconnect.
#   ./spike-build.sh <desc> --no-push    skip the share (just build the versioned .pbz)
#   ./spike-build.sh --configure <desc>  force a waf configure (after Kconfig/registry changes)
#
# What this produces and why (see PROGRESS.md "PT2 port" for the full post-mortem):
#   - Release build  (CONFIG_RELEASE=y). The very first black-screens were caused by this flag
#     being silently dropped, making non-release builds that hung the obelix display/boot path.
#   - Single-slot slot0, RAW bundle. Do NOT dual-slot repack and do NOT rewrite the manifest:
#     the official single-slot bundle is what the app parses and the watch boots. The repack that
#     duplicated slot0/1 under one pbz black-screened, and manifest-only versionTag rewriting
#     produced "did not parse" failures.
#   - Release band (0x01) with a release-form version, so it boots over the current stock
#     (4.36.2). A plain annotated git tag like v4.36.9 gives the app a parseable versionTag.
#     Dev band (0x80) is NOT used: a dev-form git describe breaks the app's manifest parse.
#
# This bakes a clean annotated release tag (v4.36.9 by default) if none is present, because
# git describe must resolve to a release-form tag for the bundle's versionTag to parse.
set -euo pipefail
cd "$(dirname "$0")"

IMAGE=ghcr.io/coredevices/pebbleos-docker:v6   # official CI image, not the local commit
BOARD=obelix@pvt                              # PT2 / Pebble Time 2 (SiFli), production revision
SPIKE_TAG=${SPIKE_TAG:-v4.36.9}               # release-form tag stamped into the bundle
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

# Ensure a release-form annotated tag exists on HEAD so `git describe` in the build resolves to
# something the Pebble app parses (vX.Y.Z / -beta / -rc) AND that encodes as release band.
# If SPIKE_TAG exists on an older commit, move it to HEAD (the bundle carries the HEAD build).
# This makes the recipe idempotent across new commits: re-running re-tags HEAD.
git tag -f -a "$SPIKE_TAG" -m "spike pt2 build" HEAD >/dev/null 2>&1
git describe --dirty

# Fast path: keep the existing build/c4che configure (incremental) unless one is missing
# or the board/config changed. Re-configure only on --configure or first run.
if [ -d build/c4che ] && ! grep -q "${BOARD%@*}" build/c4che/_cache.py 2>/dev/null; then
  do_configure=1
fi
[ -d build/c4che ] || do_configure=1

# Next version = 1 + (max N across build/sake-spike-vN-*.pbz) (numeric, not lexical).
next_ver=$(( $(ls build/sake-spike-v*.pbz 2>/dev/null \
  | sed -n 's#.*/sake-spike-v\([0-9]\{1,\}\)-.*#\1#p' | sort -n | tail -1 | grep -E '^[0-9]+$' || echo 0) + 1 ))

echo ">> building (v$next_ver-$desc)${do_configure:+ [configure]}..."
docker run --rm -e HOME=/tmp \
  -v "$PWD":/pebbleos -w /pebbleos "$IMAGE" bash -lc "
    git config --global --add safe.directory /pebbleos
    pip install -U pip >/dev/null 2>&1
    pip install -r requirements.txt >/dev/null 2>&1
    export PATH=/opt/pebbleos-sdk/arm-none-eabi/bin:\$PATH
    ${do_configure:+./waf configure --board $BOARD -DCONFIG_FIRMWARE_SLOT=0 -DCONFIG_RELEASE=y -DCONFIG_MINIMED_SAKE_SPIKE=y && }./waf build && ./waf bundle"

# The freshly written bundle is the newest normal_<board normalized>_*.pbz
# (BOARD_NORMALIZED strips the @revision, e.g. obelix@pvt -> obelix).
# Share this RAW single-slot bundle as-is.
fresh=$(ls -t build/normal_${BOARD//@/_}_*.pbz | head -1)
out="build/sake-spike-v${next_ver}-${desc}.pbz"
cp "$fresh" "$out"
echo ">> $out"

# Sanity: versionTag must be release-form (else the app rejects), and band must be release
# (0x01) with version > stock (4.36.2) so it boots over the alternate slot. Dev band (0x80)
# would not be parseable, so we explicitly want release here.
version_tag=$(unzip -p "$out" manifest.json | python3 -c "import json,sys; print(json.load(sys.stdin)['firmware']['versionTag'])")
band_info=$(python3 -c "
import zipfile
fw = zipfile.ZipFile('$out').read('pebbleos.bin')
prio = int.from_bytes(fw[8:16], 'little')
band = (prio >> 56) & 0xff
maj, mn, pat = (prio >> 48) & 0xff, (prio >> 40) & 0xff, (prio >> 32) & 0xff
print(f'{band:02x} {maj} {mn} {pat}')
")
read band_hex maj min pat <<<"$band_info"
echo ">> versionTag=$version_tag band=$band_hex v$maj.$min.$pat"
if [ "$band_hex" != "01" ]; then
  echo ">> ERROR: expected release band 0x01, got $band_hex. Remove the dev/dirty tag so version resolves to a release form."
  exit 1
fi
if [ "$maj" -lt 4 ] || { [ "$maj" -eq 4 ] && [ "$min" -lt 36 ]; }; then
  echo ">> ERROR: version v$maj.$min.$pat would NOT boot over stock v4.36.2"
  exit 1
fi
echo ">> pblboot: release band, v$maj.$min.$pat (boots over stock v4.36.2), versionTag=$version_tag"

# Keep this build's loghash dictionary next to the .pbz.
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