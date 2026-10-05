# SM-X900 revision 5: battery and charger evidence

Recorded 2026-10-04 with the charger and fuel-gauge nodes still disabled.
Nothing in the first three sections changed what the tablet does with its
battery. The later sections record the gauge being enabled (kernel
`7.2-r86`), a supervised charger test that is not in the tree, and system
suspend.

## What runs today

The MAX77705 MFD and its Type-C function are enabled as a 5 V sink; the
charger (`0x69`) and fuel gauge (`0x36`) answer on `i2c@994000` but have no
driver bound. Charging is whatever the bootloader left programmed.

Reading the gauge's registers directly after many hours on a Mac's USB
port, mostly idle with the panel blanked:

| Register | Raw | Meaning |
|---|---|---|
| `0x09` VCELL | `0xd8b8` | 4.334 V |
| `0x06` RepSOC | `0x63c7` | 99.8 % |
| `0x0a` Current | `0xfffd` | about zero |
| `0x08` Temperature | `0x1a19` | 26.1 °C |
| `0x10` FullCapRep | `0x1069` | 10,502 mAh at 2.5 mAh per count |
| `0x18` DesignCap | `0x0f3f` | 9,757 mAh, equal to stock `battery0,capacity` |
| `0x17` Cycles | `0x2ac3` | about 109 |

So the bootloader's charger state keeps the battery full and then idles.
The Type-C supply reports online, 5 V, 3 A maximum, PD.

## Stock description against the inherited one

| Item | X900 stock | Inherited X800 `battery` node |
|---|---|---|
| Sense resistor | `fuelgauge,fg_resistor = <5>`, 2 mΩ | `shunt-resistor-micro-ohms = <2000>` |
| Full capacity | `battery,battery_full_capacity` 10,880 mAh | 8,800 mAh |
| Float voltage | `battery,chg_float_voltage` 4.420 V | 4.300 V constant-charge maximum, 4.380 V design maximum |
| Charge current | `battery,max_charging_current` 3.15 A | 2.0 A |
| Input limit | 3.0 A, 9 V | Type-C held at 5 V |
| Recharge threshold | 4.350 V | not described |
| Direct charger | SM5440, for the 45 W path | not described |

The sense resistor matches. The capacity is wrong for this tablet. The
inherited voltage and current limits are lower than stock's, so they err on
the safe side. Stock steps the float voltage down with age (4.420, 4.400,
4.380, 4.360, 4.310 V at 0, 300, 400, 700 and 1000 cycles); mainline has no
equivalent.

## Fuel gauge, enabled for reading

`7.2-r86` enables the gauge without its reference to the charger. It
registers as `max170xx_battery`: 99 %, 4.33 V, 26.0 °C, `charge_full`
10,502 mAh, `charge_full_design` 9,757 mAh, the same values as the raw read
above. `STATUS` is `0x0080`, no power-on-reset bit, so the driver loads no
model. Of 28 registers read before and after the driver bound, the only
configuration change is `SALRT_Th` (`0xff01` to `0x6462`, the driver's
1 % SOC alerts). `FullSOCThr` stays at stock's `0x5d00`.

`cycle_count` reports the raw register, 10947, for about 109 cycles.
`status` is `Unknown` without a charger.

## Charger, one supervised test

Not in the tree. With the owner present, a test build enabled
`charger@69` at the battery node's limits, leaving Type-C at 5 V.

| Register | Bootloader | Mainline driver |
|---|---|---|
| `CNFG_00` `0xb7` | `0x05`, buck and charge | `0x05` |
| `CNFG_02` `0xb9` | `0x5e`, 1.5 A | `0x68`, 2.0 A |
| `CNFG_04` `0xbb` | `0x13`, 4.35 V | `0x0e`, 4.30 V |
| `CNFG_09` `0xc0` | `0x3b`, 1.5 A input | `0xbb`, 1.5 A input |
| `CNFG_03`, `05`, `08`, `12` | `0x99 0x60 0x00 0x68` | `0x98 0x68 0x02 0x60` |

The bootloader's float is 4.35 V, stock's recharge threshold, not the
4.42 V full-charge figure. The driver reported `Full`, 4.30 V, 2.0 A and a
1.5 A input limit. With the battery at 4.33 V, above the new float, the
battery carried the tablet: 4.30 V and 0.46 to 0.65 A out of the battery for
the six minutes watched, 26.0 °C throughout. No charging was seen, because
the battery was full. On the next boot the bootloader put its own values
back (`0xb9` and `0xbb`), and three of the driver's other settings were
still there (`0xbc`, `0xbf`, bit 7 of `0xc0`).

Still to see before the charger is enabled in the tree: a charge from a
lower state of charge through to termination, with current and temperature
watched.

## System suspend

Needs the RTC (`7.2-r84`) for a timed wake. On a test build with
`CONFIG_PM_DEBUG`, every `pm_test` stage passed: freezer, devices and
platform for s2idle; devices, platform, processors and core for deep. Real
suspends, 20 s each with the RTC alarm as the wake source, came back from
both s2idle and deep (PSCI system suspend) with no failed device, Wi-Fi
still associated and both remote processors running. From the Plasma
session the power key suspended and woke the tablet; the owner called the
wake a bit slow, and the log shows about 2 s between the last CPU coming up
and tasks restarting.

The SoC did not reach its own low-power states: `qcom_stats` `aosd`, `cxsd`
and `ddr` counts stayed at 0, with USB attached. What it draws while
suspended has not been measured.

The RTC is read only and reads 1974 on this tablet. With its driver built
in and `swclock-offset` installed by hand, the clock was correct after a
clean reboot without network.

## Open

- Enabling the charger hands input and charge current control to the
  mainline driver. The probe has been watched once at full charge (above);
  a charge from a lower state of charge has not.
- Stock steps the float voltage down with age and by temperature; mainline
  does neither, which is why the limits stay below stock's.
- `swclock-offset` is not yet a dependency of the X900 device package.
- Suspend power draw, and why the SoC's sleep counters stay at zero.
