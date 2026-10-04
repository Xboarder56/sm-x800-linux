# SM-X900 revision 5: audio evidence

Recorded 2026-10-04 with nobody at the tablet: every result below is a
measurement through the tablet's own microphones, not something heard.
The X800 story this follows is in [docs/10](../../docs/10-audio.md).

## Wiring

The rev-5 stock tree has the audio where the X800 does:

| Part | Stock X900 |
|---|---|
| Amplifiers | four CS35L45 on `i2c@990000`: 0x30 rear-left, 0x31 front-left, 0x32 rear-right, 0x33 front-right; reset TLMM 18, interrupt TLMM 19 |
| Amplifier interface | primary MI2S/TDM: clock 126, sync 129, `mi2s0_data0` 127 (in), `mi2s0_data1` 128 (out) |
| Microphones | three DMIC pairs on LPI gpio 6/7, 8/9 and 12/13; `qcom,wcd-disabled` |

All four amplifiers report `REVID A0 OTPID 0B`. The card registers as
`Samsung-Galaxy-Tab-S8-Ultra` with the X800's topology file under that name
(the HDK topology with the I2S line moved to SD1, see `tools/mk-tplg.py`).

## Measurements

A 3 s file with 1 kHz at -30 dBFS on the left channel and 1.5 kHz on the
right was played while `MultiMedia3` recorded two DMICs. The table is the
magnitude of each tone in the recording, in 16-bit counts, with the X800
mixer settings and `Digital PCM Volume` 360.

| Enabled amplifier | 1 kHz (capture ch1 / ch2) | 1.5 kHz (ch1 / ch2) |
|---|---|---|
| none, no playback | 0.1 / 0.1 | 0.0 / 0.0 |
| Front Left | 25.4 / 69.4 | 0.1 / 0.0 |
| Rear Left | 33.8 / 53.4 | 0.0 / 0.1 |
| Front Right | 0.0 / 0.1 | 4.0 / 25.3 |
| Rear Right | 0.2 / 0.1 | 9.9 / 16.7 |
| all four | 17.9 / 121.0 | 13.4 / 41.8 |

Each amplifier plays, and the left pair carries the left channel and the
right pair the right. Capture ch1 was `DMIC1`, ch2 `DMIC3`.

Selecting each VA DMIC input in turn with all four amplifiers playing:

| Input | RMS | 1 kHz | 1.5 kHz |
|---|---|---|---|
| `DMIC0` | 0.0, every sample zero | 0.0 | 0.0 |
| `DMIC1` | 23.6 | 17.2 | 14.0 |
| `DMIC2` | 93.1 | 122.3 | 42.0 |
| `DMIC3` | 92.8 | 122.0 | 41.8 |
| `DMIC4` | 91.1 | 124.9 | 20.6 |
| `DMIC5` | 91.5 | 125.5 | 20.4 |

With no playback the two captured channels sit at 15-17 counts RMS. Three
distinct microphones answer: one on `DMIC1`, one on `DMIC2`/`DMIC3` and one
on `DMIC4`/`DMIC5`.

## Not done

- Nobody listened: distortion, rattle and how loud the cap is are unknown.
  The speaker-protection firmware is not loaded, as on the X800.
- The X900 device package has no topology file, UCM profile or the
  amplifier no-hibernate rule; the test used the X800's topology under the
  Ultra's card name and set the mixer by hand.
- Which physical microphone is which input, and why two inputs pair up.
- Headset jack detection (the card registers one), suspend/resume.
