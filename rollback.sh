#!/usr/bin/env bash
# rollback.sh — remove the ChromeOS AVS/Waves DSP transplant and return to the
# stock mainline AVS stack (stock topology/basefw/module + the pre-transplant
# UCM speaker calibration).  Run with sudo, then reboot.
set -euo pipefail

[ "$EUID" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }
REAL_USER="${SUDO_USER:-}"
REAL_UID="${REAL_USER:+$(id -u "$REAL_USER")}"
UHOME="${REAL_USER:+$(getent passwd "$REAL_USER" | cut -d: -f6)}"
REPO="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
KREL="$(uname -r)"
FW=/lib/firmware/intel/avs
UCMDIR=/usr/share/alsa/ucm2/Custom/avs_max98373-atlas
CONFD=/usr/share/alsa/ucm2/conf.d/avs_max98373

as_user() {
    [ -n "$REAL_USER" ] || return 0
    sudo -u "$REAL_USER" env XDG_RUNTIME_DIR="/run/user/$REAL_UID" "$@"
}

echo "== remove patched AVS module"
rm -f "/lib/modules/$KREL/updates/snd-soc-avs.ko"
rm -f /etc/modprobe.d/atlas-avs.conf
rm -f /etc/udev/rules.d/99-atlas-avs-pm.rules

echo "== remove ChromeOS firmware that would override stock"
# The stock topology/basefw/module loader are the linux-firmware .zst files.
rm -f "$FW/max98373-tplg.bin" "$FW"/max98373-tplg-cros*.bin
rm -f "$FW/skl/dsp_basefw.bin" "$FW/skl/dsp_mod_7CAD0808-AB10-CD23-EF45-12AB34CD56EF.bin"
rm -f "$FW/skl/dsp_lib_"*.bin "$FW/skl/dsp_mod_B489"*.bin "$FW/skl/dsp_mod_C750"*.bin
# leftovers from experimentation
rm -f "$FW/skl/dsp_basefw-stock.bin" "$FW/skl/dsp_mod-stock_"*.bin "$FW/max98373-tplg-stock.bin"

echo "== restore pre-transplant UCM speaker calibration"
install -d "$UCMDIR" "$CONFD"
install -m 0644 "$REPO/rollback/avs_max98373-atlas.conf" \
    "$REPO/rollback/avs_max98373-atlas-HiFi.conf" "$UCMDIR/"
install -m 0644 "$REPO/rollback/AVS I2S MAX98373.conf" \
    "$CONFD/AVS I2S MAX98373.conf"

echo "== remove DSP tuning blobs"
rm -rf /opt/google/dsm /opt/google/waves

if [ -n "$REAL_USER" ]; then
    echo "== remove user-session additions ($REAL_USER)"
    as_user systemctl --user disable --now headphone-switch.service 2>/dev/null || true
    rm -f "$UHOME/.local/bin/headphone-switch.sh"
    rm -f "$UHOME/.config/systemd/user/headphone-switch.service"
    rm -f "$UHOME/.config/systemd/user/atlas-speaker-default.service"
    rm -f "$UHOME/.config/pipewire/pipewire.conf.d/20-atlas-clock.conf"
    if [ -f "$UHOME/.config/pipewire/pipewire-pulse.conf.d/59-switch-on-connect.conf.disabled" ]; then
        mv "$UHOME/.config/pipewire/pipewire-pulse.conf.d/59-switch-on-connect.conf.disabled" \
           "$UHOME/.config/pipewire/pipewire-pulse.conf.d/59-switch-on-connect.conf"
    fi
    as_user systemctl --user daemon-reload 2>/dev/null || true
fi

depmod -a

echo
echo "Rolled back. REBOOT now: sudo reboot"
echo "The stock topology will run with the pre-transplant UCM calibration."
echo "Optional userspace EQ (see optional/README.md):"
echo "  install -m 0644 optional/52-atlas-speaker-eq.conf ~/.config/wireplumber/wireplumber.conf.d/"
echo "  systemctl --user restart wireplumber"
