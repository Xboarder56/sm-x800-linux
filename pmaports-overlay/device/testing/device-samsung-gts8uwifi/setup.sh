#!/bin/sh
# gts8uwifi-setup — assemble the daily-driver from a minimal rootfs.
#
# EndeavourOS-style: the flashed image stays minimal; the "distribution" is
# a package selection applied on device. Alpine's native unit for that is
# the metapackage, so this is mostly one apk transaction plus the firmware
# extraction that no image or package may carry. (The Tab S8+ package's
# gts8pwifi-setup, for the Tab S8 Ultra.)
#
#   gts8uwifi-setup                 toolkit only (device-samsung-gts8uwifi-tools)
#   gts8uwifi-setup plasma          toolkit + Plasma Desktop 6 (KWin Wayland)
#   gts8uwifi-setup [plasma] -- OPTIONS
#                                   OPTIONS go to gts8uwifi-fw-extract, for
#                                   example --apnhlos-image and --vendor-image
#                                   to take the firmware from the stock
#                                   firmware package instead of the tablet's
#                                   own partitions

set -e

if [ "$(id -u)" != 0 ]; then
	echo "run as root (sudo gts8uwifi-setup)" >&2
	exit 1
fi

ui=
if [ "$1" = "plasma" ]; then
	ui=plasma
	shift
fi
[ "$1" = "--" ] && shift

echo ">> installing device toolkit metapackage"
apk add device-samsung-gts8uwifi-tools

if [ "$ui" = "plasma" ]; then
	echo ">> installing Plasma Desktop (KDE 6, KWin Wayland)"
	apk add postmarketos-ui-plasma-desktop plasma-keyboard
	# A tablet without a keyboard attached: make the Plasma on-screen
	# keyboard the system default input method. KWin has none selected
	# out of the box, and then nothing pops up in a text field once
	# logged in. A user's own choice in System Settings still wins.
	if command -v kwriteconfig6 >/dev/null \
		&& [ -z "$(kreadconfig6 --file /etc/xdg/kwinrc --group Wayland --key InputMethod 2>/dev/null)" ]; then
		kwriteconfig6 --file /etc/xdg/kwinrc --group Wayland --key InputMethod \
			/usr/share/applications/org.kde.plasma.keyboard.desktop
		kwriteconfig6 --file /etc/xdg/kwinrc --group Wayland --key VirtualKeyboardEnabled true
		echo "   on-screen keyboard set as the default input method"
	fi
fi

echo ">> extracting device-signed firmware, the Wi-Fi set and the sensor registry configs"
gts8uwifi-fw-extract "$@"

cat <<'EOF'
>> done. Remaining manual bits:
   - WiFi profile (lost with the root filesystem):
       nmcli dev wifi connect <ssid> password <pw>
   - reboot to pick up the initramfs with GPU firmware, the Wi-Fi
     firmware set, and to let the sensor hub read its registry
     (ssccli --sensor accelerometer to check)
EOF
