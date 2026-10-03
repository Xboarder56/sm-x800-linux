# Mac-hosted Linux/aarch64 bring-up builder

The authoritative sources are the Git checkout. Linux chroots and build
copies live on a Docker volume; exported artifacts live in ignored
`root-build/`. These commands compile images and do not flash a tablet.

From the checkout on the Mac:

```sh
docker build -t sm-x900-builder:local tools/container
docker volume create sm-x900-build
mkdir -p root-build
docker run -d --name sm-x900-builder --privileged \
  --mount type=volume,source=sm-x900-build,target=/work \
  --mount "type=bind,source=$PWD,target=/src,readonly" \
  --mount "type=bind,source=$PWD/root-build,target=/out" \
  sm-x900-builder:local
```

Privileged mode is needed for pmbootstrap's Linux mounts/chroots. The tablet's
USB connection stays on macOS, where native ADB and Heimdall handle transport.
Do not run two pmbootstrap operations concurrently.

For the initial builder, pmbootstrap was cloned to `/work/pmbootstrap` at
`4ed5555f34c6bbb3b6899003336fd233bd402218`. The repo wrapper and overlay were
copied to `/work/repo`, with `tools/pmbootstrap` linked to that clone. Pmaports
is under `/work/repo/pmb-work/cache_git/pmaports`, pinned for this experiment to
`cc0c3e14092a134f0a9665b0cbb9892eec6de88c`.

Initialize the repository wrapper interactively in `/work/repo`, setting work
and aports to those paths. Use `samsung-gts8uwifi`, aarch64, console UI, 8 jobs
and USB developer support. Always sync edited packages from `/src` before
checksumming/building; the copy on `/work` is not a second source tree.

Before each build, sync the edited kernel and device packages into the actual
pmbootstrap aports cache (copying only `/work/repo/pmaports-overlay` is not
enough). From a shell as `builder` in the container:

```sh
rsync -a /src/pmaports-overlay/device/testing/linux-postmarketos-qcom-sm8450/ \
  /work/repo/pmb-work/cache_git/pmaports/device/testing/linux-postmarketos-qcom-sm8450/
rsync -a /src/pmaports-overlay/device/testing/device-samsung-gts8uwifi/ \
  /work/repo/pmb-work/cache_git/pmaports/device/testing/device-samsung-gts8uwifi/
cd /work/repo
```

Then checksum, build and regenerate the ramdisk:

```sh
./pmb checksum linux-postmarketos-qcom-sm8450
./pmb build linux-postmarketos-qcom-sm8450
./pmb checksum device-samsung-gts8uwifi
./pmb config device samsung-gts8uwifi
./pmb build device-samsung-gts8uwifi
./pmb install --no-image --no-recommends --password x900-debug
```

`x900-debug` is a disposable development password, not a personal credential.
The initial debug shell itself runs from the initramfs. No rootfs image has
been installed on the tablet by these commands. Copy generated APKBUILD
checksums back to the authoritative overlay after verifying its source list
still matches.

With the matching DYDC stock ramdisk extracted to
`root-build/stock-dydc/boot-unpacked/ramdisk`, assemble the debug image:

```sh
docker exec sm-x900-builder bash /src/tools/container/build-gts8uwifi-debug.sh
```

The script clones pinned uniLoader, apply-checks the complete patch stack and
builds both boards in separate directories. `UNILOADER_REMOTE` may point to
an existing local clone as an offline object source; it still checks out the
pinned commit before applying patches. Ubuntu's incomplete mkbootimg package
is bypassed using the complete AOSP tool installed in the postmarketOS rootfs.

Outputs are `root-build/gts8uwifi-debug/boot-debug.img`, payloads, SHA256SUMS,
board build logs, the unpacked image/header and payload audit. The script
checks that stage 2 is present in the ramdisk, the debug command line has no
rootfs UUIDs, embedded payload bytes match, relocation ranges are disjoint and
in allocatable DT RAM, and the image fits the 96 MiB BOOT partition.
Those are static checks; R6 shows an allocation fault despite passing them.
They do not establish that Samsung's runtime map makes every range writable.

Optional bring-up switches are passed with `docker exec ... env`:

| Variable | Effect |
|---|---|
| `DIAGNOSTIC_INIT=1` | Repack the ramdisk with the temporary diagnostic init; no UFS filesystem mounts. |
| `MINIMAL_INITRAMFS=1` | With diagnostic init, use just static BusyBox, console device and script. |
| `RAW_INITRAMFS=1` | With diagnostic init, embed raw cpio instead of gzip. |
| `USB_STATE_DIAGNOSTIC=1` | With diagnostic init, print UDC state and current speed at each heartbeat; retain the baseline gadget descriptors. |
| `EXTRA_CMDLINE='...'` | Append diagnostic kernel parameters. |
| `UNILOADER_BUILD_DATE='YYYY-MM-DD HH:MM:SS'` | Fix uniLoader's banner timestamp for comparisons with a saved image. |
| `CAPTURE_BOOTLOADER_FDT=1` | Enable uniLoader diagnostic 0006 for X900 only; show ABL's memory map and halt before Linux. |

R7 captures ABL's FDT before uniLoader relocates its image. The incoming tree
temporarily occupies up to 2 MiB at `DTB_ENTRY`; the audit checks that scratch
range against payloads, the relocated loader and compiled-DT reservations.
This experiment does not modify the normal board defconfigs. The printed
reservation differences are restricted to ranges our compiled DT would
expose; chosen/bootargs and device identifiers are not displayed.

The X800 uniLoader build is a compilation check using the debug ramdisk;
it is not an X800 deployment image or hardware regression test.
The top-level Makefile's existing image and flash targets still select X800.
See [the X900 bring-up record](../../docs/14-gts8uwifi-bringup.md) for transport,
recovery and outstanding hardware checks.

Build a diagnostic image using the current package release and the same
options as the working R11 stage:

```sh
docker exec -u builder sm-x900-builder env \
  UNILOADER_REMOTE=/work/uniloader \
  DIAGNOSTIC_INIT=1 MINIMAL_INITRAMFS=1 RAW_INITRAMFS=1 \
  USB_STATE_DIAGNOSTIC=1 EXTRA_CMDLINE='initcall_debug ignore_loglevel' \
  bash /src/tools/container/build-gts8uwifi-debug.sh \
  /src /work/repo/pmb-work /out/gts8uwifi-debug-next
```

Use a new output directory for each experiment and compare payload sizes and
loader layout before flashing. The archived r46 R8 control was reproduced
byte-for-byte with `UNILOADER_BUILD_DATE='2026-10-03 09:02:19'` and USB state
printing disabled; its BOOT SHA-256 is
`0ebd7a7e6694cffea631523478d066d23a11002af5bc9478b4e6e634ce261830`.
New package releases or banner timestamps produce different hashes. R11 adds
UDC state printing and establishes an interactive ACM shell; see the bring-up
page for its hash and runtime evidence.
