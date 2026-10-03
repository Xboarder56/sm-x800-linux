# SM-X900 revision 5: S6TUUM1 AMSA46AS01 evidence

Updated, 2026-10-03. The inherited bootloader framebuffer produces a readable
uniLoader/simpledrm console. **Native panel takeover is not tested under
mainline Linux**.
The matching DYDC source files and hashes are recorded in
[the bring-up checkpoint](../../docs/14-gts8uwifi-bringup.md).

## Offline source and driver checks

The merged reference node is
`ss_dsi_panel_S6TUUM1_AMSA46AS01_WQXGA` (label and node name).
It contains separate 60 Hz and 120 Hz timing/command sets. Both command streams
match the earlier CYB1 research inputs; the proposed family driver compiles in
the r44/r46 kernel packages. Native panel takeover remains disabled for first boot.

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
driver byte for byte after renaming. The family driver now compiles. Still verify descriptor selection, mode,
DSC settings and shared lifecycle behaviour on hardware, and obtain X800
hardware regression testing before proposing that refactor upstream.

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
