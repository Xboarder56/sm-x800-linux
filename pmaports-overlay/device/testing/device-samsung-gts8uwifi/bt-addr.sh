#!/bin/sh
# gts8uwifi-bt-addr: give hci0 its public Bluetooth address.
#
# The WCN6855 on the Bluetooth UART completes QCA firmware setup and then
# sits there unconfigured: `btmgmt info` lists no controller and bluetoothd
# reports "No default controller available". Nothing supplies the
# controller's address. The DT `bluetooth` node has no `local-bd-address`
# and the bootloader fills none. hci_qca flags the address invalid and the
# core leaves the controller unconfigured until userspace sets one over the
# management interface. (As on the Tab S8+, whose helper this follows.)
#
# Stock keeps the factory address on the `efs` partition in
# bluetooth/bt_addr: its init scripts point ro.bt.bdaddr_path there and the
# Bluetooth HAL reads it. On the Tab S8+ the file holds two addresses back
# to back; the first 17 characters are the Bluetooth address.
#
# Order of sources:
#   1. BT_ADDR in /etc/conf.d/gts8uwifi-bt-addr, if the owner set one.
#   2. /var/lib/gts8uwifi/bt_addr, saved by an earlier run.
#   3. efs, once: the partition is switched read-only at the block layer
#      and mounted without journal replay, the address is saved to (2) and
#      efs is not mounted again on later boots. BT_ADDR_FROM_EFS=no in
#      the conf file skips this step.
#   4. A locally administered address (02:xx:xx:xx:xx:xx) derived from
#      /etc/machine-id, stable across boots, so the controller still comes
#      up. Not saved, so a later boot can still pick up (3).
#
# Unlike the Tab S8+ helper this does not mount efs on every boot.
#
# Pulled in by 90-gts8uwifi-bt-addr.rules when hci0 appears. The add event
# fires before firmware setup finishes and the management interface answers
# "Invalid Index" until it has, so the set is retried for a while.
#
# Idempotent: exits 0 without touching anything if hci0 already has an
# address. POSIX sh (busybox ash).

set -u

TAG=gts8uwifi-bt-addr
HCI=${HCI_INDEX:-0}
CONF=/etc/conf.d/$TAG
SAVED=/var/lib/gts8uwifi/bt_addr
EFS_DEV=/dev/disk/by-partlabel/efs
MNT=/run/$TAG/efs
ADDR_RE='^[0-9A-Fa-f]\{2\}\(:[0-9A-Fa-f]\{2\}\)\{5\}$'
RETRIES=30

log() {
	logger -t "$TAG" "$*" 2>/dev/null || echo "$TAG: $*" >&2
}

die() {
	log "$*"
	exit 1
}

valid() {
	printf '%s\n' "$1" | grep -q "$ADDR_RE" && [ "$1" != "00:00:00:00:00:00" ]
}

mounted() {
	grep -qs " $MNT " /proc/mounts
}

cleanup() {
	if mounted; then
		umount "$MNT" 2>/dev/null || log "warning: umount $MNT failed"
	fi
}
trap cleanup EXIT

# Already configured? `btmgmt info` prints an "addr" line only for a
# configured controller (an unconfigured one answers Invalid Index).
current=$(btmgmt -i "$HCI" info 2>/dev/null \
	| sed -n 's/^[[:space:]]*addr \([0-9A-Fa-f:]\{17\}\).*/\1/p' | head -n 1)
if [ -n "$current" ] && [ "$current" != "00:00:00:00:00:00" ]; then
	log "hci$HCI already configured, nothing to do"
	exit 0
fi

addr=
source=

# 1. The owner's choice.
BT_ADDR=
BT_ADDR_FROM_EFS=yes
[ -r "$CONF" ] && . "$CONF"
if [ -n "$BT_ADDR" ]; then
	if valid "$BT_ADDR"; then
		addr=$BT_ADDR
		source="$CONF"
	else
		log "BT_ADDR in $CONF is not an address, ignoring"
	fi
fi

# 2. Saved by an earlier run.
if [ -z "$addr" ] && [ -r "$SAVED" ]; then
	candidate=$(head -c 17 "$SAVED" 2>/dev/null)
	if valid "$candidate"; then
		addr=$candidate
		source="$SAVED"
	fi
fi

# 3. Factory address from efs, read once.
if [ -z "$addr" ] && [ "$BT_ADDR_FROM_EFS" != yes ]; then
	log "BT_ADDR_FROM_EFS is not yes, leaving efs alone"
elif [ -z "$addr" ] && [ -e "$EFS_DEV" ]; then
	dev=$(readlink -f "$EFS_DEV")
	fstype=$(blkid -o value -s TYPE "$dev" 2>/dev/null)
	case "$fstype" in
		ext4) opts=ro,noload ;;
		f2fs) opts=ro,norecovery ;;
		*) opts= ;;
	esac
	if [ -z "$opts" ]; then
		log "efs is '$fstype', not a filesystem this helper mounts"
	elif ! blockdev --setro "$dev" 2>/dev/null; then
		log "could not switch $dev read-only, leaving efs alone"
	else
		mkdir -p "$MNT"
		if mount -t "$fstype" -o "$opts" "$dev" "$MNT" 2>/dev/null; then
			if [ -r "$MNT/bluetooth/bt_addr" ]; then
				candidate=$(head -c 17 "$MNT/bluetooth/bt_addr" 2>/dev/null)
				if valid "$candidate"; then
					addr=$candidate
					source="efs bluetooth/bt_addr"
					mkdir -p "$(dirname "$SAVED")"
					(umask 077; printf '%s\n' "$addr" > "$SAVED")
				else
					log "efs bluetooth/bt_addr does not start with an address, ignoring"
				fi
			else
				log "efs has no bluetooth/bt_addr"
			fi
			cleanup
		else
			log "could not mount $dev read-only"
		fi
	fi
fi

# 4. Fallback: locally administered address from the machine id.
if [ -z "$addr" ]; then
	id=$(tr -cd '0-9a-fA-F' < /etc/machine-id 2>/dev/null | head -c 10)
	[ ${#id} -eq 10 ] || die "no usable address: no saved or efs address and /etc/machine-id unreadable"
	addr="02:$(printf '%s' "$id" | sed 's/\(..\)/\1:/g; s/:$//')"
	source="machine-id fallback"
fi

valid "$addr" || die "internal error: derived address is malformed"

# Hand it to the kernel. Retry while the controller is still in setup.
# The address itself is not logged.
n=0
while :; do
	if out=$(btmgmt -i "$HCI" public-addr "$addr" 2>&1); then
		log "hci$HCI public address set ($source)"
		exit 0
	fi
	n=$((n + 1))
	if [ "$n" -ge "$RETRIES" ]; then
		die "failed to set hci$HCI public address ($source) after $n attempts: $(printf '%s' "$out" | tail -n 1)"
	fi
	sleep 1
done
