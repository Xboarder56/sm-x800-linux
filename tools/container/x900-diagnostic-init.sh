#!/bin/busybox ash
# Temporary BOOT-only diagnostic PID 1. Never mounts or writes UFS storage.
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
/bin/busybox --install -s
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
exec </dev/console >/dev/console 2>&1
mount -t tmpfs tmpfs /run
mount -t debugfs debugfs /sys/kernel/debug
mount -t configfs configfs /sys/kernel/config
mkdir -p /dev/pts
mount -t devpts devpts /dev/pts

echo '=== X900 diagnostic init reached ==='
uname -a
cat /proc/cmdline
grep -E 'MemTotal|MemFree' /proc/meminfo
echo '=== USB controller and deferred probes ==='
ls -l /sys/class/udc
cat /sys/kernel/debug/devices_deferred
echo '=== UFS block devices (read-only discovery) ==='
ls /sys/class/block
echo '=== Recent kernel messages ==='
dmesg | tail -90

g=/sys/kernel/config/usb_gadget/x900_debug
mkdir -p "$g"
echo 0x18d1 > "$g/idVendor"
echo 0xd001 > "$g/idProduct"
echo 0x02 > "$g/bDeviceClass"
mkdir -p "$g/strings/0x409"
echo postmarketOS-debug > "$g/strings/0x409/serialnumber"
echo Samsung > "$g/strings/0x409/manufacturer"
echo 'Galaxy Tab S8 Ultra debug serial' > "$g/strings/0x409/product"
mkdir -p "$g/functions/acm.usb0" "$g/configs/c.1"
ln -s "$g/functions/acm.usb0" "$g/configs/c.1/acm.usb0"
cat > /sbin/x900-debug-getty <<'EOF'
#!/bin/busybox ash
echo 'X900 diagnostic USB shell; UFS filesystems remain unmounted.'
exec /bin/sh
EOF
chmod +x /sbin/x900-debug-getty

start_serial() {
    # Wait for a host newline before the getty starts, as PMOS does.
    echo ' ' > /dev/ttyGS0
    read -r < /dev/ttyGS0
    while /sbin/getty -n -l /sbin/x900-debug-getty ttyGS0 115200 vt100; do
        sleep 1
    done
}
start_serial &

# Allow delayed probes to finish without hiding why they are waiting.
while :; do
    if [ -z "$(cat "$g/UDC" 2>/dev/null)" ]; then
        for udc in /sys/class/udc/*; do
            [ -e "$udc" ] || continue
            echo "Binding USB serial gadget to ${udc##*/}"
            echo "${udc##*/}" > "$g/UDC"
            break
        done
    fi
    echo "=== Diagnostic heartbeat: $(cat /proc/uptime); UDC=$(cat "$g/UDC" 2>/dev/null) ==="
    cat /sys/kernel/debug/devices_deferred
    sleep 20
done
