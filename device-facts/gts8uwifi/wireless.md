# SM-X900 revision 5: Wi-Fi and Bluetooth evidence

Recorded 2026-10-04 on kernel `7.2-r81` sources with the root filesystem on
the microSD card. The X800 story is in
[docs/07](../../docs/07-input-and-wireless.md).

## Wi-Fi needs Samsung's firmware set

The chip identifies exactly as on the X800: `wcn6855 hw2.1`, chip 0x2,
board-id 0xff, PCI `17cb:1103` subsystem `17cb:0108`. linux-firmware's
`board-2.bin` has an entry for that identity, and with it and upstream
`WLAN.HSP.1.1-03125` the X900 associates but is not usable:

| Measure | linux-firmware set | Stock set |
|---|---|---|
| Firmware | WLAN.HSP.1.1-03125 | WLAN.HSP.2.0.c1-00441 |
| Scan, 2.4 / 5 / 6 GHz | 21-43 / 0 / 0 BSS | 33 / 43 / 8 BSS |
| Association | 2.4 GHz, 12 Mbit/s | 6 GHz, 160 MHz, HE MCS 7-10, 2 streams |
| Per-chain signal | -48 and -77 dBm | -64 and -82 dBm |
| `tx failed` | 207 of 229, 140 of 156 | 0 of 142 |
| Ping 1.1.1.1 | 0-33 % delivered | 5 of 5 |

The stock set is `/vendor/firmware/qca6490/` from the DYDC firmware
package: `amss20.bin` as `amss.bin`, `m3.bin`, `regdb.bin` and `bdwlan.elf`
as `board.bin`, with linux-firmware's four files moved aside. NetworkManager
then reconnects by itself at boot. A 100 MB download completed; its rate
(0.7 MB/s from a distant test server) says nothing about the link.

Getting the files out needs a kernel with F2FS LZ4 support. The stock vendor
image stores them compressed: the builder's kernel refuses to read them, and
`dump.f2fs` 1.16 writes files of the right size that begin with zeros. Two
tests run with such files (the stock board file alone, then the whole set)
failed with `MHI_CB_EE_RDDM` and `failed to power up mhi: -110`; they say
nothing about the real files. The files were finally copied by loop-mounting
the image on the tablet itself.

The genuine board file does not work with upstream firmware either. With
linux-firmware's `amss.bin`, `m3.bin` and `regdb.bin` (WLAN.HSP.1.1-03125),
`board-2.bin` moved aside and the stock `bdwlan.elf` (a valid ELF, SHA-256
`c5d04d22c98a...`) as `board.bin`, the firmware crashes while the board file
is downloaded:

    firmware crashed: MHI_CB_EE_RDDM
    failed to wait board file download request: -110
    qmi failed to load bdf file

So a board file alone cannot be upstreamed to make linux-firmware work
here; the board data belongs to the WLAN.HSP.2.0 firmware branch stock
uses. Putting the complete stock set back restored the 6 GHz link at once.

## Where stock gets the addresses

Neither radio has an address of its own, and the bootloader does not pass
one. Stock reads both from the `efs` partition: `init.qcom.rc` sets
`ro.bt.bdaddr_path` to `/mnt/vendor/efs/bluetooth/bt_addr`, which the
Bluetooth HAL reads, and `macloader` and Samsung's Wi-Fi HAL read
`/mnt/vendor/efs/wifi/.mac.info`. Found in the firmware package's vendor
image; the tablet's own `efs` has not been read. Under Linux `wlan0` gets a
random locally administered address on each boot and `hci0` has none.

## Rails

Three inherited regulator floors sat below what stock runs; two feed the
WCN6855. Linux programs the floor, so the radio ran at 1.808 V on the rfa
1.9 V rail and 0.5 V on the always-on rail until they were raised to the
values stock's `cnss-qca6490` requests (1.9 V and 1.012 V). Stock also holds
PMR735A L7 at 2.8 V as `wlan-ant-switch` and `bt-vdd-asd`; it is now held on.
Neither change altered the linux-firmware results above, and the stock set
has only been run with both in place.

## Not done

- Bluetooth: `hci0` loads its firmware but has no address, as on the X800
  before its address helper. Stock ships `hpnv21.bin` and `hpnv21g.bin`,
  which were copied out but not tried.
- A stable Wi-Fi address; see the section above.
- Throughput against a local server, roaming, 5 GHz association, suspend.
- The X900 package does not carry or fetch the stock Wi-Fi files.
- The default regulatory domain leaves all 28 5 GHz channels listen-only.
