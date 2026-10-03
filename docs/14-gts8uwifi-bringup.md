# Galaxy Tab S8 Ultra Wi-Fi (SM-X900 / gts8uwifi): bring-up

Status, 2026-10-03: **framebuffer console, USB2 ACM root shell, UFS discovery
and the real postmarketOS initramfs debug shell work on the attached SM-X900**.
Both initramfs stages run in RAM; the on-screen debug keyboard renders. The
corrected memory map also passed a 512 MiB allocation/read-back check. An
installed rootfs, native AMOLED takeover and input remain unfinished. USERDATA
has not been flashed.

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

The DTS enables UFS, fixed USB2 peripheral mode and ABL's existing framebuffer.
The 2960x1848 ARGB landscape framebuffer at `0xb8000000` produces readable
uniLoader and Linux console output. Native MDSS/DSI, GPU, wireless, remote
processors, input, pogo, audio and the MAX77705 charger/gauge remain disabled.
The MFD and Type-C driver handle USB data routing in sink/device mode.
Inherited dormant peripheral descriptions are preparation, not support claims.

Kernel package `7.2-r51`, device package `0.1-r1` and uniLoader's console
newline fix establish the current diagnostic stage. The image built directly
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
layout. The framebuffer still depends on ABL scanout rather than native
panel takeover.

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

Continue BOOT-only tests with native AMOLED takeover and the Goodix GT6936
touchscreen, using the RAM-based postmarketOS debug shell. Keep charger,
wireless and other peripherals as separate stages. Installed rootfs work is
deferred; the on-screen keyboard currently has no validated touch input.
Generalize live ABL memory/reservation transfer before supporting other
firmware or RAM sizes.
