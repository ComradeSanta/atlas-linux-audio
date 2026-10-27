# Optional: userspace speaker EQ (fallback)

The ChromeOS AVS/Waves DSP is the tone-shaping stage in this repo; do **not**
run this EQ together with it (double processing).

`52-atlas-speaker-eq.conf` is the reference WirePlumber smart-filter voicing
from the earlier userspace-only setup (HP 100 Hz, +3 @100, +2 @160, +1 @250,
−1.5 @500, −1.5 @3k, +1.5 @8k, +1 @12k). It is useful only if you roll back to
the stock topology and want a quick tonal fix.

```sh
install -m 0644 optional/52-atlas-speaker-eq.conf \
  ~/.config/wireplumber/wireplumber.conf.d/
systemctl --user restart wireplumber
```
