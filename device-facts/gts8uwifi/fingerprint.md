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
