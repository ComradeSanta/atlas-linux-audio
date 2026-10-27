# Firmware/DSP blob provenance

The files under `firmware/` and the ChromeOS UCM in `ucm/` are **not** covered by
the repository's MIT license. They were extracted from an official ChromeOS
recovery image for the **Google Pixelbook Go (Atlas)** and are redistributed for
interoperability with the hardware they shipped on. They remain the property of
their owners (Google, Intel, Maxim, Waves Audio).

Reproduce them from your own Atlas recovery image; the paths are as shipped in
the image's `ROOT-A` partition.

| Repo file | ChromeOS path | What it is |
|---|---|---|
| `firmware/max98373-tplg.bin` | `/lib/firmware/intel/avs/max98373-tplg.bin` | Unmodified ChromeOS Atlas AVS topology (reference) |
| `firmware/max98373-tplg-cros-playback-only.bin` | same, edited | ChromeOS topology with the capture/echo-reference PCM and its DAPM routes removed (the mainline machine driver has one BE link). Installed as `intel/avs/max98373-tplg-cros3.bin`. |
| `firmware/skl/dsp_fw_spt_release.bin` | `/lib/firmware/intel/avs/skl/dsp_fw_spt_release.bin` | ChromeOS AVS base firmware (loaded as `dsp_basefw.bin`) |
| `firmware/skl/dsp_fw_spt_release_7CAD0808-AB10-CD23-EF45-12AB34CD56EF.bin` | same dir | ChromeOS AVS module loader (loaded as `dsp_mod_7CAD0808-….bin`) |
| `firmware/skl/dsp_lib_dsm_core_spt_release.bin` | same dir | Maxim DSM core DSP library |
| `firmware/skl/dsp_lib_waves5_9_spt_release.bin` | same dir | Waves MaxxAudio DSP library |
| `firmware/skl/dsp_mod_B489C2DE-0F96-42E1-8A2D-C25B5091EE49.bin` | same dir | Waves module binary requested by the topology |
| `firmware/skl/dsp_mod_C75061F3-F2B2-4DCC-8F9F-82ABB4131E66.bin` | same dir | DSM module binary requested by the topology |
| `firmware/dsmparam.bin` | `/opt/google/dsm/dsmparam.bin` | Maxim DSM speaker models (Re/Bl/excursion, protection parameters) |
| `firmware/wavesdata.bin` | `/opt/google/waves/wavesdata.bin` | Waves speaker tuning parameters |
| `ucm/avs_max98373-atlas.conf`, `ucm/avs_max98373-atlas-HiFi.conf`, `ucm/AVS I2S MAX98373.conf` | ChromeOS UCM `/usr/share/alsa/ucm2/.../avs_max98373/` | Amp calibration (BDE/DHT, output stage) transcribed into the mainline UCM; the `cset-tlv` blob loads and the `PlaybackMixerElem "DSP"` removal are our changes |

The topology edit removes the second `SectionPCM` element (`Echoreference
Capture`) and the three DAPM routes that reference it. Everything else —
manifest, libraries, pipelines, modules, bindings, playback PCM, SSP widgets —
is the ChromeOS file.

The UCM in `rollback/` is the pre-transplant **mainline** calibration profile
(not a ChromeOS blob) used by `rollback.sh`.

The driver overlay in `module/` is GPL-2.0 (Linux kernel); the rest of the code
is MIT. See `LICENSE` and `README.md`.
