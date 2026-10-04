# SM-X900 revision 5: memory evidence

Updated, 2026-10-03. This records read-only Android observations and R7's live
ABL memory-map capture. R11 adds a working USB serial shell and a successful
512 MiB allocation/write/read check; this is a bounded sample, not validation
of every RAM bank. Source inventory and firmware caveat:
[bring-up checkpoint](../../docs/14-gts8uwifi-bringup.md).

## Live DYDC observations

Collected through an ordinary ADB shell on SM-X900, `ro.revision=5`,
`ro.build.PDA=X900XXU9DYDC`:

| Observation | Value |
|---|---|
| `getconf PAGE_SIZE` | 4096 bytes |
| `/proc/meminfo` `MemTotal` | 11,546,768 kB |
| `/sys/devices/system/memory` directory entries | memory16..31, memory256..335 |
| DMA32 `start_pfn` / `spanned` / `present` | 524288 / 524288 / 492544 |
| Normal `start_pfn` / `spanned` / `present` | 1048576 / 9961472 / 2601728 |

The zone figures are pages. DMA32 spans `[0x80000000, 0x100000000)`;
Normal spans `[0x100000000, 0xa80000000)`. The latter includes a large hole;
the zone's start is not necessarily the start of its first populated bank.
Present pages total 1,924 MiB in DMA32 and 10,163 MiB in Normal.

Assuming 128 MiB blocks, the enumerated blocks imply these physical ranges:

| Base | Size | End, exclusive |
|---|---|---|
| `0x80000000` | `0x80000000` (2 GiB) | `0x100000000` |
| `0x800000000` | `0x280000000` (10 GiB) | `0xa80000000` |

The handoff supplies the 128 MiB block assumption. This session could list the
block directories but could not read `block_size_bytes` or `phys_index`.
Neither the populated block list nor zone totals identify all reserved holes.

## Android shell limitations before R7

`/sys/firmware/fdt` exists (864,115 bytes) but is root-readable only.
The `/sys/firmware/devicetree/base/memory` directory exists; its `reg` property
and even `model`/`compatible` are permission-denied to this shell. No `su`
executable was found on the shell's PATH. No rooting or partition changes were
attempted to obtain these reads.

The offline merged stock tree has a zero-length memory placeholder; it cannot
replace a capture after ABL has populated the memory map. Its reserved-memory
nodes have now been compared using the matching DYDC base and rev-5 overlay.

## Superseded sibling-derived map

The experimental r44 DTS used five X800-derived ranges totaling 8,013 MiB,
ending at `0x980000000`. Although they fit Android's inferred bank envelope,
R6 took an external abort during page clearing. R7 subsequently identified
holes inside that envelope; r44 is not the current map.

Compared with R1, the DTS additionally reserves the Samsung debug envelope
`[0x800100000, 0x80b900000)` and places XBL ramdump at
`[0xa7d00000, 0xa8000000)`, as in the DYDC tree. The old X800 XBL address
was not authoritative for X900.

That DTB passed the static DYDC reservation audit despite its runtime fault:
the offline stock tree has no populated RAM map and lacks ABL's additional
reservations. The current audit also consumes the live ranges captured in R7.

## R6 on-device failure

A tiny raw initramfs reaches its diagnostic userspace, reports MemTotal
6,522,492 kB, and finds the USB UDC. It then faults in `clear_page+0x30/0x70`
with a synchronous external abort (`0x96000010`) and destination
`x0=0xffff0007bce00000`. Converting this linear-map virtual address to a
physical address requires the actual kernel mapping offset; the register
alone is not a direct physical-RAM measurement.

Full initramfs stalls may share this cause, but that is not yet proven.

## R7 live ABL capture

The opt-in uniLoader diagnostic preserves the incoming arm64 x0 FDT before
image relocation, prints its memory banks and missing reservations, then halts
without starting Linux. The user photo confirms a valid 864,115-byte tree.
Its address ranges are transcribed in
[abl-memory-dydc-rev5.json](abl-memory-dydc-rev5.json); no stock blob or chosen
properties are published.

| ABL RAM base | End, exclusive |
|---|---|
| `0x80000000` | `0xea000000` |
| `0xf1c00000` | `0x100000000` |
| `0x800000000` | `0x839500000` |
| `0x839b00000` | `0x83b900000` |
| `0x840000000` | `0x900000000` |
| `0x900000000` | `0xa80000000` |

The r44 X800-derived ranges wrongly expose parts of
`[0x839500000, 0x839b00000)` and `[0x83b900000, 0x840000000)`.
The R6 faulting virtual address is consistent with physical `0x83ce00000`
under the expected 48-bit linear-map offset with base RAM `0x80000000`;
that inferred address lies in the second missing region.

ABL also exposes three runtime reservations that r44 lacks:

| Node | Base | End, exclusive |
|---|---|---|
| `kaslr_region` | `0xb01ff000` | `0xb0200000` |
| `uh_heap_region` | `0xb0200000` | `0xb0240000` |
| `uh_guest_region` | `0xb1000000` | `0xb2a00000` |

Kernel packages r45/r46 use only ABL-reported RAM below the previous `0x980000000` upper limit
and reserve those three regions with `no-map`. This is evidence for this
12 GiB rev-5 tablet running DYDC; other capacities or firmware require a live
map. A future normal uniLoader path should transfer ABL's memory and runtime
reservations rather than relying on board-specific hardcoded values.

Audit a packaged DTB against both offline and runtime evidence:

```sh
python3 -B tools/dt-memory-audit.py \
  root-build/kernel-r46/boot/dtbs/qcom/sm8450-samsung-gts8uwifi.dtb \
  root-build/stock-dydc/x900-rev5-stock.dtb \
  --runtime-map device-facts/gts8uwifi/abl-memory-dydc-rev5.json
```

## R11 runtime checks

The serial shell reports `MemTotal=6473176 kB`. `/proc/iomem` excludes both
high-bank holes identified in R7 and marks the three additional firmware
reservations unavailable. Kernel code begins at `0x80b900000`, matching the
loader's payload entry. The full iomem and dmesg captures stay in ignored
`root-build/gts8uwifi-debug-r11/serial-first.txt`.

A 512 MiB tmpfs file was allocated, filled with zeros and read back for
SHA-256. Both the write status and checksum match:
`9acca8e8c22201155389f65abbf6bc9723edc7384ead80503839f49dcc56d767`.
The file was then removed. The full 11,802,461-byte postmarketOS initramfs
was also uploaded to `/run` with a matching checksum, gzip-tested, unpacked
into RAM, and its BusyBox executed in a chroot. All returned success.
The kernel log shows no new external abort during these observations;
the diagnostic shell and USB link remain operational.

These checks exercise Linux allocation and the actual postmarketOS ramdisk
on the corrected map. They do not explain the earlier R9/R10 black screens,
validate the excluded upper RAM, or prove all allocatable pages writable.

## Full map, 2026-10-04

Kernel package `7.2-r77` exposes all six ABL banks, ending at `0xa80000000`.
The static audit advertises 12,087 MiB and passes against the stock
reservations and the captured runtime ranges. On the tablet `MemTotal` is
10,581,440 kB (6,473,168 kB with the earlier limit) and `/proc/iomem` shows
`840000000-a7fffffff : System RAM`.

A tmpfs was filled with 148 copies of a random 64 MiB block (9,536 MiB,
leaving about 560 MiB free) and every copy matched the original's SHA-256;
no external abort or other fault was logged. That was run twice in the
initramfs shell on a workbench build of the same sources. It exercises page
allocation and clearing across the banks; it is not a pattern memory test.

