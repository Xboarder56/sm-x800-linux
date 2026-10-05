# SM-X900 revision 5: bus and device audit

Recorded 2026-10-05. The left side is every enabled bus and child device
in the rev-5 stock device tree (DYDC); the right side is what Linux on
kernel `7.2-r90` sources has described and bound. "Not described" means
the mainline tree has no node for it, so nothing has been probed there.

## I2C, by stock controller

| Stock bus | Stock device | Linux |
|---|---|---|
| `i2c@984000` (SE1) | `sm5440@63`, SiliconMitus direct charger for the 45 W path | Not described. Charging uses the MAX77705 only |
| `i2c@988000` (SE2) | rear lens actuator `0x18` (7-bit `0x0c`), rear module EEPROM `0x58` | `i2c-2`: `dw9807` and `at24` bound |
| | front EEPROM (`qcom,eeprom51`), front ultrawide EEPROM (`qcom,eeprom8`) | Not described |
| `i2c@990000` (SE4) | four CS35L45 at `0x30` to `0x33` | `i2c-3`: all four bound |
| | `synaptics_tcm@20`, a second touch controller node | Not described; whether the part is fitted is unknown (touch is the Goodix below) |
| `i2c@994000` (SE5) | `max77705@66` (top, CCIC `0x25`, charger `0x69`, gauge `0x36`) | `i2c-4`: MFD, Type-C, charger and gauge all bound |
| `i2c@998000` (SE6) | `display_boost@18`, MAX77816 buck-boost | Not described. Stock programs it before each panel power-on; the panel works without |
| `i2c@a80000` (SE8) | `touchscreen@5d`, Goodix Berlin (GT6936) | `i2c-5`: bound |
| `i2c@a90000` (SE12) | `ps5169@28`, Parade USB 3 / DisplayPort redriver | Not described. Needed for SuperSpeed and video out |
| `i2c@a94000` (SE13) | `k250a@23`, Samsung secure element | Not described, not planned |
| `i2c@a98000` (SE14) | `wacom@56`, S Pen digitizer | `i2c-0`: bound, on bit-banged GPIO I2C |
| `i2c@88c000` (SE18) | `stm32@2a`, keyboard-cover controller | `i2c-1`: bound; no cover has been attached |

## Camera control (CCI)

| Bus | Device | Linux |
|---|---|---|
| CCI0 master 0 | Hi847 rear ultrawide, `0x21` | `i2c-6`: bound |
| CCI0 master 1 | Hi1337 rear main, `0x21` | `i2c-7`: bound |
| CCI1 master 0 | Hi1337 front ultrawide, `0x21` | `i2c-8`: bound |
| CCI1 master 1 | Hi1337 front, `0x20` | `i2c-9`: bound |

The two front addresses were found by scanning each bus with the module
powered. All four stream; the frames hold no pixel data yet.

## Serial, SPI, SPMI

| Stock | Linux |
|---|---|
| UART SE7 (`99c000`), debug console | earlycon only |
| UART SE20 (`894000`), Bluetooth | `serial0-0`, hci0 |
| SPI | none enabled in stock; none in Linux |
| SPMI `c42d000`: PMK8350 (0), PM8350 (1), PM8350C (2), PMR735A (4), PMR735B (5), PM8450 (7) | 0, 1 and 2 as SPMI devices. The other three only through RPMh regulators: no ADC, thermal or GPIO from them |

## Other

| Function | Linux |
|---|---|
| PCIe0, WCN6855 Wi-Fi | bound (ath11k) |
| USB | USB 2 dual role through the MAX77705 CCIC; the SuperSpeed PHY is off |
| microSD, UFS | `mmc0`, six UFS LUNs |
| Remote processors | ADSP and SLPI run. CDSP and the modem (which holds the GNSS receiver) are not started |
| Video decoder and encoder | Not described |
| Thermal | 35 zones: SoC sensors, PM8350, PM8350C, two thermistors, battery |
| Inputs | power and volume-down (PON), volume-up and two hall switches (gpio-keys), touch, S Pen, headset jack |
| Fingerprint | stock has `qcom,qbt_handler` and the panel flag `samsung,support-optical-fingerprint`; no node on any I2C or SPI bus, the sensor is driven from the secure world. No mainline support |

## Read from this

Nothing that has a mainline driver and matters for daily use is missing
from the I2C side. The undescribed parts are the direct charger (only for
charging above 15 W), the display boost, the USB 3 / DisplayPort redriver,
two camera EEPROMs and the secure element. The larger gaps are whole
subsystems: SuperSpeed and video out, the modem for GNSS, and the video
codec.

## Feasibility of the larger gaps

Looked at on 2026-10-05, nothing built.

| Item | What stock uses | What mainline 7.2 has | Verdict |
|---|---|---|---|
| Video out over USB-C | Samsung's `secdp` DisplayPort driver, the PS5169 redriver, AUX enable and select GPIOs, alt mode negotiated by the MAX77705 CCIC | The DP controller and the USB 3 / DP combo PHY are in `sm8450.dtsi`. No PS5169 driver; the port's CCIC driver has no alt-mode support; the SuperSpeed PHY is off on this board | Large: PHY bring-up, a redriver driver, alt mode in the CCIC driver |
| GNSS | The modem processor (the Wi-Fi model still carries one for location) | `remoteproc_mpss` is in `sm8450.dtsi`; ModemManager can read a QMI location service | Medium: needs the modem firmware and a read-only `rmtfs`, which touches modem partitions on UFS |
| Hardware video decode | Iris/Venus video core | The venus and iris drivers list SM8250, SM8550, SM8650 and SM8750, not SM8450; no node in `sm8450.dtsi` | Not available without adding SM8450 platform support to a driver |
| Gyroscope | Sensor hub | `libssc` offers proximity, light, accelerometer, magnetometer and compass only | Needs gyroscope support in `libssc`; nothing on the desktop uses it |
| Auto-brightness | Sensor hub light sensor | The light sensor reads through `iio-sensor-proxy`; this Plasma's power manager has no ambient-light setting | Small: a helper that maps lux to backlight |
| Fingerprint | Optical in-display sensor driven from the secure world | Nothing | Not feasible |
