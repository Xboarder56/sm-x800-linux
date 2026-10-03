# SM-X900 Download Mode reboot

Validated on the 12 GiB SM-X900, board revision 5, with X900XXU9DYDC ABL.
Kernel `7.2-r49` in the R13b BOOT-only control reaches Samsung Download Mode
through `RESTART2("download")`. The user confirmed the screen and native
Heimdall detected the device without a manual key sequence.

## Restart-reason path

The previous X900 DTS inherited X800's `mode-download = <0x15>` on
`&pmk8350_pon`. The qcom-pon driver bound and advertised `download`, but the
reboot returned to Linux. Advertising a mode only confirms registration;
it does not establish that Samsung's bootloader consumes that register.

The merged DYDC stock tree's `samsung,qcom-qcom_reboot_reason` node selects
`restart_reason` in PMK8350 SDAM2: base `0x7100`, byte offset `0x48`, bits
`<1 7>`. The pinned Linux 7.2 `pmk8350.dtsi` already describes this cell and
its `/reboot-mode` consumer. X900 now adds `mode-download = <0x15>` there.
NVMEM applies the cell's bit shift; no userspace register write is needed.

Samsung's SM8450 downstream
[command handler](https://github.com/samsung-sm8450-dev/android_kernel_samsung_sm8450/blob/lineage-22.2/drivers/samsung/debug/qcom/reboot_cmd/sec_qc_rbcmd_command.c)
maps `download` to that reason, and its
[restart-reason driver](https://github.com/samsung-sm8450-dev/android_kernel_samsung_sm8450/blob/lineage-22.2/drivers/samsung/debug/qcom/reboot_reason/sec_qc_qcom_reboot_reason.c)
writes the `restart_reason` NVMEM cell. These sources corroborate the stock
DT path; they are not a source release matched to this tablet's DYDC kernel.

## Kernel and runtime checks

`CONFIG_NVMEM_SPMI_SDAM=y` and `CONFIG_NVMEM_REBOOT_MODE=y` make the path
available in the minimal ramdisk without loading modules. The running kernel
exposes ten SDAM providers and advertises `recovery bootloader download` under
`/sys/class/reboot-mode/nvmem-reboot-mode/reboot_modes`. A static helper uploaded
to `/run` invokes the RESTART2 syscall with `download`; BusyBox's reboot applet
does not pass this argument. Runtime and reboot transcripts are under
`root-build/gts8uwifi-debug-r13b-sdam-control/`.

X800's DTS and qcom-pon download setting are unchanged. Its inherited NVMEM
consumer has no `download` mode, and Linux's reboot-mode notifier skips writes
when no nonzero matching reason exists. The shared built-in driver change
still needs X800 hardware regression testing; other restart targets and other
X900 firmware have not been tested.
