#!/usr/bin/env python3
"""Check the X900 debug image's embedded payloads and relocation ranges."""

import argparse
import importlib.util
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("artifact_dir", type=Path)
    args = parser.parse_args()
    spec = importlib.util.spec_from_file_location(
        "dt_memory", Path(__file__).with_name("dt-memory-audit.py")
    )
    dt = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(dt)
    out = args.artifact_dir
    nodes, reserved = dt.read_fdt(out / "dtb")
    memory = []
    for path, props in nodes.items():
        if props.get("device_type") == b"memory\0" and dt.enabled(nodes, path):
            memory.extend(dt.reg_ranges(nodes, path))
        if path.startswith("/reserved-memory/") and path.count("/") == 2:
            if dt.enabled(nodes, path):
                reserved.extend(dt.reg_ranges(nodes, path))
    usable = dt.subtract(memory, reserved)
    config = dict(
        line.split("=", 1) for line in (out / "gts8uwifi.config").read_text().splitlines()
        if line.startswith("CONFIG_") and "=" in line
    )
    loader = (out / "gts8uwifi-uniLoader").read_bytes()
    ranges = []
    for name, key, size in [
        ("Image", "CONFIG_PAYLOAD_ENTRY", (out / "Image").stat().st_size),
        ("initramfs", "CONFIG_RAMDISK_ENTRY", (out / "initramfs").stat().st_size),
        ("dtb", "CONFIG_DTB_ENTRY", int(config["CONFIG_FDT_BUF_SIZE"], 0)),
    ]:
        data = (out / name).read_bytes()
        if loader.find(data) < 0:
            raise SystemExit(f"FAIL: {name} does not match the embedded payload")
        start = int(config[key], 0)
        end = start + size
        if not any(lo <= start and end <= hi for lo, hi in usable):
            raise SystemExit(f"FAIL: {name} relocation is outside allocatable DT RAM")
        ranges.append((start, end, name))
        print(f"{name}: 0x{start:x}..0x{end:x} ({size} bytes)")
    if config.get("CONFIG_BOOTLOADER_FDT_DIAGNOSTIC") == "y":
        start = int(config["CONFIG_DTB_ENTRY"], 0)
        end = start + 0x200000
        if not any(lo <= start and end <= hi for lo, hi in usable):
            raise SystemExit("FAIL: incoming FDT scratch is outside allocatable DT RAM")
        # This diagnostic halts before DTB relocation, so it reuses that buffer.
        for lo, hi, name in ranges:
            if name != "dtb" and start < hi and lo < end:
                raise SystemExit(f"FAIL: incoming FDT scratch overlaps {name}")
        loader_start = int(config["CONFIG_TEXT_BASE"], 0)
        loader_end = loader_start + len(loader)
        if start < loader_end and loader_start < end:
            raise SystemExit("FAIL: incoming FDT scratch overlaps relocated uniLoader")
        print(f"Incoming FDT scratch: 0x{start:x}..0x{end:x} (halts before Linux)")
    for left, right in zip(sorted(ranges), sorted(ranges)[1:]):
        if left[1] > right[0]:
            raise SystemExit(f"FAIL: {left[2]} overlaps {right[2]}")
    cmdline = (out / "cmdline").read_bytes()
    if not cmdline.endswith(b"\0") or b"pmos.debug-shell" not in cmdline:
        raise SystemExit("FAIL: missing debug-shell command line")
    if b"pmos_root_uuid=" in cmdline or b"pmos_boot_uuid=" in cmdline:
        raise SystemExit("FAIL: first debug boot contains rootfs UUIDs")
    if loader.find(cmdline) < 0:
        raise SystemExit("FAIL: command line does not match the embedded payload")
    print("Embedded payloads and relocation ranges PASS (static DT only)")


if __name__ == "__main__":
    main()
