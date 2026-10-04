# SM-X900 revision 5: battery and charger evidence

Recorded 2026-10-04 with the charger and fuel-gauge nodes still disabled.
Nothing here has changed what the tablet does with its battery.

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

## Open

- Enabling the gauge alone needs its `power-supplies` reference to the
  disabled charger dropped. The mainline driver may rewrite alert and
  configuration registers the bootloader set up.
- Enabling the charger hands input and charge current control to the
  mainline driver. That should be done with someone watching current and
  temperature, not unattended.
- `battery` should carry the X900 capacity before either is enabled.
