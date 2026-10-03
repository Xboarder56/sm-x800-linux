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

After Download Mode, the MAX77705 data switch is open even though its
firmware reports a sink/UFP connection. On the attached DYDC tablet:

| Register or mailbox response | Before routing | After routing |
|---|---|---|
| CC_STATUS0 (`0x0a`) | `0xb1` (sink) | — |
| PD_STATUS1 (`0x0d`) | `0x57` (UFP/device) | — |
| CTRL1, read with opcode `0x05` | `0x3f` (open) | `0x09` (USB) |
| UDC state / speed | `not attached` / `UNKNOWN` | `configured` / `high-speed` |

Sending `CTRL1_W` opcode `0x06` with `COM_USB=0x09` connects D+/D- to the
PHY. Two BOOT-only diagnostic boots attached and provided an interactive
ACM root shell without a cable replug. The stock-confirmed I2C controller
is `994000.i2c`; its adapter is under `/sys/bus/i2c/devices`, not the removed
`/sys/class/i2c-adapter` path. PMIC ID/revision read `0x15` / `0x02` (PASS2).
CCIC hardware revision is `0x1a`, firmware revision `0x5f`, raw minor byte
`0x48` (the driver's version mask reports `5F.00`). Captures are in
`root-build/gts8uwifi-debug-r18-muic/`, including the repeat boot and PMIC ID.

The existing patched `max77705-usbc` kernel driver performs the same routing
when setting its data role. With the MFD and Type-C clients enabled, a
BOOT-only test attaches without userspace I2C commands or a replug. Both
drivers bind, the Type-C port reports sink/device, and its power supply
reports 5,000,000 microvolts. Charger and gauge clients stay disabled;
omitting their supply/reference keeps the Type-C driver's PD policy at 5 V
and provides no OTG boost control. This is USB2 device support; host mode,
SuperSpeed, USB networking, SSH and charger/gauge operation remain unverified.
Kernel-driver captures are in `root-build/gts8uwifi-debug-r19-typec/`.
Package `7.2-r51` reproduces initial USB attachment and readable Linux text
with no userspace routing or automatic Download Mode timeout. Its BOOT
SHA-256 is `ed4f3ffcfc40b0a50277086daea67c667380a195e499f7ef387dbd9ee8fe0594`;
the capture is in `root-build/gts8uwifi-debug-r21-typec-package/`.

The single 5 V PDO retains stock capability flags (`0x3601912c`). A test
changing only those flags to USB communication alone (`0x0401912c`) left
Linux, its framebuffer and USB running but blanked the inherited scanout.
Restoring the original value restored visible text. This is an observation,
not an established explanation of the display/firmware interaction; revisit
the flags when native display owns the hardware.

macOS enumerates VID `0x18d1`, PID `0xd001`, configuration 1, at 480 Mbit/s
and creates a USB modem port. An earlier ACM test also transferred an
11.8 MB ramdisk to RAM with a matching checksum. UFS filesystems remain
unmounted during these diagnostic tests.

The failed gadget/controller resets help distinguish this routing fault:
unbinding/rebinding the ACM gadget and removing/reprobing DWC3 did not
restore attachment while the switch was open. In the controller-reset test,
PHY offsets `0x58`, `0x60`, `0x64`, `0x94` read `0x3b3b3b3b`, `0x01010101`,
`0x06060606`, `0x00000000`; QSCRATCH HS PHY control stayed `0x10100000`.
Those values also remain unchanged when routing alone restores attachment.
EUD enable at `0x088e2000` is zero before a replug during the failure, so
an active EUD was not its cause. Captures are in
`root-build/gts8uwifi-debug-r15-usb-reset/` and the user's `IMG_5654.JPG`.

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
The live EUD enable bit is already clear during the initial attachment
failure, as described above.

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

The SM-X900 measurements above now corroborate this routing requirement
for USB device mode: CTRL1 is initially `0x3f`, and selecting USB restores
attachment. The first-boot DTS enables the MFD and Type-C driver for that
routing while keeping DWC3 in fixed peripheral mode and charger/gauge
clients disabled. The inherited dual-role setup still needs separate X900
validation before enabling host mode, OTG boost or higher-voltage charging.
