# SM-X900 revision 5: camera evidence

Recorded 2026-10-05 on kernels `7.2.8-r0` through `7.2.8-r3`. The X800 story is in
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
nothing faults, and the pages stay as they were. The four image addresses
read from the write master (`0xff000000`, `0xff400000`, `0xff800000`,
`0xffc00000`) are the four queued buffers' IOVAs, 4 MiB apart, not stale
values — so the addressing is right.

### Interrupt trace, 2026-10-05 (kernel 7.2.8-r3)

A 30-frame rear capture, counting only `/proc/interrupts` (no register
reads), showed where the pipeline stops:

| Interrupt | Delta over 30 frames | Meaning |
|---|---|---|
| `ac15000.cci` (CCI0) | +1558 | the sensor is configured and polled over I2C |
| `acb7000.isp_msm_csid2` | +46 | the CSID raises RUP and buf-done, about 1.5 per frame |
| `acb7000.isp_msm_csiphy*` | 0 | CSIPHY only interrupts on error; none |
| `acb7000.isp_msm_vfe*` | 0 | the VFE680 ISR is a stub, expected |

`v4l2-ctl` dequeued all 30 buffers at 30.0 fps with full `bytesused`, each
one entirely zero. So the completion path is whole: the CSID interrupt
drives `camss_buf_done` → `vfe_buf_done` → `vb2_buffer_done`, which is why
frames flow at sensor rate. The gap is only that the VFE bus write master,
though enabled and addressed, never writes beats into DDR. The problem is
the CSID-to-bus datapath or the bus client's own enable/CGC in the young
VFE680 code (`vfe_wm_start` programs the client minimally and the ISR does
nothing), not the buffer handoff, the addresses, the SMMU or the sensor.

Reading VFE registers while the block is not streaming resets the SoC; the
register dump above was taken only with a capture running. Booting with
`iommu.passthrough=1` did not reach a shell.

### Tested: the VFE480 bus-client writes the 680 omits (no change)

The working `camss-vfe-480.c` (SM8250) does two things in `vfe_wm_start`
that `camss-vfe-680.c` does not: it writes `WM_CGC_OVERRIDE_ALL`
(`0x3ffffff`) to the bus CGC-override register to stop clock-gating the
bus input, and it sets the write-master mode to `MIPI_RAW` rather than
only the enable bit. The two drivers' bus register maps align exactly
(680 bus base `0xc00`, CGC at `+0x08` = `0xc08`, WM block at `+0x200`),
so a patch added both to the 680 (kept in
`root-build/camera-leads/camss-vfe-680-wm-bus-enable.patch`). Built as
`7.2.8-r4` and captured: the write master is still never written, every
byte of every frame is still zero. So the gap is not the bus client's
clock gate or mode. The patch is not committed.

### The write master is starved, 2026-10-05 (downstream compared)

The SM8450 downstream camera driver (LineageOS `camera-kernel`,
`cam_vfe680.h` + `cam_vfe_bus_ver3.c`, kept in `root-build/camera-leads/`)
gives the authoritative write-master programming for this exact bus
(RDI0 = client 24 at `0x2600`, bus base `0xc00`, CGC at `0xc08`). Against
it the mainline `vfe_wm_start` is wrong in three places: it leaves the
packer format at 0 (`PLAIN_128`) while the data is MIPI RAW10 (should be
`MIPI10`, enum 12); it packs `(height<<16)|(stride>>4)` into `image_cfg_0`
where the downstream uses the RDI default width `0xffff` with height 0;
and it never writes the bus CGC override. (The gen3 `addr >> 8` and the
`MODE` bit are a *different* bus generation — the downstream writes the
full byte address and `en_cfg = 0x1` for RDI, matching the original 680.)

Each was tried on the tablet (patches in `root-build/camera-leads/`, none
committed):

| Write-master config | Result |
|---|---|
| mainline as-is (packer `PLAIN_128`) | 30 fps, buffers dequeue, every byte 0xAA (prefill) untouched |
| + CGC override + `MODE` bit (480 style) | same: completes, nothing written |
| full gen3 port (`addr>>8`, defaults) | same: completes, nothing written |
| packer `MIPI10` (+ CGC), any `image_cfg_0` | **stream stalls**: `STREAMON`/`QBUF` succeed, no buffer ever dequeues, no dmesg error |

That last line is the decisive one. With the packer at `PLAIN_128` the
write master "completes" each frame instantly and empty; with the packer
set to the real `MIPI10` it waits forever and nothing completes. Both mean
the same thing: **no pixel beats are arriving at write-master 24.** The
master is correctly addressed and enabled but starved — the CSID's RDI
pixel stream never reaches the IFE bus. The CSID's buf-done is a frame-timing
counter, not proof of a write.

So the gap is not in the write-master registers at all (every value was
tried). It is the IFE **top/core** datapath that the mainline `vfe-680`
driver does not implement: it writes only IRQ masks and the bus client,
and nothing to the VFE top (`core_cfg_0..6`, `core_cgc_ovd_0/1` at
`0x18/0x1c`, `ahb_cgc_ovd` at `0x20`, the module-enable and the CSID→IFE
input mux that the downstream `cam_vfe_top_ver4` programs on stream-on).
Bringing RDI capture up on this SoC needs that top-level datapath ported,
which is a substantial driver effort, not a register tweak.

Next session, with the above established: port the VFE680 top enable from
`cam_vfe_top_ver4.c` (core CGC overrides, `core_cfg`, module/RDI enable)
and re-test with the packer set to `MIPI10`; a kernel-side dump of the WM
`ADDR_STATUS`/beat counter during a stream would confirm when beats start.

Not tried: the VFE-top datapath port (the main remaining work); the
vfe_lite path by itself; libcamera. No X800 is available to compare.
