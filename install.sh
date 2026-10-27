#!/usr/bin/env bash
# install.sh — ChromeOS speaker DSP on the Google Pixelbook Go (board "Atlas")
# under mainline Linux (Intel AVS + MAX98373).
#
# Installs:
#   1. patched snd-soc-avs.ko (ChromeOS TLV bytes controls, cros3 topology)
#   2. ChromeOS AVS basefw / module loader / topology / Waves+DSM libraries
#   3. UCM speaker profile + DSP tuning blobs (dsmparam, wavesdata)
#   4. udev runtime-PM rule (ChromeOS basefw needs the DSP kept active)
#   5. user session: 48 kHz PipeWire lock, default-sink pinning service
#
# Idempotent. Re-run after a kernel update (the module is rebuilt).
set -euo pipefail

[ "$EUID" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }
REAL_USER="${SUDO_USER:-}"
[ -n "$REAL_USER" ] || { echo "run via sudo from your user account" >&2; exit 1; }
REAL_UID="$(id -u "$REAL_USER")"
UHOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
REPO="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
KREL="$(uname -r)"
FW=/lib/firmware/intel/avs
UCMDIR=/usr/share/alsa/ucm2/Custom/avs_max98373-atlas
CONFD=/usr/share/alsa/ucm2/conf.d/avs_max98373
SPK=alsa_output.platform-avs_max98373.18.auto.HiFi__Speaker__sink

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1
if ! grep -qiE 'atlas' /sys/class/dmi/id/board_name /sys/class/dmi/id/product_name 2>/dev/null; then
    echo "This machine does not identify as Atlas (Pixelbook Go):" >&2
    echo "  board_name=$(cat /sys/class/dmi/id/board_name 2>/dev/null)" >&2
    echo "  product_name=$(cat /sys/class/dmi/id/product_name 2>/dev/null)" >&2
    echo "The firmware/topology here is Atlas-specific. Use --force to install anyway." >&2
    [ "$FORCE" -eq 1 ] || exit 1
fi
for t in curl zstd make clang ld.lld; do
    command -v "$t" >/dev/null 2>&1 || { echo "missing required tool: $t" >&2; exit 1; }
done

as_user() {
    sudo -u "$REAL_USER" env XDG_RUNTIME_DIR="/run/user/$REAL_UID" "$@"
}

echo "== 1/6 build + install patched AVS module"
"$REPO/build-module.sh"
MOD=/tmp/atlas-avs-build/sound/soc/intel/avs/snd-soc-avs.ko
install -d "/lib/modules/$KREL/updates"
install -m 0644 "$MOD" "/lib/modules/$KREL/updates/snd-soc-avs.ko"

echo "== 2/6 ChromeOS AVS firmware, topology and DSP libraries"
install -m 0644 "$REPO/firmware/max98373-tplg-cros-playback-only.bin" \
    "$FW/max98373-tplg-cros3.bin"
install -m 0644 "$REPO/firmware/skl/dsp_fw_spt_release.bin" \
    "$FW/skl/dsp_basefw.bin"
install -m 0644 "$REPO/firmware/skl/dsp_fw_spt_release_7CAD0808-AB10-CD23-EF45-12AB34CD56EF.bin" \
    "$FW/skl/dsp_mod_7CAD0808-AB10-CD23-EF45-12AB34CD56EF.bin"
install -m 0644 \
    "$REPO/firmware/skl/dsp_lib_dsm_core_spt_release.bin" \
    "$REPO/firmware/skl/dsp_lib_waves5_9_spt_release.bin" \
    "$REPO/firmware/skl/dsp_mod_B489C2DE-0F96-42E1-8A2D-C25B5091EE49.bin" \
    "$REPO/firmware/skl/dsp_mod_C75061F3-F2B2-4DCC-8F9F-82ABB4131E66.bin" \
    "$FW/skl/"

echo "== 3/6 UCM speaker profile"
install -d "$UCMDIR" "$CONFD"
install -m 0644 "$REPO/ucm/avs_max98373-atlas.conf" \
    "$REPO/ucm/avs_max98373-atlas-HiFi.conf" "$UCMDIR/"
install -m 0644 "$REPO/ucm/AVS I2S MAX98373.conf" \
    "$CONFD/AVS I2S MAX98373.conf"

echo "== 4/6 Waves/DSM tuning blobs"
install -d /opt/google/dsm /opt/google/waves
install -m 0644 "$REPO/firmware/dsmparam.bin" /opt/google/dsm/dsmparam.bin
install -m 0644 "$REPO/firmware/wavesdata.bin" /opt/google/waves/wavesdata.bin

echo "== 5/6 runtime PM + modprobe"
# ChromeOS basefw does not support mainline runtime-PM resume; keep the AVS
# platform components active or every PCM open fails with -EINVAL.
cat > /etc/udev/rules.d/99-atlas-avs-pm.rules <<'RULE'
ACTION=="add", SUBSYSTEM=="platform", KERNEL=="avs_*", ATTR{power/control}="on"
ACTION=="add", SUBSYSTEM=="pci", KERNEL=="0000:00:1f.3", ATTR{power/control}="on"
RULE
echo 'options snd_soc_avs ignore_fw_version=1' > /etc/modprobe.d/atlas-avs.conf
udevadm control --reload-rules 2>/dev/null || true

echo "== 6/6 user session ($REAL_USER)"
install -d "$UHOME/.config/pipewire/pipewire.conf.d" "$UHOME/.config/systemd/user"
install -m 0644 "$REPO/pipewire/20-atlas-clock.conf" \
    "$UHOME/.config/pipewire/pipewire.conf.d/20-atlas-clock.conf"
install -m 0644 "$REPO/user/atlas-speaker-default.service" \
    "$UHOME/.config/systemd/user/atlas-speaker-default.service"
chown -R "$REAL_USER:" "$UHOME/.config/pipewire" "$UHOME/.config/systemd/user" 2>/dev/null || true
as_user systemctl --user daemon-reload 2>/dev/null || true
as_user systemctl --user enable atlas-speaker-default.service 2>/dev/null || true
as_user systemctl --user restart pipewire wireplumber 2>/dev/null || true
as_user pactl set-default-sink "$SPK" 2>/dev/null || true

depmod -a

echo
echo "Done. REBOOT now (the AVS card must re-probe with the ChromeOS firmware)."
echo "After reboot:"
echo "  amixer -c MAX98373 controls | grep -E 'DSM|WAVES'"
echo "  pactl get-default-sink        # ...HiFi__Speaker__sink"
echo "  sudo dmesg | grep -iE 'ASoC error|firmware boot|failed'"
echo "If WirePlumber routes to HDMI, the atlas-speaker-default.service pins it back;"
echo "or set it once with: pactl set-default-sink $SPK"
