# SM-X900 revision 5: fingerprint reader

Recorded 2026-10-05. Nothing here works under Linux; this is what the
part is and what stands between it and a driver.

## The part

Goodix GW9558, an optical sensor under the display. Stock device tree:

    gw9558 {
        compatible = "goodix,gw9558x";
        goodix,chip_id = "GW9558";
        goodix,modelinfo = "X906";
        goodix,gpio_reset = <&tlmm 88 0>;
        goodix,gpio_pwr = <&tlmm 35 0>;
        spi-max-frequency = <25000000>;
        goodix,position = "16.70,0.00,9.10,9.10,14.80,14.80,12.00,12.00,5.00";
    };

The panel nodes carry `samsung,support-optical-fingerprint`: the display
lights the finger. The tree also has a generic `qcom,qbt_handler` node
(Qualcomm's ultrasonic reader); one of its GPIOs, 42, is a camera enable
on this board, so it is a leftover.

## How stock drives it

- The `gw9558` node is a platform device directly under `/soc`, not a
  child of an SPI controller, and all 21 `qcom,spi-geni` controllers in
  the tree are disabled. The kernel side only switches power and reset
  and exposes `/dev/goodix_fp`. The SPI bus is driven from the secure
  world.
- User space: `vendor.samsung.hardware.biometrics.fingerprint@3.0-service`
  with `libbauthserver.so`, `libbauthtzcommon.so` (Samsung's interface to
  a trusted application) and `libgf_in_system_lib.so` (Goodix), plus a
  `goodixfingerprintd` service. Capture, image processing, enrolment and
  matching happen in the trusted application.
- Under Linux none of the SoC pins is left in an SPI function by the
  bootloader, so the port cannot be found from pin state.

## What a Linux driver would need

Two routes, both long:

1. **Through the trusted application.** A client for Qualcomm's secure
   world that can load and call Samsung's application, and a
   re-implementation of the proprietary protocol the three libraries
   speak to it, including whatever ties enrolment to Android's
   authentication tokens. Closed on both ends.
2. **Around it.** Take the SPI port for Linux and drive the sensor
   directly. That needs the port's serial engine and pins (not in the
   device tree; in the secure world's configuration), the secure world to
   allow a normal-world driver on that engine, Goodix's command protocol
   for this optical family (there is public reverse-engineering work for
   Goodix's laptop sensors, none found for the GW95xx phone parts), the
   display driving a bright spot under the finger, and an image pipeline
   and matcher (libfprint has generic image matching).

Next steps that cost little: pull the kernel driver for `gw9558x` from
Samsung's open-source release for this model to get the ioctl interface
and the name of the serial engine; extract the three libraries from the
vendor image for static analysis; and check whether the engine answers a
normal-world SPI controller at all. The last one decides whether route 2
exists.

## Static analysis, 2026-10-05

The service, the three libraries and the trusted application were pulled
from the stock `vendor` and `NON-HLOS` images for reading (kept locally,
not in the repo). What they show:

- **The trusted application is `securefp`.** `NON-HLOS.bin` carries it as
  a signed Qualcomm trustlet (`securefp.mdt` + `.b0x`, aarch64, ~20 MB
  loaded), alongside `authhat` (the authentication-token helper),
  `skm`/`fabrickeymaster` (keymaster) and the others. The same code is
  mirrored in the vendor image at
  `/apex/com.samsung.android.biometrics.fingerprint/etc/ta/fpta`.
- **The normal-world libraries are a thin QSEECom shim.**
  `libbauthtzcommon.so` imports `QSEECom_start_app`, `QSEECom_send_cmd`,
  `QSEECom_set_bandwidth`, `QSEECom_shutdown_app` and nothing that
  touches a bus. It opens `securefp` and relays opcodes (`BAuth_Open`,
  `BAuth_Enroll_Init/Do/Final`, `BAuth_Identify_Init/Do/Final`,
  `BAuth_GetK_From_KM`, `BAuth_Hat_OP`). Enrolment and matching return
  only a yes/no and a signed authentication token — the template and the
  image never leave the secure world.
- **The sensor is driven entirely inside the TA.** `securefp` contains a
  Goodix optical stack (strings name it
  `shenzhen_samsung_a9/fingerprint2`, with `gf_matcher.c`, `gf_algo`,
  `gf_sz_ta.c`, chip IDs `GW9558/GW9568/GW9578/GW9588`). Every SPI call
  is `sec_tzspi_open` / `sec_tzspi_full_duplex` / `sec_tzspi_close`, which
  call `tlSecSPIGetStatus` and `run_tlmm()` — a secure-world SPI and
  pinmux service inside TrustZone. The Goodix layer reads the chip ID by
  writing a 3-byte command header (`0xf0 <addr>`) and reading back over
  full-duplex; the reset and power GPIOs (88 and 35) are the only parts
  that ever surface to the HLOS kernel, which is why the mainline node is
  a bare platform device.
- **The SPI engine is a QUP on `qupv3_wrap1`.** `&tlmm` reserves pins
  36–39 (`gpio-reserved-ranges = <36 4>`), which are the `qup10` function
  (SE on `qupv3_wrap1`). Those pins carry no mainline pinmux and the
  engine is left to the secure world; a normal-world read of that SE's
  register block faults, where the neighbouring engines on the same
  wrapper read back fine. So the secure world holds the port, as route 2
  assumed.

What this settles: **route 2 (take the port for Linux) needs the secure
world to hand back the `qup10` SE, which it does not.** The realistic path
is route 1 — load and drive `securefp` from Linux. That is now concretely:
a QSEECom/`qcom_scm` client in the normal world (mainline has the SCM
calls; no `qseecomd` equivalent exists yet for pmOS), the ability to load
the signed `securefp` trustlet through PIL, and a re-implementation of the
`BAuth_*` command protocol plus the `authhat`/keymaster handshake that
signs the result. All of it is closed and tied to Samsung's trustlets, so
it stays a large, uncertain effort — but the shape is now known rather
than guessed, and the `BAuth_*` opcode surface is the thing to map next.
