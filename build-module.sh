#!/usr/bin/env bash
# Build the patched snd-soc-avs.ko for the running kernel.
#
# Fetches the matching AVS sources from the stable tree, applies the Atlas
# overlay in module/, and builds against the installed kernel build tree.
set -euo pipefail

REPO="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
KREL="$(uname -r)"
KVER="${KREL%%-*}"
TAG="v${KVER}"
SRC="/tmp/atlas-avs-build/sound/soc/intel/avs"
CODECS="/tmp/atlas-avs-build/sound/soc/codecs"
BASE="https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain"

FILES="Makefile avs.h topology.h topology.c control.h control.c core.c dsp.c \
ipc.c messages.h messages.c utils.h utils.c loader.c path.h path.c pcm.h \
pcm.c board_selection.c sysfs.c cldma.h cldma.c skl.c apl.c cnl.c icl.c tgl.c \
mtl.c lnl.c ptl.c trace.h trace.c probes.c debugfs.c registers.h debug.h"

for t in curl make clang ld.lld; do
    command -v "$t" >/dev/null 2>&1 || {
        echo "missing build tool: $t (CachyOS Clang kernel needs clang/LLD)" >&2
        exit 1
    }
done
[ -d "/lib/modules/$KREL/build" ] || {
    echo "missing kernel build tree for $KREL (/lib/modules/$KREL/build)" >&2
    exit 1
}

rm -rf /tmp/atlas-avs-build
mkdir -p "$SRC" "$CODECS"

echo "fetching AVS sources for $TAG"
for f in $FILES; do
    curl -fsSL "$BASE/sound/soc/intel/avs/$f?h=$TAG" -o "$SRC/$f" || {
        echo "failed to fetch $f for $TAG from kernel.org" >&2
        echo "if your kernel is not a stable point release, fetch the matching tree manually" >&2
        exit 1
    }
done
# core.c/pcm.c include ../../codecs/hda.h relative to the source dir
curl -fsSL "$BASE/sound/soc/codecs/hda.h?h=$TAG" -o "$CODECS/hda.h"

echo "applying Atlas overlay (TLV controls, module init hook, cros3 topology)"
cp "$REPO/module/board_selection.c" "$REPO/module/control.c" "$REPO/module/control.h" \
   "$REPO/module/topology.c" "$REPO/module/topology.h" "$REPO/module/path.c" \
   "$REPO/module/Makefile" "$SRC/"

echo "building against $KREL"
make -C "/lib/modules/$KREL/build" M="$SRC" LLVM=1 CONFIG_MODULE_SIG_ALL=n \
     modules -j"$(nproc)"

echo "built: $SRC/snd-soc-avs.ko"
