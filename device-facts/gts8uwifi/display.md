# SM-X900 revision 5: S6TUUM1 AMSA46AS01 evidence

Updated, 2026-10-03. The inherited bootloader framebuffer produces a readable
uniLoader/simpledrm console. **Native 2960x1848 display at 120 Hz reaches the
postmarketOS debug screen on the attached DYDC tablet with a flash-free
handoff** (kernel package `7.2-r63`). Display off/on is not validated. The
60 Hz sections below record the earlier `7.2-r55` stage; the later sections
supersede their open points.
The matching DYDC source files and hashes are recorded in
[the bring-up checkpoint](../../docs/14-gts8uwifi-bringup.md).

## Offline source and driver checks

The merged reference node is
`ss_dsi_panel_S6TUUM1_AMSA46AS01_WQXGA` (label and node name).
It contains separate 60 Hz and 120 Hz timing/command sets. Both command streams
match the earlier CYB1 research inputs; the proposed family driver compiled in
the r44/r46 kernel packages. Native panel takeover was disabled for first boot.

The R1 `s6tuum1_amsa46_on()` DCS write payloads were compared programmatically
with the 120 Hz `qcom,mdss-dsi-on-command` packets. All DCS payloads match in
order. The other packet is compression-enable (type `0x07`, payload `01`).
The stream specifies a 50 ms delay after `60 20`; R1 carries that delay.

The payload written to register `0x9e` contains 88 PPS bytes. Decoding its
picture and slice fields gives:

| Field | Value |
|---|---|
| Picture width / height | 2960 / 1848 |
| Slice width / height | 1480 / 132 |
| Slices across the picture | 2 |

The stock reset property is `<0 2 1 1>` (low 2 ms, high 1 ms).
The 120 Hz timing properties specify horizontal front porch / pulse / back
porch of 200 / 200 / 200 and vertical values of 192 / 200 / 200.

R1 also inherits sleep-out, TCON readiness, power sequencing, brightness
handling and display-enable behaviour from the X800 implementation. Matching
the command stream does not validate those behaviours on X900. In particular,
check the downstream brightness encoding and normal/HBM paths before claiming
that the X800 brightness limits transfer unchanged.

The X800 reset/on function bodies in the R1 family driver match the base
driver byte for byte after renaming. The family driver compiles. X900 runtime
evidence is recorded below; obtain X800 hardware regression testing before
proposing that refactor upstream.

## Runtime and first-boot limits

On the attached DYDC tablet, `adb shell wm size` reports `1848x2960`.
That is Android's logical display orientation; it does not establish the
bootloader framebuffer's stride, format or scanout orientation. No `fb0`
geometry attributes were present under `/sys/class/graphics`.

The offline splash reservation is `[0xb8000000, 0xbab00000)` (43 MiB).
R1 assumes landscape 2960x1848, four bytes per pixel, at that base. R2–R8 and
R11 hardware photos confirm readable console output with this geometry,
format and base. This verifies the inherited framebuffer path; it does not
validate the native panel's init sequence, DSC or brightness encoding.
Keep native panel takeover separate from the first kernel-entry milestone.

## Native 60 Hz operation

The current AMSA46AS01 descriptor uses the stock 60 Hz command stream (`60 00`
with a 50 ms delay), reset sequence and 88-byte DCS PPS. The normal brightness
tables in the rev-5 stock DTB top out at DBV `0x7ff`; the driver retains an
11-bit range and the little-endian `0x51` encoding. Runtime backlight value
1496 produces visible output. HBM and the full brightness curve are untested.

Using only the inherited X800 display-enable command left the native screen
black despite a registered framebuffer and completed DPU frames. Adding X900's
stock `samsung,first_display_on_tx_cmds_revA` (`f8 58 00 d0 1d`, then
`f9 00 00 00 00`) before display-on (`29`, 17 ms wait) restored the debug screen.
The subsequent build without temporary register dumps gives the same result.
Both boots have a brief black/white flash at handoff before readable output;
one also showed a purple line. Its cause remains unresolved.

The cleaned driver is kernel package `7.2-r55`. It reports TCON ready after
350 ms, native `msmdrmfb` at 2960x1848 and backlight 1496. DPU frame-completion
and TE interrupts advance with no captured underrun, external abort or Oops.
The user confirms readable Linux and the postmarketOS keyboard. USB remains
configured; the debug shell mounts only RAM/virtual filesystems. These checks
validate initial display operation, not touch, suspend/resume or panel blanking.
The X800 reset/on/enable commands and delays are unchanged after the refactor.

The direct stock 120 Hz porch translation gives a 1,042,368 kHz DRM mode.
Mainline rejects it with `CLOCK_HIGH` before panel initialization: its adjusted
per-mixer requirement is 547,243 kHz, above the 500 MHz DPU limit. Stock command
mode specifies a separate 7,533 us transfer time and 1,530 MHz lane bit clock;
these require a mainline timing translation rather than raising the DPU limit.
Only 60 Hz is exposed until that translation is tested.

The BOOT-only image has SHA-256
`20b71cda0047c9eb8f037a1560d3623891cc20087d5c7c7713670e12023a48b0`.
Build, memory/payload audits and USB captures remain local in
`root-build/gts8uwifi-debug-r28-clean-panel/` and `root-build/kernel-r55/`.

## Vendor driver reference

The Samsung kernel source for this tablet family is public
(`Samsung_Kernel_sm8450_common_gts8x`, `techpack/display/msm/`). The panel file
`samsung/S6TUUM1_AMSA46AS01/ss_dsi_panel_S6TUUM1_AMSA46AS01.c`, `dsi/dsi_panel.c`
and `dsi/dsi_clk_manager.c` were read for behaviour the stock DTB does not
describe. A local copy is kept under `root-build/vendor-display-src/`.

## Bootloader handoff

Three separate effects produced the startup flash and intermittent dark boots.

**SMMU faults.** ABL leaves the DPU scanning the splash buffer out in command
mode. Mainline has no identity-domain entry for `qcom,sm8450-mdss`, so every
fetch faulted once MDSS joined its IOMMU group:

```
platform ae00000.display-subsystem: Adding to iommu group 6
arm-smmu 15000000.iommu: Unhandled context fault: fsr=0x402, iova=0xb8e41200,
  fsynr=0x700021, cbfrsynra=0x2800, cb=5
```

`arm-smmu-qcom-sm8450-mdss-identity.patch` gives MDSS an identity default
domain; the DTS also marks the splash buffer as a reserved 1:1 region for
kernels without it. With both, the group type reads `identity` and no fault
is logged.

**Warm reset of a running TCON.** Stock `tcon_prepare()` returns without
resetting when cont-splash is active or `tcon_rdy` is already high. Mainline
pulsed reset on the running panel at every boot. Of roughly fifteen such
initialisations, about half ended with a dark panel while the DPU kept
completing frames; where it was sampled, `tcon_rdy` had dropped within a
second. Most of those ran with L13C still at 3.0 V and the cause was not
isolated further. The driver now adopts the running panel on the first prepare
and only sends the refresh select.
`tcon_rdy` also goes low after sleep-in (`0x10`); low means asleep, not failed.

**Supply cut at display-off.** Stock's always-on-touch path does not assert
reset or drop the panel supply at display-off. Cutting only `panel_ldo_en`
(GPIO34) with the other rails up left the panel driving a bright white,
purple-tinged field, the earlier "extremely white screen". The X900 variant
now stays powered with reset released.

## Tearing effect and 120 Hz

Polling GPIO86 directly gave the following; the vendor driver documents the
same two TE shapes.

| State | TE on GPIO86 |
|---|---|
| Bootloader state | 60.4 Hz, high for 8.3 ms per frame |
| After the inherited `35 00` tear-on | no edges |
| After `35` with no parameter | pulses restored |
| `60 20` | 120.9 Hz, about 0.1-0.23 ms pulses |
| `60 00` | 60.4 Hz, high for 8.3 ms per frame |

With TE absent the DPU's tear-check counter free-runs at
`vsync_clk / (vsync_count * 2 * vtotal)`: 60.5 Hz in the 120 Hz mode. Frame and
"TE" interrupt counters still advance in that state, so they do not show that
tearing sync works. DCS reads are valid after a full init (`0A` = `1c`, `52`
returns the written brightness) but return `f0` in the adopted state, where
writes still take effect.

The 120 Hz mode uses blanking chosen for the stock lane rate: h 48/32/58,
v 16/8/16, 701,882 kHz. The DSI host derives 1,529 Mbit/s per lane, matching
stock's 1,530. Measured with the r63 package: vblank 120.8 Hz, 120.4 completed
frames per second under continuous fbdev updates, no underrun or frame-done
timeout.

## Rails and the display boost

Stock constrains PM8350C L13C to 1.8 V on X900 and lists no active consumer.
The X800-derived tree held it at 3.0 V; it is now described at 1.8 V and left
in its bootloader state. What it feeds on this board is unknown.

Stock programs a MAX77816 buck-boost at I2C 0x18 on `i2c@998000` before each
panel reset: register `0x03 = 0x70` (enable, GPIO function off) and
`0x02 = 0x8e` (3.1 A limit), "to reduce the voltage drop". ABL leaves those
values in place and they survived TCON resets and sleep here, so mainline does
not drive the part yet. Its interrupt register showed a power-OK event after
sleep/wake attempts.

## Open: display off/on

- Blanking through fbdev resets the tablet about 14 s later with no kernel
  message, the signature of a panic followed by the test image's `panic=10`
  reboot. Blanking with fbcon detached from the framebuffer survives.
  Holding the UFS PHY rails or the display power domains on does not help.
- A wake from sleep-in (reset, wait for `tcon_rdy`, init) left `tcon_rdy` low
  again in the one attempt made. Stock sends no sleep-out (`0x11`) in this
  path and reprograms the boost first; neither difference has been tested.
- Boots following an unclean reset sometimes start with bootloader-stage
  artifacts. Normal reboots on the r63 package came up clean.

