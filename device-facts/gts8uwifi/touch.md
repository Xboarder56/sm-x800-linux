# SM-X900 revision 5: Goodix GT6936 touchscreen evidence

Updated, 2026-10-03. **The touchscreen works on the attached DYDC tablet with
kernel package `7.2-r63`**: the postmarketOS initramfs keyboard registers the
key under the finger.

## Stock wiring

From the rev-5 stock DTB node `touchscreen@5d` (`goodix,berlin`):

| Item | Value |
|---|---|
| Bus | `i2c@a80000` (mainline `i2c8`), address `0x5d`, GPIO28/29, 2 mA, pull-up |
| Interrupt | TLMM GPIO46, falling edge, no pull |
| AVDD | PM8350C L7C, 3.3 V |
| VDDIO | PM8350C L8C, 1.8 V |
| Coordinates | `sec,max_coords` 1848 x 2960 (portrait) |
| Reset GPIO | none |
| Firmware | `tsp_goodix/gt6936_gts8u.bin` (resident firmware is used; none is loaded) |

The X800-derived tree carried a 3.0-3.3 V range for L7C and 1.848 V for L8C.
BOB, the parent of L7C, was lowered to 3.032 V by Linux because the RPMh
regulator driver does not raise a parent for LDO headroom; it is now held at
the stock 3.296 V init voltage.

## Findings

- ABL leaves both touch rails off. With the bus enabled and the controller
  unpowered, SDA and SCL read low and transfers time out; that, not the GPI
  DMA engine, explains the earlier failed raw reads. Enabling L8C alone brings
  the bus lines high.
- The firmware version block at `0x10014` reads `BERLIN`, PID `6936`. Its
  IC_INFO advertises 8-byte points while events use Samsung's 16-byte SEC
  records. `goodix-berlin-samsung-events.patch` selects that parser by PID.
- The controller pulls its interrupt line low after power-up; the line was
  high again after the first I2C read. Binding the driver with the controller
  already powered and the line low still delivered that event.
- Raw corner taps on the landscape display: top-left (1821, 32), top-right
  (1813, 2934), bottom-right (31, 2916), bottom-left (55, 59). The DTS inverts
  X and swaps the axes.

## Validation and limits

Corner taps span the full raw range, drags track, and two contacts use
separate slots with releases (10 contacts, 9 lifts in one capture). Built in,
the driver probes about 3 s into boot and delivers interrupts from a cold
start. Pen and palm events, more than two contacts, suspend/resume and firmware
update are untested. The first hand-loaded attempt recorded no events; whether
the screen was being touched then is uncertain, and it has not recurred.
