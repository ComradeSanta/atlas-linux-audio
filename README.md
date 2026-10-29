# Atlas (Pixelbook Go) speaker DSP on Linux

Full ChromeOS speaker quality on the **Google Pixelbook Go** (board **atlas**)
running Arch Linux/CachyOS with mainline PipeWire + the Intel **AVS** driver and
two **MAX98373** smart amps. Stock Linux plays through a dumb AVS topology and
an uncalibrated codec; this repo transplants ChromeOS's actual speaker DSP —
the Waves + Maxim DSM chain — into mainline, with a small out-of-tree AVS
driver patch and the ChromeOS firmware/topology/libraries.

The approach is the same as [vell-linux-audio](https://github.com/ComradeSanta/vell-linux-audio)
(the HP Dragonfly Pro Chromebook, 4× CS35L41 + SOF), adapted to Atlas's
completely different hardware: 2× MAX98373 + DA7219 on Intel AVS.

**Status:** working and listening-verified on Pixelbook Go (Atlas), CachyOS
kernel 7.2.11, PipeWire 1.6.9. The result matches ChromeOS subjectively.

## What it fixes

| Layer | Stock mainline | This repo |
|---|---|---|
| AVS driver | no way to push ChromeOS `DSM data` / `WAVES data` TLV blobs; only the stock "dumb pipe" topology loads | patched `snd-soc-avs` accepts the ChromeOS TLV bytes controls, caches the blobs and applies them when the matching Waves/DSM module is instantiated |
| AVS firmware | stock `skl/dsp_basefw.bin` + generic max98373 topology; no Waves/DSM modules | ChromeOS AVS basefw, ChromeOS `max98373-tplg` topology (playback-only variant), Waves/DSM DSP libraries and module binaries |
| Codec | MAX98373 defaults | ChromeOS UCM amp calibration (BDE/DHT tables, 9.65 V output stage, speaker protection) + `dsmparam.bin`/`wavesdata.bin` pushed into the DSP |
| Runtime PM | PCM open fails with `-EINVAL` with the ChromeOS basefw | udev rule keeps the AVS platform components active |
| Session | HDMI may win the default-node race; adaptive clock | 48 kHz graph lock + high-quality resampling; a jack-driven router switches speakers ↔ DA7219 headphones (both `Headphone Jack` and the AAD's 3-pole `Line Out` classification) and pins the speakers at login |

## Quick start

```bash
git clone https://github.com/ComradeSanta/atlas-linux-audio.git
cd atlas-linux-audio
sudo ./install.sh
sudo reboot
```

The installer builds the patched AVS module for the running kernel, installs
the ChromeOS firmware/topology/libraries and tuning blobs, the UCM profile, the
runtime-PM udev rule, the PipeWire clock config and the default-sink service.

### Requirements

- Arch Linux or a derivative (tested on CachyOS), PipeWire + WirePlumber,
  `alsa-ucm-conf`, `linux-firmware`, `zstd`, `curl`, kernel headers.
- A Clang/LLD-built kernel tree (CachyOS) and `clang`, `ld.lld` — the module is
  built out-of-tree with `LLVM=1`.
- Network access to kernel.org (the installer fetches the matching AVS sources
  for the running kernel version).
- The installer refuses on non-Atlas boards unless `--force` is given.

## Verify (no audio needed)

```sh
cat /proc/asound/cards | grep -A1 MAX98373
amixer -c MAX98373 controls | grep -E 'DSM|WAVES'
pactl get-default-sink        # ...HiFi__Speaker__sink when the jack is out
sudo dmesg | grep -iE 'ASoC error|firmware boot|load modules failed|failed to apply cached TLV'
```

Then play music. If the speakers stay silent, check that WirePlumber did not
route the stream to the HDMI sink:

```sh
pactl list short sink-inputs
pactl get-default-sink
pactl move-sink-input <id> alsa_output.platform-avs_max98373.18.auto.HiFi__Speaker__sink
```

The `headphone-switch.service` user unit pins the default sink to the speakers
at login and switches to the DA7219 headphones when the jack is plugged in
(and back on unplug). A 3-pole headphone plug is reported by the DA7219 AAD as
`Line Out Jack`, not `Headphone Jack`, so the custom DA7219 UCM exposes both
`Headphones` and `Line Out` devices for the same HP outputs. The router is
routing-only: it never touches the speaker DSP/UCM, so speaker quality is
unaffected. An explicit sink choice (e.g. HDMI) is kept.

## How it works

1. **Driver patch** (`module/`, GPL-2.0): the mainline AVS topology loader
   rejects every control except mixers, and registers no TLV bytes handlers.
   The patch adds `DSM data` / `WAVES data` bytes controls (`ext_ops` id 256),
   a blob cache, and applies the cached large-config TLVs to the module whose
   topology `ctl_id` matches, in `avs_path_module_create()`. It also points the
   MX98373 card at `max98373-tplg-cros3.bin` so the kernel's per-name firmware
   cache cannot mask the new topology.
2. **ChromeOS firmware**: `skl/dsp_basefw.bin`, the module loader, the
   Waves/DSM libraries and module binaries. `max98373-tplg-cros3.bin` is the
   ChromeOS topology with its capture/echo-reference PCM and DAPM routes
   removed: the mainline one-BE-link machine driver rejects the extra PCM
   (`-EBUSY`/`-ENODEV`). Playback is unaffected.
3. **UCM + blobs**: the Speaker `EnableSequence` applies the ChromeOS amp
   calibration and pushes `dsmparam.bin`/`wavesdata.bin` with `cset-tlv`. The
   patched driver caches them; the playback path creation sends them to the
   Waves/DSM modules. There is no `DSP Volume` control in the ChromeOS
   topology, so PipeWire uses software volume (the amp path stays at ChromeOS
   parity: Speaker Volume 0, Digital Volume 127).
4. **Runtime PM**: the ChromeOS basefw boots and loads libraries/topology, but
   mainline's runtime-PM resume returns `-EINVAL`; the udev rule keeps the
   `avs_*` platform components at `power/control=on`, and the PCM path works.
5. **Session**: 48 kHz graph lock + resampler quality 10; the default-sink
   service prevents the HDMI sink from winning the default-node race. The
   DA7219 headphone UCM exposes `Headphones` (`Headphone Jack`) and `Line Out`
   (`Line Out Jack`) devices; the router accepts either as headphones.

## Caveats

- **Kernel updates invalidate the out-of-tree module.** Re-run
  `sudo ./install.sh` after a kernel update (it rebuilds the module).
- The ChromeOS runtime-PM workaround keeps the DSP powered (no autosuspend);
  this costs some idle power but is required by the ChromeOS basefw.
- The ChromeOS capture/echo-reference path is not transplanted (playback only).
- The module is unsigned (kernel taint warning); `CONFIG_MODULE_SIG_FORCE` is
  not set on Arch/CachyOS. Re-sign it if you enforce module signatures.
- Do **not** run the optional userspace EQ (`optional/`) together with the
  ChromeOS DSP; it double-processes. It is a fallback for stock rollback.

## Rollback

```bash
sudo ./rollback.sh
sudo reboot
```

Removes the patched module, ChromeOS firmware overrides, udev/modprobe changes
and user additions, and restores the pre-transplant UCM speaker calibration.
The stock linux-firmware `.zst` basefw/topology/module load again.

## Provenance & license

- Code/scripts in this repo: MIT (see `LICENSE`). The kernel module overlay in
  `module/` is GPL-2.0 (derived from Linux; SPDX headers retained).
- Files in `firmware/` are extracted from an official ChromeOS recovery image
  for the hardware they shipped on (Google/Intel/Maxim/Waves); they are not
  covered by MIT. See [BLOBS.md](BLOBS.md).
- Method independently rediscovered from the ChromeOS recovery image; the
  ChromeOS 5.10 AVS driver (`sound/soc/intel/avs/{topology,control,kcontrol}.c`)
  was the reference for the TLV bytes handling. Credit to the mainline AVS
  authors (Cezary Rojewski, Amadeusz Sławiński) and the vell-linux-audio work.

## Repo map

```
install.sh              main installer (build + firmware + UCM + session)
build-module.sh         fetch matching AVS sources and build the patched module
rollback.sh             return to the stock mainline AVS stack
module/                 GPL-2.0 AVS driver overlay (TLV controls, cros3 topology)
firmware/               ChromeOS AVS basefw/module loader/topology/libraries + blobs
ucm/                    ChromeOS-style UCM speaker profile + DA7219 headphone profile
rollback/               pre-transplant UCM speaker calibration
pipewire/               48 kHz graph lock + high-quality resampler
user/                   headphone-switch.service/.sh (jack routing + speaker pin)
optional/               userspace smart-filter EQ (fallback only; not installed)
BLOBS.md                firmware provenance and licensing
```
