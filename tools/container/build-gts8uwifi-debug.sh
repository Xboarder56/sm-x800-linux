#!/usr/bin/env bash
# Run inside the Linux/aarch64 builder after the kernel/device builds and
# `pmb install --no-image`. This produces artifacts; it never flashes a device.
set -euo pipefail

repo=${1:-/src}
pmb_work=${2:-/work/repo/pmb-work}
out=${3:-/out/gts8uwifi-debug}
build_base=${BUILD_BASE:-/work/debug-build}
ul_pin=43770a04327532407194ddd3f9f35770daa01c70
ul_remote=${UNILOADER_REMOTE:-https://github.com/ivoszbg/uniLoader.git}
# Fix the banner timestamp when comparing a new image with a saved control.
# uniLoader accepts BUILD_DATE as a make variable; otherwise it uses the clock.
ul_make_args=(ARCH=aarch64 CROSS_COMPILE=aarch64-linux-gnu-)
if [[ -n ${UNILOADER_BUILD_DATE:-} ]]; then
    ul_make_args+=("BUILD_DATE=$UNILOADER_BUILD_DATE")
fi
port="$repo/pmaports-overlay/uniloader-port"
kernel_pkg="$repo/pmaports-overlay/device/testing/linux-postmarketos-qcom-sm8450"
rootfs="$pmb_work/chroot_rootfs_samsung-gts8uwifi"
stock_ramdisk=${STOCK_RAMDISK:-/out/stock-dydc/boot-unpacked/ramdisk}

[[ $(uname -s) == Linux && $(uname -m) == aarch64 ]] || {
    echo 'Run this script in the Linux/aarch64 container.' >&2; exit 1;
}
for tool in git make aarch64-linux-gnu-gcc mkbootimg unpack_bootimg cpio python3; do
    command -v "$tool" >/dev/null
done
version=$(sed -n 's/^pkgver=//p' "$kernel_pkg/APKBUILD")
release=$(sed -n 's/^pkgrel=//p' "$kernel_pkg/APKBUILD")
apk="$pmb_work/packages/edge/aarch64/linux-postmarketos-qcom-sm8450-$version-r$release.apk"
test -f "$apk"
test -f "$rootfs/boot/initramfs"
test -f "$stock_ramdisk"
mkdir -p "$out" "$build_base"
run=$(mktemp -d "$build_base/run.XXXXXX")
echo "Build workspace: $run"
git clone --no-checkout "$ul_remote" "$run/source"
git -C "$run/source" checkout --detach "$ul_pin"
for patch in "$port"/patches/*.patch; do
    git -C "$run/source" apply --check "$patch"
    git -C "$run/source" apply "$patch"
done
cp "$port"/board/samsung/board-gts8{p,u}wifi.c "$run/source/board/samsung/"
cp "$port"/configs/gts8{p,u}wifi_defconfig "$run/source/configs/"
mkdir "$run/kernel"
tar xzf "$apk" --warning=no-unknown-keyword -C "$run/kernel" boot/vmlinuz \
    boot/dtbs/qcom/sm8450-samsung-gts8pwifi.dtb \
    boot/dtbs/qcom/sm8450-samsung-gts8uwifi.dtb
gzip -dc "$run/kernel/boot/vmlinuz" > "$out/Image"
cp "$rootfs/boot/initramfs" "$out/initramfs"
cp "$stock_ramdisk" "$out/stock-ramdisk"
extra_cmdline=${EXTRA_CMDLINE:-}
if [[ ${DIAGNOSTIC_INIT:-0} == 1 ]]; then
    mkdir "$run/ramdisk"
    (
        cd "$run/ramdisk"
        if [[ ${MINIMAL_INITRAMFS:-0} == 1 ]]; then
            mkdir -p bin sbin usr/bin usr/sbin dev proc sys/kernel/debug \
                sys/kernel/config run etc tmp
            cp /usr/bin/busybox bin/busybox
            file bin/busybox | grep -q 'statically linked'
            sudo mknod dev/console c 5 1
            sudo chown "$(id -u):$(id -g)" dev/console
        else
            gzip -dc "$out/initramfs" | cpio -id --quiet
        fi
        cp "$repo/tools/container/x900-diagnostic-init.sh" x900-diagnostic-init
        if [[ ${USB_STATE_DIAGNOSTIC:-0} == 1 ]]; then
            # Observe the link after binding without changing USB descriptors.
            # Keep the unmodified diagnostic source available as the R8 control.
            python3 - x900-diagnostic-init <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
script = path.read_text()
anchor = "    sleep 20\n"
if script.count(anchor) != 1:
    raise SystemExit("Diagnostic heartbeat anchor changed; review USB state insertion.")
state = ('    for f in /sys/class/udc/*/state /sys/class/udc/*/current_speed; '
         'do echo "$f=$(cat "$f")"; done\n')
path.write_text(script.replace(anchor, state + anchor))
PY
        fi
        chmod +x x900-diagnostic-init
        find . -exec touch -h -d @0 {} +
        find . -print0 | LC_ALL=C sort -z \
            | cpio --null -o -H newc --owner=0:0 --reproducible --quiet \
            > "$run/ramdisk.cpio"
        if [[ ${RAW_INITRAMFS:-0} == 1 ]]; then
            cp "$run/ramdisk.cpio" "$out/initramfs"
        else
            gzip -nc "$run/ramdisk.cpio" > "$out/initramfs"
        fi
    )
    extra_cmdline="$extra_cmdline rdinit=/x900-diagnostic-init"
fi
if [[ ${RAW_INITRAMFS:-0} == 1 ]]; then
    cpio -it < "$out/initramfs" > "$out/initramfs-files.txt" 2>/dev/null
else
    gzip -dc "$out/initramfs" | cpio -it > "$out/initramfs-files.txt" 2>/dev/null
fi
if [[ ${MINIMAL_INITRAMFS:-0} == 1 ]]; then
    grep -Eq '^(\./)?x900-diagnostic-init$' "$out/initramfs-files.txt"
else
    for file in init_2nd.sh init_functions.sh init_functions_2nd.sh; do
        grep -Eq "^(\./)?$file$" "$out/initramfs-files.txt"
    done
fi

# No rootfs UUIDs: pmos.debug-shell stops before rootfs mount/resize.
source "$repo/pmaports-overlay/device/testing/device-samsung-gts8uwifi/deviceinfo"
# The native panel is disabled, so no driver claims its boot-on regulator.
# Keep inherited rails on during this diagnostic boot, alongside clocks/PDs.
printf '%s\0' "$deviceinfo_kernel_cmdline regulator_ignore_unused bootloader=uniloader pmos.debug-shell rd.info $extra_cmdline" > "$out/cmdline"
for board in gts8pwifi gts8uwifi; do
    cp -a "$run/source" "$run/$board"
    cp "$out/Image" "$run/$board/blob/Image"
    cp "$run/kernel/boot/dtbs/qcom/sm8450-samsung-$board.dtb" "$run/$board/blob/dtb"
    cp "$out/initramfs" "$run/$board/blob/ramdisk"
    cp "$out/cmdline" "$run/$board/blob/cmdline"
    # Leave both normal defconfigs unchanged; this image stops in uniLoader.
    if [[ ${CAPTURE_BOOTLOADER_FDT:-0} == 1 && $board == gts8uwifi ]]; then
        printf '%s\n' 'CONFIG_BOOTLOADER_FDT_DIAGNOSTIC=y' \
            >> "$run/$board/configs/${board}_defconfig"
    fi
    (
        cd "$run/$board"
        make "${ul_make_args[@]}" "${board}_defconfig"
        make -j8 "${ul_make_args[@]}"
    ) > "$out/$board-build.log" 2>&1
    cp "$run/$board/uniLoader" "$out/$board-uniLoader"
    cp "$run/$board/uniLoader.o" "$out/$board-uniLoader.elf"
    cp "$run/$board/.config" "$out/$board.config"
done
cp "$run/kernel/boot/dtbs/qcom/sm8450-samsung-gts8uwifi.dtb" "$out/dtb"
python3 -B "$repo/tools/boot-payload-audit.py" "$out" | tee "$out/payload-audit.txt"
# Ubuntu 24.04's mkbootimg package omits its gki Python module. Use the
# complete AOSP tool supplied by the installed Alpine package instead.
python3 "$rootfs/usr/share/android-tools/mkbootimg/mkbootimg.py" \
    --header_version 4 --os_version 12.0.0 --os_patch_level 2025-04 \
    --kernel "$out/gts8uwifi-uniLoader" --ramdisk "$out/stock-ramdisk" \
    --cmdline '' -o "$out/boot-debug.img"
test "$(stat -c %s "$out/boot-debug.img")" -le 100663296
unpack_bootimg --boot_img "$out/boot-debug.img" --out "$out/unpacked" > "$out/boot-header.txt"
cmp "$out/unpacked/kernel" "$out/gts8uwifi-uniLoader"
cmp "$out/unpacked/ramdisk" "$out/stock-ramdisk"
(cd "$out" && sha256sum Image dtb initramfs cmdline gts8uwifi-uniLoader \
    stock-ramdisk boot-debug.img > SHA256SUMS)
printf '%s\n' "$ul_pin" > "$out/uniloader-commit.txt"
echo "Debug image ready: $out/boot-debug.img"
