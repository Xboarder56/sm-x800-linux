# Galaxy Tab S8 Ultra Wi-Fi (SM-X900 / gts8uwifi): bring-up

Status, 2026-10-03: **native 120 Hz display with a flash-free bootloader
handoff, the Goodix touchscreen, USB2 ACM root shell, UFS discovery and the
real postmarketOS initramfs debug shell work on the attached SM-X900**.
Both initramfs stages run in RAM; the on-screen debug keyboard renders and
takes touch input. The corrected memory map also passed a 512 MiB
allocation/read-back check. An installed rootfs is unfinished, and display
off/on is not usable yet. USERDATA has not been flashed.

## Hardware evidence

The attached tablet is a 12 GiB SM-X900 / `gts8uwifi`, board revision 5,
SoC ID 457 (`0x1c9`), revision 2.2, running `X900XXU9DYDC` (Android 15).
The matching vendor_boot Waipio v2 base and recovery rev-5 overlay were merged
with fdtoverlay. A uniLoader diagnostic also captured ABL's live RAM banks
and three additional firmware reservations before image relocation.

| Local DYDC source (`root-build/stock-dydc/`) | SHA-256 |
|---|---|
| `base-00.dtb` | `57a5a4fea5caf9bfe779de69965b05f7578dbff277d8d0d8a91a494303595d9c` |
| `board-03.dtb` | `226251f5f961efd580bd06b7fd9e7021d96384b3bd97fecc9a61f2110faa41d1` |
| `x900-rev5-stock.dtb` | `f3fc4a71ac20f6306a588eb6ed79b82e225a5508443c756445433cf3fedb083c` |
| `boot.img` | `fdab2e13e4b9105d677b798cd7c91de08378b5cb76cdc6294587ad18f26b11e0` |

Durable findings and their limits are in [memory](../device-facts/gts8uwifi/memory.md),
[display](../device-facts/gts8uwifi/display.md) and [USB](../device-facts/gts8uwifi/usb.md).
The memory evidence explains the earlier `clear_page` external abort and the
holes/reservations absent from the sibling-derived map. Other RAM capacities
and firmware need their own live map; the excluded upper RAM remains untested.

## Validated first-boot stage

The first-boot DTS enabled UFS, fixed USB2 peripheral mode and ABL's framebuffer.
The 2960x1848 ARGB landscape framebuffer at `0xb8000000` produces readable
uniLoader and Linux console output. Native MDSS/DSI was disabled at that stage;
its subsequent enablement is described below. GPU, wireless, remote processors,
input, pogo, audio and the MAX77705 charger/gauge remain disabled.
The MFD and Type-C driver handle USB data routing in sink/device mode.
Inherited dormant peripheral descriptions are preparation, not support claims.

Kernel package `7.2-r51`, device package `0.1-r1` and uniLoader's console
newline fix established the framebuffer diagnostic stage. The image built directly
from this checkout with the command below has BOOT SHA-256
`121360005ac3f9ca4dd60459e89883ce8ba6976a482e816d7a3ef713fe8b6eee`;
artifacts and its ACM capture are in `root-build/gts8uwifi-debug-r23-checkout/`.
The older `root-build/gts8uwifi-debug/` image is the archived R11 baseline.

`RESTART2("download")` reaches Samsung Download Mode, confirmed by the
tablet screen and Heimdall detection without pressing the volume keys. The
[restart-reason evidence](../device-facts/gts8uwifi/reboot.md) explains the SDAM
route and why the previous qcom-pon setting returned to Linux. There is no
automatic Download Mode timeout in the diagnostic init.

The MAX77705 data switch is open after Download Mode on DYDC. Enabling its
MFD and Type-C driver selects USB routing and establishes initial attachment
without a cable replug. The UDC reaches `configured` at `high-speed`; macOS
enumerates the ACM device as `18d1:d001` and exposes an interactive root shell.
USB host mode, SuperSpeed, USB networking and SSH have not been tested. The
Linux shell reports `MemTotal=6473176 kB`, with no repeat external abort during
the captured RAM checks. UFS enumeration does not establish filesystem operation.

The real postmarketOS initramfs (`3.12.3-r1`, 11,802,395 compressed bytes)
reaches stage 2 and its debug shell with the same kernel package and console
fix. macOS exposes `/dev/cu.usbmodempostmarketOS3`; its name differs from the
minimal diagnostic gadget. The shell reports `configured` / `high-speed`,
with only RAM/virtual filesystems mounted and no captured external abort.
The on-screen keyboard is buffyboard; this proves rendering, not touch input.
USB NCM and DHCP start on the tablet, but host networking remains unverified.
This BOOT image has SHA-256
`fb83a7aef2014fb87331549d417f772b43657eb9aba52444ab59aa192da0ad82`;
logs are in `root-build/gts8uwifi-debug-r24-pmos-initramfs/`.

Earlier black/corrupted screens were not sufficient evidence of a kernel or
RAM fault. A USB capability-only change reproduced a black screen with Linux
and USB still alive; the tested stock capability word restores visible text
(see the USB evidence). Minimal ramdisk edits also showed sensitivity to
loader layout. The diagnostic recipe retains the original 1,919,488-byte
raw-cpio slot; the full compressed initramfs now boots despite its larger
layout. That initial framebuffer depended on ABL scanout rather than native
panel takeover.

## Native display stage

Kernel package `7.2-r55` enables MDSS/DSI and the AMSA46AS01 panel descriptor.
Native `msmdrmfb` at 2960x1848 reaches the same postmarketOS debug screen and
keyboard. X900's stock first-display commands restore output that remained
black with the inherited X800 enable sequence. The clean driver, without
register dumps or a temporary geometry selector, gives the same visible result.
See [the panel evidence](../device-facts/gts8uwifi/display.md) for commands,
clock limits and validation.

That stage flashed black/white at startup, exposed only 60 Hz and had no
touch input. Its BOOT image has SHA-256
`20b71cda0047c9eb8f037a1560d3623891cc20087d5c7c7713670e12023a48b0`;
local captures are in `root-build/gts8uwifi-debug-r28-clean-panel/`.

## Handoff, 120 Hz and touch stage

Kernel package `7.2-r63` resolves the startup flash, runs the panel at 120 Hz
and enables the touchscreen. Four findings were needed, each recorded with its
evidence in [display](../device-facts/gts8uwifi/display.md) and
[touch](../device-facts/gts8uwifi/touch.md):

- **An inherited rail was outside the X900 stock range.** The X800's 3.0 V
  always-on L13C is constrained to 1.8 V on X900 and has no stock consumer.
  It is no longer driven; every other declared RPMh rail was audited against
  the stock constraints.
- **The bootloader's scanout faulted in the SMMU** as soon as MDSS joined its
  IOMMU group. MDSS now keeps an identity domain until msm takes over.
- **Stock never resets this panel while it is running** and never cuts its
  supply at display-off. The driver now adopts the bootloader's panel and
  keeps it powered, which removes the flash.
- **The standard tear-on command switched TE off**, so the DPU ran on its
  fallback timer. With the parameterless form the panel and DPU run at
  120.8 Hz.

The Goodix GT6936 needed the Samsung 16-byte event parser, the X900 stock rail
voltages, pull-ups on its bus and an orientation mapping to the landscape
display. The initramfs keyboard registers the key under the finger.

The package-built image has BOOT SHA-256
`8ce915940fae1af364d3f29d1f4b60a71e10b02933a25b1694c6d8f7417acac2`; captures
are in `root-build/gts8uwifi-debug-r40-package-r63/`. The boot sequence,
picture and keyboard input were confirmed by eye on a workbench build of the
same sources and DTB. Three further boots of that build and the first boot of
the package build then matched by log only: native framebuffer, 120.7-120.8 Hz
vblank, touch registered, no SMMU fault or display error.

Display off/on is **not** validated. fbdev blanking panics this kernel without
a log a few seconds after the CRTC is disabled while fbcon is bound; detaching
fbcon first avoids it. One wake from sleep-in then left the panel controller
not ready. Reboot is unaffected. Avoid blanking the console on this image.

## Build and reproduce

Use the [Mac-hosted Linux/aarch64 container workflow](../tools/container/README.md).
Sources remain in this checkout; Linux chroots/build copies live on the Docker
volume. The host checkout is mounted read-only at `/src`, with ignored outputs
at `/out`. Sync the overlay, checksum/build the packages and regenerate the
initramfs before assembling an image. Never run concurrent pmbootstrap operations.

Pins: uniLoader `43770a04327532407194ddd3f9f35770daa01c70`,
pmbootstrap `4ed5555f34c6bbb3b6899003336fd233bd402218` (3.11.1),
pmaports `cc0c3e14092a134f0a9665b0cbb9892eec6de88c`; kernel vanilla Linux 7.2.

With matching stock outer ramdisk at `root-build/stock-dydc/boot-unpacked/ramdisk`:

```sh
docker exec -u builder sm-x900-builder env \
  UNILOADER_REMOTE=/work/uniloader \
  DIAGNOSTIC_INIT=1 MINIMAL_INITRAMFS=1 RAW_INITRAMFS=1 \
  USB_STATE_DIAGNOSTIC=1 UNILOADER_BUILD_DATE="2026-10-03 09:34:27" \
  EXTRA_CMDLINE='initcall_debug ignore_loglevel' \
  bash /src/tools/container/build-gts8uwifi-debug.sh \
  /src /work/repo/pmb-work /out/gts8uwifi-debug-next
```

For the real initramfs debug shell, use the same builder without the diagnostic
ramdisk switches:

```sh
docker exec -u builder sm-x900-builder env \
  UNILOADER_REMOTE=/work/uniloader \
  UNILOADER_BUILD_DATE="2026-10-03 09:34:27" \
  EXTRA_CMDLINE='pmos.nosplash initcall_debug ignore_loglevel' \
  bash /src/tools/container/build-gts8uwifi-debug.sh \
  /src /work/repo/pmb-work /out/gts8uwifi-pmos-debug
```

The script apply-checks the pinned patch stack, builds both uniLoader boards,
compares embedded bytes and checks relocation ranges, BOOT metadata and size.
The memory audit compares the DTB with both stock and captured ABL ranges.
`make lint` checks both device packages and DTS structure. Binding validation
and X800 hardware regression testing remain outstanding. Top-level image/flash
targets still select X800; use the explicit X900 script above.

## BOOT-only testing and recovery

From a freshly entered Download Mode session, flash the reviewed image:

```sh
root-build/heimdall/bin/heimdall flash --BOOT root-build/gts8uwifi-debug-next/boot-debug.img
```

This experiment leaves USERDATA, VENDOR_BOOT, DTBO, VBMETA, PERSIST and RECOVERY
untouched. The diagnostic init mounts only RAM and virtual filesystems.
Capture `uname`, `dmesg`, `meminfo`, `iomem` and UDC state over the ACM shell.
Do not run `pmos_continue_boot` before preparing the matching installed rootfs.

On macOS, find the enumerated port with `ls /dev/cu.usbmodem*`, then open it:

```sh
screen /dev/cu.usbmodem13101 115200
```

Substitute the current port name and press Enter to start the diagnostic shell.
This is a serial shell; SSH requires a separately configured network gadget.

To restore Android, re-enter Download Mode and flash matching DYDC stock BOOT:

```sh
root-build/heimdall/bin/heimdall flash --BOOT root-build/stock-dydc/boot.img
```

Custom BOOT transport is tested; stock BOOT restoration has not yet been
tested on this tablet. The X800 restore archive is not an X900 recovery image.

## Unresolved

Touch, the startup flash and 120 Hz are resolved for boot. Work continues with
BOOT-only tests and the RAM-based debug shell; installed rootfs work is
deferred.

| Area | Remaining work |
|---|---|
| Display | Display off/on: the fbcon-on-disabled-CRTC panic and the wake path from sleep-in, including stock's MAX77816 boost programming; brightness curve and HBM; 60 Hz switching; boots after an unclean reset. |
| Input | GT6936 pen/palm events, more than two contacts, suspend/resume and firmware update; X900 S Pen and pogo/cover keyboard; remaining buttons. |
| Graphics | Adreno GPU firmware, GMU initialization and hardware acceleration. |
| Wireless | X900 Wi-Fi and Bluetooth wiring/firmware, connectivity and recovery. |
| USB | Host networking/SSH, host mode, SuperSpeed and role changes. USB2 device serial works. |
| Power | Charger/gauge and battery readings, thermal sensors, idle consumption and system suspend/resume. |
| Storage/system | UFS filesystem operation, microSD, an installed rootfs and normal userspace boot. UFS enumeration works. |
| Audio | Amplifiers, speakers, microphones and routing on X900. |
| Other hardware | Sensors, cameras and fingerprint reader; audit inherited descriptions before enabling them. |
| Portability | Transfer ABL's live RAM/reservations rather than assuming this DYDC/12 GiB layout for other firmware or capacities. |
| Submission | Kernel bindings and `dtbs_check`, removal of remaining bring-up workarounds, X800 hardware regression and separate Linux/uniLoader/pmaports submissions. |

These are functional milestones, not claims that dormant DTS nodes already
support the corresponding X900 hardware.
