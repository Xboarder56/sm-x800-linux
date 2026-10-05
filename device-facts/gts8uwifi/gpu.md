# SM-X900 revision 5: Adreno 730 evidence

Recorded 2026-10-04 on kernel `7.2-r81` to `7.2-r83` sources with the root
filesystem on the microSD card. Enabling the GPU is described in
[docs/14](../../docs/14-gts8uwifi-bringup.md).

## The desktop hang was the HFI interrupt handler

Symptom, under Plasma and worst with touch use: the UI froze for a second
at a time, and after seconds to minutes the GPU hung and the login screen
or session went down.

    Message HFI_H2F_MSG_GX_BW_PERF_VOTE id 282 timed out waiting for response
    Unexpected message id 282 on the response queue
    Timeout waiting for GMU OOB set GPU_SET: 0x0
    07030001: hangcheck recover!

The GMU had answered every time. Replies to HFI messages and to OOB
requests are bits in `GMU2HOST_INTR_INFO`, which the driver polls. The HFI
interrupt exists for the firmware fault bit only, but its handler wrote
back everything it read, so whenever it ran it also cleared a reply nobody
had seen yet. The waiter then sat out its one second timeout.

The handler should not run outside a fault. It did because the GMU powers
up with `GMU2HOST_INTR_MASK` reading 0, everything unmasked, and the driver
only wrote the mask after the boot messages had been exchanged. The
replies to those messages raise the line, and the interrupt was then taken
11 to 300 µs after `enable_irq()`, just as the driver sends its first
frequency vote.

It needs the CPUs to be allowed into their power-collapse idle state
(`cpu-sleep-0-0`, cpuidle state1). That is why continuous rendering was
clean and a compositor that lets the GPU idle between frames was not: KWin
reads the GPU timestamp every frame, which resumes the GMU each time it
has runtime suspended (66 ms autosuspend).

Reproducer with the panel off: a client that waits 120 ms, then asks for
`MSM_PARAM_TIMESTAMP`, one GMU suspend and resume per query. The handler
counts are from counters added for the test in the first four rows and
from `/proc/interrupts` in the last two.

| Kernel | Resumes | Handler ran | Reply bit taken | Timed out votes |
|---|---|---|---|---|
| Unchanged, CPU idle allowed | 800 | 112 | 12 | 12 |
| Unchanged, cpuidle state1 disabled | 1200 | not counted | not counted | 0 |
| Handler leaves reply bits alone | 600 | 215 | 0 (seen 46 times) | 0 |
| Mask written before firmware start | 600 | 0 | 0 | 0 |
| Both (the packaged patch) | 3500 | 0 | 0 | 0 |
| Package `7.2-r83` image | 1500 | 0 | 0 | 0 |

The same comparison with KWin itself, on its virtual output so the panel
stays dark, a terminal repainting at uneven intervals:

| Kernel | Time | Resumes | Timed out votes |
|---|---|---|---|
| Unchanged | 180 s | 439 | 14 |
| Both changes | 240 s | 634 | 0 |
| Package `7.2-r83` image | 300 s | 783 | 0 |

`a6xx-hfi-irq-keep-polled-acks.patch` makes both changes. Nothing in it is
specific to this tablet.

What did not fix it, each tried on the way: stable commit 51fcee9d4140
(RPMh stop sequence, carried as a backport until the package moved to
7.2.8, which has it), dropping `clk_ignore_unused
pd_ignore_unused`, running `hw_init` on the timestamp path, linux-next
128a0edde507 (secondary ARC vote), and describing the GPU's memory path.
Keeping the GPU out of runtime suspend, a long autosuspend delay or a CPU
latency request of 0 each hid it by removing one of the conditions.

## Memory path

`sm8450.dtsi` gives the GPU node no `interconnects`, so nothing asks for
DDR bandwidth on its behalf. Stock votes `MASTER_GFX3D` to `SLAVE_EBI1`
per power level: each `qcom,gpu-pwrlevel` has a `qcom,bus-freq` index into
`qcom,bus-table-ddr`.

| GPU frequency (MHz) | DDR bandwidth (kBps) |
|---|---|
| 818, 791 | 13085937 |
| 734, 640 | 12484375 |
| 599, 545 | 8171875 |
| 492, 421 | 6074218 |
| 350 | 2136718 |
| 317, 285, 220 | 1761718 |

With the path and these `opp-peak-kBps` values in the X900 device tree, a
GMU resume measured by the reproducer takes about 9 to 10 ms, against 16
to 30 ms without. It had no effect on the timeouts.

## Not done

- More than one hands-on session. The fix was validated with the panel
  off, and then the owner used the Plasma desktop by touch on `7.2-r83`
  with runtime PM on auto: no GMU error and the HFI handler never ran.
- Frequency scaling under load, thermal behaviour and sustained rendering
  beyond the 74 frames per second `kmscube` run.
- A730 hardware clock gating (upstream 9d7355c6040c) and the other a6xx
  patches newer than 7.2 were looked at and not needed for this fault.
