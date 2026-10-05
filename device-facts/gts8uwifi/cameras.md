# SM-X900 revision 5: camera evidence

Recorded 2026-10-05 on kernel `7.2.8-r0`. The X800 story is in
[docs/11](../../docs/11-camera.md).

## The four cameras

From the rev-5 stock device tree and the sensor module files in the stock
vendor image (`com.samsung.sensormodule.*.bin`):

| Camera | Sensor | Control bus | Address | CSIPHY | MCLK | Reset | Enables |
|---|---|---|---|---|---|---|---|
| Rear main | Hi1337 | CCI0 master 1 | `0x21` | 1 | MCLK3, gpio103 | gpio120 | gpio107, gpio117 |
| Rear ultrawide | Hi847 | CCI0 master 0 | `0x21` | 2 | MCLK1, gpio101 | gpio106 | gpio109, gpio117 |
| Front | Hi1337 | CCI1 master 1 | `0x20` | 4 | MCLK4, gpio104 | gpio24 | gpio25, gpio117 |
| Front ultrawide | Hi1337 | CCI1 master 0 | `0x21` | 5 | MCLK4, gpio104 | gpio118 | gpio42, gpio107, gpio117 |

The first three are wired as on the X800 except for the front sensor's
address. The fourth does not exist on the X800. Both front addresses were
found by scanning the bus with the module powered: stock keeps slave
addresses in the module files, not the device tree. The rear main camera
also has a DW9808 lens actuator and a module EEPROM on `i2c@988000`; the
two front modules have EEPROMs there that are not described.

All four sensors report their model id, link to their CSIPHY in the media
graph, and stream through CSID and VFE at 30 frames per second, the only
rate the driver's mode tables carry.

## Frames arrive, pixel data does not

Every byte of every captured frame is zero. It is not the dark room and
not the sensors: with each buffer filled with `0xAA` before it is queued,
the buffers come back still holding `0xAA`. The VFE never writes into
them. The "frame done" events come from the CSID on this hardware, so
they say nothing about the write.

What was checked, all on the front camera unless noted:

| Check | Result |
|---|---|
| All four cameras, two kernels (workbench 7.2, package 7.2.8) | same, buffers untouched |
| `clk_ignore_unused pd_ignore_unused` on the command line | no change |
| `arm-smmu.disable_bypass=0` | no change |
| `mem=5G` | no change |
| VFE1 write master 24 while streaming | enabled (`0x2600` = 1), image address cycling through `0xff000000`, `0xff400000`, `0xff800000`, `0xffc00000`, frame increment 3877056, height 1524, stride 2544 |
| VFE1 bus status while streaming | IRQ, violation, overflow and image-violation status all 0; top IRQ status shows RDI0 SOF and EOF |
| SMMU stream table | `id 0x0800 mask 0x0460` on context bank 5, which covers the eight IFE and SFE stream IDs stock lists |
| SMMU faults | global fault status 0, no context-fault interrupt counted |
| IOMMU group of `acb7000.isp` | type DMA |

So the write master is programmed with the buffers' I/O addresses, sees
frames, raises no error, the stream is matched to a translation context,
nothing faults, and the pages stay as they were.

Reading VFE registers while the block is not streaming resets the SoC; the
register dump above was taken only with a capture running. Booting with
`iommu.passthrough=1` did not reach a shell.

Not tried: the same capture on an X800 with the current kernel (its
frames were last confirmed on a kernel that still booted with the
bring-up flags); a kernel-side dump of the buffer's mapping and contents;
the vfe_lite path by itself; libcamera.
