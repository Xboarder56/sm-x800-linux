#!/bin/sh
# gts8uwifi-fw-extract — pull non-redistributable firmware off the device's
# own stock partitions into /lib/firmware, build the sensor hub's served
# tree from the stock vendor image, then rebuild the initramfs.
#
# The cartridge-dump model: this port's repo and packages ship only OPEN or
# redistributable content. Blobs that are Samsung-signed for THIS device
# (the a730 GPU zap shader, the audio DSP and sensor hub images, which TrustZone will only
# accept with Samsung's signature), Qualcomm's proprietary sensor registry configs
# and this unit's factory sensor calibration are extracted at setup time from
# partitions the device already carries. Nothing copyrighted is ever distributed by us.
#
#   gts8uwifi-fw-extract                     everything from the tablet's own partitions:
#                                            apnhlos blobs, Wi-Fi set and sensor tree from
#                                            super, registry from persist
#   gts8uwifi-fw-extract --apnhlos-image FILE  apnhlos blobs from a NON-HLOS.bin of the
#                                            stock firmware package instead of the partition
#   gts8uwifi-fw-extract --vendor-image FILE Wi-Fi set and sensor tree from a raw vendor.img
#                                            of the stock firmware package instead of super
#   gts8uwifi-fw-extract --sensors-from DIR  sensor tree only, DIR holding a copy of the
#                                            stock /vendor/etc/sensors (config/ and
#                                            sns_reg_config), see tools/sensors-from-super.sh
#   gts8uwifi-fw-extract --refresh-registry  replace a populated registry (any mode)
#   gts8uwifi-fw-extract --hw-rev N          the board revision served to the sensor hub
#                                            (default 5, see build_sensor_tree)
#
# This is the Tab S8+ package's gts8pwifi-fw-extract with three changes for
# the Tab S8 Ultra. It also stages the stock Wi-Fi firmware set, because
# linux-firmware's board data does not fit this tablet (stage_wifi). It can
# take the firmware package's images in place of the partitions, for a
# tablet that no longer has Android on it and for testing. And every
# partition it does read is first switched read-only at the block layer.
# With an --*-image option the corresponding partition is not opened, and
# persist is only read when super is.
#
# Sensor tree: hexagonrpcd serves $HFS to the SLPI. It resolves that root
# from the device tree (compatible samsung,gts8uwifi + qcom,sm8450, model
# "Samsung ..."), so the daemon runs with no -R. Layout, from upstream
# hexagonrpcd/rpcd_builder.c:
#   sensors/config/*.json     stock /vendor/etc/sensors/config (66 SEE registry configs; 65 on the X900)
#   sensors/sns_reg.conf      stock sns_reg_config, revision source pointed at socinfo
#   sensors/persist/          writable by fastrpc; the SLPI keeps sns_reg_version here
#   sensors/persist/registry/ the registry, copied from the stock persist partition:
#                             the same groups the SLPI would generate, with this unit's
#                             factory calibration (magnetometer soft-iron matrix, axis
#                             orientation) and the calibration state the stock hub saved.
#                             Without persist it is pre-generated with sscregistrygen and
#                             the SLPI rewrites it on its first boot.
#   sensors/registry -> persist/registry   read-only path of the unpatched daemon
#   socinfo/                  served as /sys/devices/soc0: values the stock kernel
#                             exposes and mainline does not (hw_platform, ssc_hw_rev...)
# An existing registry is left alone unless --refresh-registry is given: it
# holds the SLPI's own state.
#
# Idempotent; run once after any userdata/rootfs reflash (see tools/README).

set -e

FWDIR=/lib/firmware/qcom/sm8450/gts8uwifi
WIFIDIR=/lib/firmware/ath11k/WCN6855/hw2.1
HFS=/usr/share/qcom/sm8450/Samsung/gts8uwifi
APNHLOS=/dev/disk/by-partlabel/apnhlos
SUPER=/dev/disk/by-partlabel/super
PERSIST=/dev/disk/by-partlabel/persist
SOC_ID=457
HW_PLATFORM=MTP
HW_REV=5

MNT=$(mktemp -d)
VMNT=
PMNT=
DM_CREATED=
REFRESH_REGISTRY=

cleanup() {
	for d in "$VMNT" "$PMNT"; do
		[ -n "$d" ] || continue
		umount "$d" 2>/dev/null || true
		rmdir "$d" 2>/dev/null || true
	done
	for m in $DM_CREATED; do
		dmsetup remove "$m" 2>/dev/null || true
	done
	umount "$MNT" 2>/dev/null || true
	rmdir "$MNT" 2>/dev/null || true
}
trap cleanup EXIT

die() { echo "!! $*" >&2; exit 1; }

# Switch a partition read-only at the block layer before anything mounts
# it, so that not even a journal replay can reach the flash.
setro() {
	dev=$(readlink -f "$1")
	[ -b "$dev" ] || die "$1 is not a block device"
	blockdev --setro "$dev" || die "could not switch $dev read-only"
}

stage_apnhlos() {
	if [ -n "$APNHLOS_IMAGE" ]; then
		echo ">> mounting $APNHLOS_IMAGE (stock NON-HLOS image, read-only)"
		mount -o ro,loop "$APNHLOS_IMAGE" "$MNT" || die "mounting $APNHLOS_IMAGE failed"
	else
		echo ">> mounting apnhlos (stock firmware partition, read-only)"
		setro "$APNHLOS"
		mount -o ro "$APNHLOS" "$MNT"
	fi

	mkdir -p "$FWDIR"
	for f in a730_zap.mdt a730_zap.b00 a730_zap.b01 a730_zap.b02; do
		[ -f "$MNT/image/$f" ] || die "$f not found in apnhlos/image — wrong partition layout?"
		cp "$MNT/image/$f" "$FWDIR/$f"
		echo "   $f -> $FWDIR/"
	done

	# Audio DSP: split adsp.mdt + adsp.bNN segments (some segment numbers are
	# absent by design; the mdt loader skips zero-size PT_LOADs). SM8450 ships
	# no adsp_dtb. The *.jsn protection-domain maps are not needed by the
	# in-kernel pd-mapper; they are kept beside the image for a userspace
	# pd-mapper, should one ever be used.
	echo ">> staging audio DSP image"
	[ -f "$MNT/image/adsp.mdt" ] || die "adsp.mdt not found in apnhlos/image"
	cp "$MNT"/image/adsp.mdt "$MNT"/image/adsp.b* "$FWDIR"/
	cp "$MNT"/image/adspua.jsn "$MNT"/image/adspr.jsn "$FWDIR"/ 2>/dev/null || true
	echo "   adsp.mdt + $(ls "$FWDIR"/adsp.b* | wc -l) segments -> $FWDIR/"

	# Sensor hub: split slpi.mdt + slpi.bNN, same loader. Loaded from the rootfs
	# after boot, so it does not need to ride in the initramfs.
	echo ">> staging sensor hub image"
	[ -f "$MNT/image/slpi.mdt" ] || die "slpi.mdt not found in apnhlos/image"
	cp "$MNT"/image/slpi.mdt "$MNT"/image/slpi.b* "$FWDIR"/
	echo "   slpi.mdt + $(ls "$FWDIR"/slpi.b* | wc -l) segments -> $FWDIR/"

	umount "$MNT"

	echo ">> regenerating initramfs (a7xx needs GPU firmware at bind time)"
	mkinitfs
}

# Map the logical partitions inside super with device-mapper and mount
# vendor read-only. make-dynpart-mappings opens super O_RDONLY, reads the
# LP metadata and creates one linear dm target per logical partition; no
# byte of super is written. The mount is ro + norecovery so F2FS replays
# nothing. Only /vendor/etc/sensors is read (about 270 KB): the raw bulk
# reads tools/README warns about are a different thing.
map_vendor() {
	if [ -n "$VENDOR_IMAGE" ]; then
		VMNT=$(mktemp -d)
		echo ">> mounting $VENDOR_IMAGE (stock vendor image, F2FS, read-only)"
		mount -t f2fs -o ro,norecovery,loop "$VENDOR_IMAGE" "$VMNT" \
			|| die "mounting $VENDOR_IMAGE failed: not a raw F2FS vendor image (unsparse it first), or kernel without F2FS"
		[ -d "$VMNT/etc/sensors/config" ] || die "$VENDOR_IMAGE has no etc/sensors/config"
		return 0
	fi
	command -v make-dynpart-mappings >/dev/null \
		|| die "make-dynpart-mappings missing (apk add make-dynpart-mappings)"
	[ -b "$SUPER" ] || [ -L "$SUPER" ] || die "$SUPER not present"
	setro "$SUPER"

	VDEV=
	for n in vendor vendor_a; do
		[ -e "/dev/mapper/$n" ] && VDEV=/dev/mapper/$n && break
	done
	if [ -z "$VDEV" ]; then
		echo ">> mapping the logical partitions of super (metadata only)"
		before=$(ls /dev/mapper)
		make-dynpart-mappings "$SUPER" || die "make-dynpart-mappings failed on $SUPER"
		# udev may still be creating the nodes
		i=0
		while [ $i -lt 10 ]; do
			for n in vendor vendor_a; do
				[ -e "/dev/mapper/$n" ] && VDEV=/dev/mapper/$n && break
			done
			[ -n "$VDEV" ] && break
			sleep 1; i=$((i + 1))
		done
		[ -n "$VDEV" ] || die "no vendor mapping appeared under /dev/mapper"
		for n in $(ls /dev/mapper); do
			case " $before " in *" $n "*) ;; *) DM_CREATED="$DM_CREATED $n";; esac
		done
	fi
	command -v blockdev >/dev/null && blockdev --setro "$VDEV" 2>/dev/null || true

	VMNT=$(mktemp -d)
	echo ">> mounting $VDEV (stock vendor, F2FS, read-only)"
	mount -t f2fs -o ro,norecovery "$VDEV" "$VMNT" \
		|| die "mounting vendor failed — kernel without F2FS, or super not the stock layout?"
	[ -d "$VMNT/etc/sensors/config" ] || die "$VDEV has no etc/sensors/config"
}

# The stock vendor image compresses most files (F2FS LZ4). A kernel built
# without CONFIG_F2FS_FS_COMPRESSION mounts it and hands back garbage for
# those files, so every copied config is checked for JSON.
looks_like_json() {
	c=$(head -c 256 "$1" | tr -d ' \t\r\n' | cut -c1)
	[ "$c" = "{" ] || [ "$c" = "[" ]
}

# Registry from the stock persist partition (ext4, label "persist"), which
# the tablet still carries: sensors/registry/registry/ holds the registry
# the stock hub ran with. Mounted read-only, copied, unmounted. Returns 1
# with a note when persist is missing, will not mount, or has no registry.
registry_from_persist() {
	dst=$HFS/sensors/persist/registry
	if [ -n "$VENDOR_IMAGE" ] || [ -n "$SENSORS_FROM" ]; then
		echo "   not reading the persist partition in this mode"
		return 1
	fi
	if ! [ -b "$PERSIST" ] && ! [ -L "$PERSIST" ]; then
		echo "   no persist partition"
		return 1
	fi
	setro "$PERSIST"
	PMNT=$(mktemp -d)
	if ! mount -o ro,noload "$PERSIST" "$PMNT" 2>/dev/null; then
		rmdir "$PMNT"; PMNT=
		echo "   persist would not mount read-only"
		return 1
	fi
	preg=$PMNT/sensors/registry/registry
	n=$(ls -A "$preg" 2>/dev/null | wc -l)
	if [ "$n" -eq 0 ]; then
		umount "$PMNT"; rmdir "$PMNT"; PMNT=
		echo "   persist has no sensor registry"
		return 1
	fi
	find "$dst" -mindepth 1 -delete
	cp -R "$preg"/. "$dst"/ || die "copying the persist registry failed"
	# Stock keeps its version marker beside the registry; with it in place
	# the SLPI accepts the registry as is instead of rewriting all of it
	# on its first boot (a rewrite shows up as a burst of "Handover
	# signaled" kernel lines).
	if [ -f "$PMNT/sensors/registry/sns_reg_version" ]; then
		install -o fastrpc -g fastrpc -m644 "$PMNT/sensors/registry/sns_reg_version" \
			"$HFS/sensors/persist/sns_reg_version"
		ver="with its version marker"
	else
		rm -f "$HFS/sensors/persist/sns_reg_version"
		ver="no version marker, the SLPI will rewrite it once"
	fi
	umount "$PMNT"; rmdir "$PMNT"; PMNT=
	chown -R fastrpc:fastrpc "$dst"
	find "$dst" -type f -exec chmod 644 {} +
	chmod 775 "$dst"
	echo "   registry from the stock persist partition ($n files, per-unit factory calibration, $ver)"
}

# $1 = directory holding config/ and sns_reg_config
build_sensor_tree() {
	src=$1
	[ -d "$src/config" ] || die "$src/config missing"
	[ -f "$src/sns_reg_config" ] || die "$src/sns_reg_config missing"
	grep -q '^fastrpc:' /etc/passwd \
		|| die "user fastrpc missing — install hexagonrpcd first"

	echo ">> building the HexagonFS tree at $HFS"
	rm -rf "$HFS/sensors/config" "$HFS/socinfo"
	install -d -m755 "$HFS/sensors/config" "$HFS/socinfo"

	n=0
	for f in "$src"/config/*.json; do
		[ -f "$f" ] || continue
		looks_like_json "$f" || die "$(basename "$f") is not JSON: compressed F2FS files unreadable (kernel needs CONFIG_F2FS_FS_COMPRESSION + CONFIG_F2FS_FS_LZ4); use tools/sensors-from-super.sh from the host instead"
		install -m644 "$f" "$HFS/sensors/config/"
		n=$((n + 1))
	done
	[ $n -gt 0 ] || die "no *.json in $src/config"
	echo "   $n sensor configs -> sensors/config/"

	# Stock reads the SSC revision from a Samsung sysfs node; serve it from
	# socinfo instead (the daemon maps socinfo/ as /sys/devices/soc0).
	sed 's#^file=revision=.*#file=revision=/sys/devices/soc0/ssc_hw_rev#' \
		"$src/sns_reg_config" > "$HFS/sensors/sns_reg.conf"
	chmod 644 "$HFS/sensors/sns_reg.conf"
	grep -q '^file=revision=/sys/devices/soc0/ssc_hw_rev$' "$HFS/sensors/sns_reg.conf" \
		|| die "sns_reg_config has no file=revision= line"
	echo "   sns_reg.conf (revision -> socinfo/ssc_hw_rev)"

	# ssc_hw_rev is Android's ro.revision. The bootloader passes it as
	# androidboot.revision when the kernel command line comes from ABL;
	# our command line is baked into the DTS, so fall back to this unit's
	# value.
	# X900: the fallback is 5, the revision of the stock device tree this
	# port's was taken from and of the tablet it was brought up on.
	# --hw-rev overrides it. The stock configs only tell revisions 0-2
	# from 3 and later (the magnetometer file).
	rev=$(tr ' ' '\n' < /proc/cmdline | sed -n 's/^androidboot\.revision=//p' | head -1)
	[ -n "$rev" ] || rev=$HW_REV
	printf '%s\n' "$SOC_ID" > "$HFS/socinfo/soc_id"
	printf '%s\n' "$HW_PLATFORM" > "$HFS/socinfo/hw_platform"
	printf 'Unknown\n' > "$HFS/socinfo/platform_subtype"
	printf '0\n' > "$HFS/socinfo/platform_subtype_id"
	printf '0\n' > "$HFS/socinfo/platform_version"
	printf '%s\n' "$rev" > "$HFS/socinfo/ssc_hw_rev"
	for f in revision family machine; do
		[ -f "/sys/devices/soc0/$f" ] && cp "/sys/devices/soc0/$f" "$HFS/socinfo/$f"
	done
	chmod 644 "$HFS"/socinfo/*
	echo "   socinfo/ (soc_id $SOC_ID, $HW_PLATFORM, ssc_hw_rev $rev)"

	# The SLPI writes here (registry rewrite, sns_reg_version). 775 on the
	# registry: the daemon renames a temporary file into it.
	install -d -o fastrpc -g fastrpc -m755 "$HFS/sensors/persist"
	install -d -o fastrpc -g fastrpc -m775 "$HFS/sensors/persist/registry"
	ln -sfn persist/registry "$HFS/sensors/registry"

	if [ -z "$REFRESH_REGISTRY" ] && [ -n "$(ls -A "$HFS/sensors/persist/registry")" ]; then
		echo "   registry already populated, left as is (--refresh-registry to replace it)"
	elif registry_from_persist; then
		:
	elif command -v sscregistrygen >/dev/null; then
		find "$HFS/sensors/persist/registry" -mindepth 1 -delete
		sscregistrygen -p "$HW_PLATFORM" -s "$SOC_ID" \
			"$HFS/sensors/config" "$HFS/sensors/persist/registry"
		chown -R fastrpc:fastrpc "$HFS/sensors/persist/registry"
		rm -f "$HFS/sensors/persist/sns_reg_version"
		echo "   registry: $(ls "$HFS/sensors/persist/registry" | wc -l) files from sscregistrygen (no factory calibration)"
	else
		echo "   registry left empty (no sscregistrygen); the SLPI generates it"
	fi

	# No daemon restart here: the SLPI reads the tree once at its own boot,
	# and restarting hexagonrpcd breaks its FastRPC session, which the SLPI
	# re-negotiates with a burst of "Handover signaled" kernel messages.
}

# The stock Wi-Fi firmware set, from /vendor/firmware/qca6490. On the X900
# linux-firmware's board-2.bin has an entry for the chip's identity, but
# with it one receive chain is dead and nothing is seen on 5 or 6 GHz
# (device-facts/gts8uwifi/wireless.md). Stock's board file only works with
# stock's firmware, so the four files go in together, under the names
# ath11k asks for and uncompressed.
#
# They can sit beside linux-firmware-ath11k's files. The firmware loader
# tries a plain name before the same name with .zst, so amss.bin, m3.bin
# and regdb.bin win. ath11k asks for board-2.bin before board.bin, and
# linux-firmware's would match, so a board-2.bin holding only the
# container header is put in front of it: no entry matches and the driver
# falls back to board.bin. apk owns none of these names.
#
# $1 = a mounted stock vendor tree
stage_wifi() {
	src=$1/firmware/qca6490
	echo ">> staging the stock Wi-Fi firmware set"
	for f in amss20.bin m3.bin regdb.bin bdwlan.elf; do
		[ -s "$src/$f" ] || die "$f not found in vendor/firmware/qca6490"
		# an F2FS image read without LZ4 support hands back zeros
		[ -n "$(head -c 4096 "$src/$f" | tr -d '\000' | head -c 1)" ] \
			|| die "$f reads as zeros: compressed F2FS file unreadable (kernel needs CONFIG_F2FS_FS_COMPRESSION + CONFIG_F2FS_FS_LZ4)"
	done
	for f in amss20.bin bdwlan.elf; do
		[ "$(head -c 4 "$src/$f" | od -An -tx1 | tr -d ' \n')" = 7f454c46 ] \
			|| die "$f is not an ELF image"
	done
	install -d -m755 "$WIFIDIR"
	install -m644 "$src/amss20.bin" "$WIFIDIR/amss.bin"
	install -m644 "$src/m3.bin" "$WIFIDIR/m3.bin"
	install -m644 "$src/regdb.bin" "$WIFIDIR/regdb.bin"
	install -m644 "$src/bdwlan.elf" "$WIFIDIR/board.bin"
	printf 'QCA-ATH11K-BOARD\000\000\000\000' > "$WIFIDIR/board-2.bin"
	chmod 644 "$WIFIDIR/board-2.bin"
	echo "   amss.bin m3.bin regdb.bin board.bin (+ empty board-2.bin) -> $WIFIDIR/"
}

usage() { die "usage: gts8uwifi-fw-extract [--refresh-registry] [--hw-rev N] [--apnhlos-image FILE] [--vendor-image FILE] [--sensors-from DIR]"; }

SENSORS_FROM=
APNHLOS_IMAGE=
VENDOR_IMAGE=
while [ $# -gt 0 ]; do
	case "$1" in
	--sensors-from)
		[ -n "$2" ] || usage
		SENSORS_FROM=$2
		shift 2
		;;
	--apnhlos-image)
		[ -f "$2" ] || usage
		APNHLOS_IMAGE=$2
		shift 2
		;;
	--vendor-image)
		[ -f "$2" ] || usage
		VENDOR_IMAGE=$2
		shift 2
		;;
	--hw-rev)
		[ -n "$2" ] || usage
		HW_REV=$2
		shift 2
		;;
	--refresh-registry)
		REFRESH_REGISTRY=1
		shift
		;;
	*)
		usage
		;;
	esac
done

if [ -n "$SENSORS_FROM" ]; then
	build_sensor_tree "$SENSORS_FROM"
elif [ -n "$VENDOR_IMAGE" ] && [ -z "$APNHLOS_IMAGE" ]; then
	# only the vendor image was given: leave the apnhlos partition alone
	map_vendor
	stage_wifi "$VMNT"
	build_sensor_tree "$VMNT/etc/sensors"
else
	stage_apnhlos
	echo ">> Wi-Fi set and sensor registry configs from the stock vendor image"
	map_vendor
	stage_wifi "$VMNT"
	build_sensor_tree "$VMNT/etc/sensors"
fi

echo ">> done. Firmware and the sensor tree are in place; effective from the"
echo "   next boot (the SLPI reads its registry once, when it starts)."
