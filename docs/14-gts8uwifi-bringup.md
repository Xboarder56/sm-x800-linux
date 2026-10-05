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
  120.8 Hz. TE needs no tear-on at all on this panel; `7.2-r68` sends none.

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

Kernel package `7.2-r64` enables the WCN6855: the X900 stock `cnss-qca6490`
and `bt_qca6490` nodes use the same enable GPIOs (80/81/82/204), rails and BT
UART as the inherited description. With the modules and linux-firmware blobs
loaded into RAM, ath11k reports `wcn6855 hw2.1` (chip 0x2, board 0xff) and a
scan returns 12 networks on 2.4 GHz; no 5/6 GHz network was seen under the
world regulatory domain and no association was attempted. Bluetooth loads
`wcnhpbtfw21.tlv`/`wcnhpnv21.bin`; the controller has no stored address
(`00:00:00:00:5A:AD`) and stays unconfigured until one is set, after which a
12 s discovery finds 83 devices. The X900 device package has no address
helper or firmware dependencies yet, and the modules are not in the initramfs.

Kernel package `7.2-r68` makes display off/on work. Through `7.2-r66` every
wake failed its first frame and a few cycles reset the SoC without a log: the
DPU kept its 500 MHz core clock while the display-off path dropped the
matching MMCX vote. A one-hunk DPU patch keeps the vote until runtime suspend.
The panel driver also stops sending sleep-out, which this TCON does not
survive after a reset, and resets the TCON on every wake. Details and the
measurements are in [display](../device-facts/gts8uwifi/display.md). The
cycles were checked by TE, `tcon_rdy`, register reads and error counters, not
by eye.

Kernel package `7.2-r69` enables the microSD slot from the stock
`sdhci@8804000` description: PM8350C L9C for the card, L6C for its I/O and
card detect on GPIO92, active low. A 64 GB card enumerates as SDR104 with the
I/O rail at 1.8 V and reads at 57-62 MB/s without errors. A 3 GB image
written at 33 MB/s read back identical. Hotplug and other cards are untested.

The same card now carries a postmarketOS console root filesystem, so UFS and
Android stay untouched. BOOT is still the debug-shell image; the initramfs
finds `pmOS_boot` and `pmOS_root` by label, which exist only on the card, and
`pmos_continue_boot` from the USB shell switches to it. The first boot grew
the root filesystem to the 57 GB partition and reached multi-user in 92 s of
userspace, most of it a wait for a serial device described below.

Notes for repeating it:

- `pmbootstrap install` cannot finish in the Docker builder: the loop
  partition nodes never appear. The root filesystem it builds first is
  complete, so the two filesystems were made from it with `mke2fs -d`
  (ext2 `pmOS_boot` from `/boot`, ext4 `pmOS_root` from the rest), written to
  a GPT made with `parted` in the debug shell, and verified by SHA-256.
- The serial link moves tens of MB/s but corrupted a single 484 MB transfer;
  48 MB pieces, each checksummed, were reliable.
- The initramfs removes its ACM function when it leaves the debug shell.
  A unit on the card adds `acm.usb0` back to the `g1` gadget before
  `serial-getty@ttyGS0`. macOS binds the NCM function but never gives it an
  interface name, so the serial login is the only way in from a Mac.
- The debug image's payload audit rejects root filesystem UUIDs on the
  command line by design; label lookup needs none.
- A small sysrq "deadman" started before `pmos_continue_boot` reboots into
  the debug shell if the card's system does not bring the login back.
- `rmtfs` is masked on the card: it would open the modem storage partitions
  on UFS.

These pieces are local to `root-build/`; the X900 device package does not
carry a gadget service, firmware extractor or sensor configuration yet.

Kernel package `7.2-r70` takes the ADSP and the SLPI sensor hub out of the
quarantine. The X900 stock reserved-memory regions (ADSP at `0x84500000`,
SLPI `0x88000000`+`0x1700000`) and the L2C sensor rail equal the inherited
description; stock holds no second sensor rail here. With `adsp.*` and
`slpi.*` from the DYDC firmware package's `NON-HLOS.bin` under
`/lib/firmware/qcom/sm8450/gts8uwifi/`, both reach `running` about 0.5 s
after `qcom_q6v5_pas` loads and both FastRPC devices appear. Alpine's
`hexagonrpcd` 0.4.0 with no sensor tree makes the SLPI's sensor process
fault in `sns_registry_sensor.c` and restart every 4 s; with the daemon
stopped the hub stays up. Reading sensors needs what the X800 port has and
the X900 package lacks: the patched daemon and the stock sensor registry
configs. The audio macros fail to probe behind the ADSP because the sound
card stays disabled.

Sensors read through the SLPI once the X800 port's patched `hexagonrpcd`
and the stock sensor configs are in place: accelerometer, light and
magnetometer in `ssccli`, and `iio-sensor-proxy` reports orientation, tilt,
lux and a compass heading with the X800 mount matrix. The parts, the readings
and what is still missing are in
[sensors](../device-facts/gts8uwifi/sensors.md). In the same system the
packaged firmware brings up `wlan0` and `hci0` without manual steps.

Kernel package `7.2-r71` and device package r2 enable the Adreno 730. The
initramfs carries `a730_sqe.fw`, `gmu_gen70000.bin` and the stock
`a730_zap.*` (from `NON-HLOS.bin`, staged by hand). The GPU binds with the
display, loads GMU firmware v4.0.7 and reports `gpu-initialized: 1`, chip
`07030001`. Mesa 26.2.4 answers `eglinfo` on the GBM and surfaceless
platforms as freedreno FD730 with OpenGL 4.6 and OpenGL ES 3.2. No frame has
been rendered to the panel: that test waits for someone to watch it. A DRM
client closing its device restores the console and wakes a blanked panel.

Kernel package `7.2-r72` enables the two thermistor ADC channels. The stock
X900 state for the Wi-Fi thermistor puts pm8350 `gpio2` in high impedance,
where the inherited X800 state named `gpio1`; with `gpio1` the channel read
57-63 °C, with `gpio2` 31-32 °C beside the AP thermistor at 29 °C.

Kernel package `7.2-r73` enables `gpio-keys`: volume-up on pm8350 `gpio6`
and the cover and S Pen hall switches on TLMM 169 and 23, all as the stock
X900 tree has them. The device registers and reports the cover switch open
and the pen switch set. Nobody has pressed the key or moved a magnet yet.

Kernel package `7.2-r74` enables the S Pen digitizer. The stock X900 node
has it where the X800 does: Wacom W90xx at 0x56 on the `i2c@a98000` pins
(TLMM 52/53), interrupt 51, flash-mode 54, pen-detect 155, supply switch 167,
and the same `wacom,invert`. The driver identifies firmware `4010` with a
31376 x 19589 coordinate range, 4096 pressure levels and tilt, and registers
`Wacom WEZ01 S Pen`. No pen has touched the screen under Linux yet.

Kernel package `7.2-r75` enables the keyboard-cover controller: the STM32 at
0x2a on `i2c@88c000` with connection detect on TLMM 59, attention on 71,
reset on 97 and its supply switch on 70, as in the stock X900 node
(`EF-DX900`). The driver probes and reports no cover attached. No keyboard
cover has been attached under Linux yet.

Kernel package `7.2-r76` enables audio: the four CS35L45 amplifiers, the VA
macro and the sound card, whose stock wiring equals the X800's. Each
amplifier was played alone at low level and picked up by the microphones,
left pair on the left channel and right pair on the right, and three
microphones answer. The measurements are in
[audio](../device-facts/gts8uwifi/audio.md). Nobody has listened to it.

Kernel package `7.2-r77` exposes all of the bootloader's RAM banks instead
of stopping at `0x980000000`: `MemTotal` rises from 6.5 to 10.6 GB. A 9.5 GB
fill-and-verify in a tmpfs ran clean twice; see
[memory](../device-facts/gts8uwifi/memory.md).

Wi-Fi turned out to need Samsung's own firmware set. With linux-firmware's
`WLAN.HSP.1.1` and its generic board entry the X900 associates on 2.4 GHz
but hears nothing on 5 or 6 GHz and loses most of what it sends; with the
stock `amss20.bin`, `m3.bin`, `regdb.bin` and `bdwlan.elf` it joins a 6 GHz
160 MHz network with no failed transmissions and reconnects at boot. Three
inherited rail floors that ran below stock (two of them WCN6855 rails) and the
stock antenna-switch rail were corrected on the way; see
[wireless](../device-facts/gts8uwifi/wireless.md).

Plasma Desktop 6.7 runs from the microSD system (installed with `apk` from
packages fetched in the builder, later directly over Wi-Fi). With the owner at
the tablet on 2026-10-04: the login screen and desktop render in the right
orientation, touch and the on-screen keyboard work, the desktop auto-rotates
both ways with touch still aligned, the S Pen pointer sits under the tip, the
brightness slider works, the speakers play a clean tone, and volume-up,
volume-down and power all register. `kmscube` draws 74 frames per second at
the native resolution. The owner saw a brief flash at the initramfs handoff
and again as services start; it varies from boot to boot.

The desktop used to freeze for a second at a time and then lose the GPU
(`HFI_H2F_MSG_GX_BW_PERF_VOTE ... timed out`, then `Timeout waiting for GMU
OOB set GPU_SET` and a hangcheck), taking the login screen or session with
it after seconds to minutes of use. The GMU had answered: the HFI interrupt
handler cleared the reply bit before the code polling for it looked. Kernel
package `7.2-r82` masks the HFI interrupts before the GMU firmware starts
and stops the handler touching reply bits. With the panel off, 5000 GMU
resumes and nine minutes of KWin on a virtual output ran without a timeout,
where the unchanged driver had 12 in 800 and 14 in three minutes. `7.2-r83`
adds the GPU's memory path and stock DDR bandwidth table, which shortens a
GMU resume from 16-30 ms to about 9 ms. A hands-on session on the fixed
kernel is still to do. Evidence is in
[gpu](../device-facts/gts8uwifi/gpu.md).

Device package r3 boots without the bring-up flags. `clk_ignore_unused
pd_ignore_unused arm-smmu.disable_bypass=0` are gone from the kernel command
line and the image builder no longer adds `regulator_ignore_unused`, which
matches the X800. With none of them the microSD system comes up as before:
both remote processors, sensors, Wi-Fi on 6 GHz, the sound card and capture,
touch and S Pen devices, six UFS LUNs, two display off/on cycles and 300 GMU
resumes, with no SMMU fault. The regulator flag had no effect here: the two
rails without a Linux user (PM8350C L13 and PMR735A S1) are RPMh rails whose
state cannot be read, and the regulator core does not switch those off.

Kernel packages `7.2-r84` to `7.2-r86` enable the PMIC real-time clock and
the fuel gauge and give the battery node the X900's design capacity. The RTC
is read only and its alarm wakes the tablet from s2idle and from deep
suspend; from the Plasma session the power key suspends and wakes it. The
gauge reports 99 %, 4.33 V and 10,502 mAh full. The charger is still
disabled; a supervised test of the mainline driver at full charge is in
[power](../device-facts/gts8uwifi/power.md), along with the suspend results.
With the owner at the tablet on the fixed kernel the desktop ran without a
GMU error, the session's sound devices and on-screen keyboard work (the
keyboard had to be selected in KWin's settings), and the speakers sound
thin.

Device package r4 to r9 move what had been copied onto the microSD system
by hand into the package: the audio topology, UCM profile and amplifier
rule (which now holds all four amplifiers), the USB gadget service (NCM
and ACM; a root login on the serial function from boot), `swclock-offset`
for the read-only RTC, the sensor rules and daemon with a guard against
running without a sensor tree, the Bluetooth address helper, and
`gts8uwifi-fw-extract`, which also stages the stock Wi-Fi set. Each was
installed over the hand-made version on the card and checked after a
clean reboot. Bluetooth has its factory address and finds devices. The
Mac got an address on the NCM interface and could ping and ssh to the
tablet on one boot and saw no interface on the next two; ssh over Wi-Fi
is the working file path.

Notes from the desktop work: a DRM client closing the last open file on the
device, render node included, restores the fbdev console and wakes a blanked
panel. `pmbootstrap install` normally copies the apk signing keys into the
image; the hand-built image lacked them and `apk` rejected every index until
they were copied in.

`poweroff` with the USB cable attached comes straight back up: the bootloader
powers the tablet on when a charger is present. Unplugged, it stays off and
the power button starts it. No kernel change is involved; a PS_HOLD rewrite
tried for this left the tablet needing power + volume-down and was dropped.

The DTS ramoops region did not survive a reset on this tablet. Test images
capture panics by pointing ramoops at Samsung's preserved debug memory from
the command line: `ramoops.mem_address=0x800900000 ramoops.mem_size=0x200000
ramoops.record_size=0x40000 ramoops.console_size=0x100000 ramoops.ecc=1`.

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
| Display | A look at display off/on by eye; stock's delayed display-on and MAX77816 boost programming; the bootloader's varying handoff state; brightness curve and HBM; 60 Hz switching; boots after an unclean reset. |
| Input | GT6936 pen/palm events, more than two contacts, suspend/resume and firmware update; a keyboard cover and the hall switches changing state. Touch, the S Pen and all three keys work under Plasma. |
| Graphics | Sending the GMU timeout fix upstream; a packaged source for the zap shader on X900. Plasma renders on the Adreno 730 and the owner's session on `7.2-r83` had no GMU error. |
| Wireless | Running the extractor's default mode against the tablet's own partitions; throughput; Bluetooth pairing and audio. Wi-Fi works on 6 GHz with the stock set, which the extractor stages; Bluetooth has its factory address and scans. |
| USB | Host mode, VBUS out, PD above 5 V and role changes, all of which need the charger driver; SuperSpeed; why macOS only sometimes brings the NCM interface up; MTP. USB2 device serial works from the packaged gadget. |
| Power | Enabling the charger after a watched charge from a lower state of charge (see [power](../device-facts/gts8uwifi/power.md)); idle and suspend consumption, where the SoC's sleep counters stay at zero; the 2 s resume; `swclock-offset` in the X900 package. The gauge reads, suspend and resume work, the bootloader's charger state keeps the battery full; SoC thermal zones and both thermistors read. |
| Storage/system | UFS filesystem operation and an installed rootfs on it; an image built from the packages alone, checked against the hand-grown card; image creation outside Docker; microSD hotplug; the Tab S8+ package's lid and console-blank policy, login banner, setup command and tools metapackage. UFS enumeration works and Plasma runs from microSD. |
| Audio | Thin speaker sound: speaker protection, tuning and 4-slot TDM; a topology file, UCM profile and amplifier rule in the X900 package. Speakers and microphones work in the Plasma session. |
| Other hardware | The sensor daemon's revision answer (4, this tablet is 5) and the registry from `persist`; the keyboard cover and hall switches doing something; the rear flash LED, disabled in the tree; Wi-Fi thermistor conversion; cameras and fingerprint reader. Sensors read through the SLPI with the packaged rules and a tree the extractor builds. |
| Portability | Transfer ABL's live RAM/reservations rather than assuming this DYDC/12 GiB layout for other firmware or capacities. |
| Submission | Kernel bindings and `dtbs_check`, removal of remaining bring-up workarounds, X800 hardware regression and separate Linux/uniLoader/pmaports submissions. |

These are functional milestones, not claims that dormant DTS nodes already
support the corresponding X900 hardware.
