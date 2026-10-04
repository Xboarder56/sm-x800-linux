# SM-X900 revision 5: S6TUUM1 AMSA46AS01 evidence

Updated, 2026-10-03. The inherited bootloader framebuffer produces a readable
uniLoader/simpledrm console. **Native 2960x1848 display at 60 Hz also reaches
the postmarketOS debug screen on the attached DYDC tablet**. A brief black/white
flash during handoff remains; 120 Hz and display power cycling are unvalidated.
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
