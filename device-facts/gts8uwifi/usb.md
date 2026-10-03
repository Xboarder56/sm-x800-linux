# SM-X900 USB evidence

Device: Galaxy Tab S8 Ultra Wi-Fi, SM-X900 / gts8uwifi, board revision 5,
firmware X900XXU9DYDC. Sources are the locally merged DYDC stock DTB and
the pinned Linux 7.2 driver/binding sources. Stock blobs remain in ignored
`root-build/stock-dydc/`; the merged DTB SHA-256 is
`f3fc4a71ac20f6306a588eb6ed79b82e225a5508443c756445433cf3fedb083c`.

## What hardware tests establish

Samsung Download Mode enumerates on this Mac and BOOT-only Heimdall flashes
succeed. That establishes a working cable and transport in Download Mode.
It does not establish Linux gadget operation.

The restored R8 photo (`IMG_5644.JPG`) shows the Linux UDC `a600000.usb`,
successful binding of the ACM gadget, and repeated diagnostic heartbeats.
macOS did not enumerate that R8 gadget during the observations.

R11 retains R8's descriptors and loader layout, adding only UDC state/speed
prints. The user's photo shows `not attached` / `UNKNOWN` at 3.54 seconds,
then `configured` / `high-speed` at 23.55 seconds. macOS detects VID `0x18d1`,
PID `0xd001`, configuration 1, at 480 Mbit/s and creates a USB modem port.
An interactive root shell works over that ACM port; runtime logs and a
checksum-verified 11.8 MB RAM-only transfer were captured. The user also
reseated USB during this boot. This proves USB2 device/ACM operation on R11;
the cause of the earlier missing enumeration is not isolated. USB networking,
SSH, host mode and SuperSpeed remain unverified.

## Controller and PHY

The stock `/soc/ssusb@a600000` uses the downstream Qualcomm glue and a
`dwc3@a600000` child. Mainline 7.2 uses the flattened SM8450 DWC3 binding.
The core interrupt is SPI 133 (`0x85`) in both trees. The PHY is at
`0x088e3000`; its reset is GCC reset 21 (`0x15`). R8 enables only this USB2
PHY, limits the controller to high speed, and selects UTMI as its pipe clock.

Stock PHY supplies resolve to PM8350 L5 (0.88 V), PM8350C L1 (1.8 V), and
PM8350 L2 (3.07 V), matching the experimental board's PHY supplies. The
stock driver also maps `eud_enable_reg` at `0x088e2000`, and the stock tree
enables its EUD node. The mainline PHY does not map that second resource.
This difference is recorded for investigation; no live EUD state has been
captured and it is not an established cause of the missing link.

Linux 7.2 `drivers/usb/dwc3/dwc3-qcom.c` enables its VBUS-valid override in
fixed peripheral mode and again through the gadget run/stop notifier.
The absence of the MAX77705 role-switch driver alone therefore does not
prove that DWC3 lacks a software attach signal.

## Stock PHY tuning absent from the experimental DTS

The stock `/soc/hsphy@88e3000` contains these value/offset pairs:

```dts
qcom,param-override-seq = <0x03 0x6c 0x0f 0x70 0x1f 0x74 0x03 0x78>;
qcom,param-host-override-seq = <0xe7 0x6c 0x0b 0x70 0x2f 0x74 0x03 0x78>;
```

These downstream properties are not accepted by the mainline binding.
The mainline `phy-qcom-snps-femto-v2.c` uses the same four override offsets
and supports individual tuning properties for the `qcom,usb-snps-hs-7nm-phy`
fallback compatible used by SM8450. Decoding the **device-mode** bytes
through that driver's masks and lookup tables gives:

| Mainline property | Stock field | Matching value |
|---|---|---|
| `qcom,hs-disconnect-bp` | `0x6c[2:0] = 3` | `630` |
| `qcom,squelch-detector-bp` | `0x6c[7:5] = 0` | `1590` |
| `qcom,hs-amplitude-bp` | `0x70[3:0] = 15` | `2670` |
| `qcom,pre-emphasis-duration-bp` | `0x70[5] = 0` | `20000` |
| `qcom,pre-emphasis-amplitude-bp` | `0x70[7:6] = 0` | `40000` |
| `qcom,hs-rise-fall-time-bp` | `0x74[1:0] = 3` | `-4100` |
| `qcom,hs-crossover-voltage-microvolt` | `0x74[3:2] = 3` | `0` |
| `qcom,hs-output-impedance-micro-ohms` | `0x74[5:4] = 1` | `2600000` |
| `qcom,ls-fs-output-impedance-bp` | `0x78[3:0] = 3` | `0` |

All nine exact values fall within
`Documentation/devicetree/bindings/phy/qcom,usb-snps-femto-v2.yaml`.
This is a translation of the stock configuration, not runtime validation.
R8/R11 do not set these overrides; their PHY reset defaults have not been
read. Host-mode bytes differ, so a device-mode translation alone cannot
establish correct tuning for dual-role operation.

## MAX77705 data routing

The stock board describes MAX77705 at `/soc/i2c@994000/max77705@66`.
The existing X800 patch `max77705-typec-source-attach.patch` records that its
MUIC switch remained open despite a powered USB host partner. Sending
`CTRL1_W` opcode `0x06` with `COM_USB=0x09` routed D+/D- to the PHY and
enumerated the mouse. The patched driver's data-role setter performs that
routing for both roles.

This is sibling hardware evidence, not an SM-X900 measurement. The X900
debug DTS currently disables the MAX77705 bus and driver, and its live
switch state is unknown. R11's working ACM link shows that enabling that
driver is not required for this observed boot. If a later boot remains not
attached, capture the CCIC/MUIC state before attributing the failure to PHY
tuning or enabling the complete PD/charging driver. Preserve the working
R8/R11 controls for comparison.
