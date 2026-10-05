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

## Charger and dual-role port, enabled

Kernel `7.2-r89` enables the charger and the dual-role Type-C port as on
the X800, with the owner's go-ahead. Plugged into a PD hub the port
reports sink and device, negotiates 9 V 3 A, and the charger sets a
1.65 A input limit (15 W). The role switch reads device, the gadget and
serial login work, and the OTG regulator is off. At 98 to 99 % the
charger reports `Full` at its 4.30 V limit and the battery carries part
of the load as it settles (0.5 to 0.8 A out, 26.0 °C). Host mode, VBUS
out and a charge from a lower state of charge have not been exercised.

## What stock charging does, and what native speed would take

Stock has two charging paths (rev-5 device tree, battery node):

| | Switching charger (MAX77705) | Direct charger (SM5440) |
|---|---|---|
| Used with | any PD or legacy source | a PPS source, "45 W" |
| Input | 9 V, 3.0 A limit, 15 W for PD (`pd_charging_charge_power`) | PPS, 2:1 conversion |
| Charge current | 3.15 A (`max_charging_current`) | 8.4 A (`dc_step_chg_val_iout`), 22 W step |
| Float | 4.42 V | 4.42 V |

and a policy around them:

| Battery temperature | Charge current | Float |
|---|---|---|
| below 5 C | 1.075 A | 4.42 V |
| 5 to 15 C | 2.875 A | 4.42 V |
| 15 to 42 C | 3.15 A | 4.42 V |
| 42 to 50 C | 3.15 A | 4.20 V |
| above 50 C, or far below 0 C | none | |

| Cycles | Float |
|---|---|
| up to 300 | 4.42 V |
| 300 | 4.40 V |
| 400 | 4.38 V |
| 700 | 4.36 V |
| 1000 | 4.31 V |

The charger IC's own temperature limits the input to 1.0 A and the charge
to 1.9 A at 80 C. Direct charging stops at 51 C charger temperature or
38 C battery temperature and is limited to 2.1 A in, 4.2 A out when warm.

Mainline today: the 9 V, 15 W input is already negotiated, the charge
current is 2.0 A and the float 4.30 V, with no temperature policy. That is
about two thirds of stock's ordinary PD rate and stops near 90 %.

To reach stock's ordinary rate (15 W in, 3.15 A, 4.42 V) safely:

1. The temperature bands above. The driver takes one current and one
   voltage from the battery node. `constant_charge_current` and
   `input_current_limit` are writable at run time; `constant_charge_voltage`
   is not, so the warm band's 4.20 V needs a small driver change.
2. Something to apply them: a guard that reads the gauge's temperature and
   cycle count and sets current and float, with the device tree's limits
   staying at today's conservative values so that a stopped guard means
   slow charging, not unguarded charging.
3. The age table, from the gauge's cycle count (109 on this tablet).
4. A watched charge from a low state of charge through termination, with
   current, voltage and temperature logged, before any of it ships.

The 45 W path is a different size of job: a driver for the SM5440 (none in
mainline), PPS requests through the MAX77705 CCIC firmware, and the
regulation loop that steps the source voltage while watching battery
current, with stock's direct-charging thermal tables. It should not be
attempted without a way to measure the pack.

## Open

- A charge from a lower state of charge through to termination has not
  been watched; neither has host mode with an accessory.
- Stock steps the float voltage down with age and by temperature; mainline
  does neither, which is why the limits stay below stock's.
- `swclock-offset` is not yet a dependency of the X900 device package.
- Suspend power draw, and why the SoC's sleep counters stay at zero.
