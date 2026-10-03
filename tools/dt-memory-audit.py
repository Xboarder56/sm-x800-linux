#!/usr/bin/env python3
"""Compare a compiled board's RAM/reservations with an offline stock DTB.

This proves static coverage only. It cannot discover bootloader-added regions.
Stock blobs remain local; output contains address ranges, never identifiers.
"""

import argparse
import json
from pathlib import Path
import struct


def read_fdt(path):
    data = Path(path).read_bytes()
    header = struct.unpack_from(">10I", data)
    magic, total, offset, strings_offset, reserve_offset = header[:5]
    if magic != 0xD00DFEED or not 40 <= total <= len(data):
        raise ValueError(f"Invalid FDT header: {path}")
    strings = data[strings_offset:strings_offset + header[8]]
    nodes, stack, reservations = {}, [], []
    while True:
        address, size = struct.unpack_from(">QQ", data, reserve_offset)
        reserve_offset += 16
        if not address and not size:
            break
        reservations.append((address, address + size))
    while offset < total:
        token, = struct.unpack_from(">I", data, offset)
        offset += 4
        if token == 1:  # FDT_BEGIN_NODE
            end = data.index(0, offset, total)
            stack.append(data[offset:end].decode())
            offset = (end + 4) & ~3
            nodes["/".join(stack) or "/"] = {}
        elif token == 2:
            stack.pop()
        elif token == 3:  # FDT_PROP
            length, name_offset = struct.unpack_from(">II", data, offset)
            offset += 8
            name = strings[name_offset:strings.index(0, name_offset)].decode()
            if offset + length > total:
                raise ValueError("Truncated FDT property")
            nodes["/".join(stack) or "/"][name] = data[offset:offset + length]
            offset = (offset + length + 3) & ~3
        elif token == 4:
            continue
        elif token == 9:
            return nodes, reservations
        else:
            raise ValueError(f"Unexpected FDT token {token}")
    raise ValueError("Missing FDT_END")


def cells(value):
    return int.from_bytes(value, "big")


def reg_ranges(nodes, path):
    parent = path.rsplit("/", 1)[0] or "/"
    ac = cells(nodes[parent].get("#address-cells", b"\0\0\0\2"))
    sc = cells(nodes[parent].get("#size-cells", b"\0\0\0\1"))
    width = 4 * (ac + sc)
    reg = nodes[path].get("reg", b"")
    if not width or len(reg) % width:
        raise ValueError(f"Invalid reg cell count: {path}")
    for offset in range(0, len(reg), width):
        start = cells(reg[offset:offset + 4 * ac])
        size = cells(reg[offset + 4 * ac:offset + width])
        if size:
            yield start, start + size


def subtract(ranges, cuts):
    for lo, hi in cuts:
        new = []
        for start, end in ranges:
            if hi <= start or lo >= end:
                new.append((start, end))
            else:
                if start < lo:
                    new.append((start, lo))
                if hi < end:
                    new.append((hi, end))
        ranges = new
    return ranges


def enabled(nodes, path):
    while path:
        if nodes[path].get("status", b"okay\0").rstrip(b"\0") not in (b"ok", b"okay"):
            return False
        if path == "/":
            break
        path = path.rsplit("/", 1)[0] or "/"
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("board_dtb")
    parser.add_argument("stock_dtb")
    parser.add_argument("--runtime-map", type=Path,
                        help="transcribed ABL RAM and additional reservations (JSON)")
    args = parser.parse_args()
    board, board_reservations = read_fdt(args.board_dtb)
    stock, stock_reservations = read_fdt(args.stock_dtb)
    memory = []
    for path, props in board.items():
        if props.get("device_type") == b"memory\0" and enabled(board, path):
            memory.extend(reg_ranges(board, path))
    if not memory:
        raise SystemExit("FAIL: board has no nonempty memory ranges")
    for nodes, reserved in [(board, board_reservations), (stock, stock_reservations)]:
        for path in nodes:
            if path.startswith("/reserved-memory/") and path.count("/") == 2:
                if enabled(nodes, path):
                    reserved.extend(reg_ranges(nodes, path))
    usable = subtract(memory, board_reservations)
    outside = []
    if args.runtime_map:
        runtime = json.loads(args.runtime_map.read_text())
        live_memory = [(int(s, 0), int(e, 0)) for s, e in runtime["memory"]]
        outside = subtract(memory, live_memory)
        for reservation in runtime["additional_reservations"]:
            start, end = reservation["range"]
            stock_reservations.append((int(start, 0), int(end, 0)))
    missing = []
    for start, end in stock_reservations:
        for lo, hi in usable:
            if max(start, lo) < min(end, hi):
                missing.append((max(start, lo), min(end, hi)))
    print("Board RAM ranges (end exclusive):")
    for start, end in sorted(memory):
        print(f"  0x{start:x}..0x{end:x} ({(end-start)/1048576:g} MiB)")
    print(f"Advertised: {sum(e-s for s,e in memory)/1048576:g} MiB")
    print("Stock reserved ranges exposed as allocatable board RAM:")
    for start, end in sorted(set(missing)):
        print(f"  FAIL 0x{start:x}..0x{end:x}")
    if args.runtime_map:
        print("Board memory outside captured ABL RAM:")
        for start, end in outside:
            print(f"  FAIL 0x{start:x}..0x{end:x}")
        if not outside:
            print("  none")
    if missing or outside:
        raise SystemExit(1)
    if args.runtime_map:
        print("Coverage PASS against offline reservations and captured runtime ranges")
        print("Allocation/runtime testing is still required")
    else:
        print("  none (static coverage PASS; runtime map still requires verification)")


if __name__ == "__main__":
    main()
