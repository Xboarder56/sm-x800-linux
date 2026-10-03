/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Samsung Galaxy Tab S8 Ultra Wi-Fi (SM-X900), codename "gts8uwifi".
 * SM8450 (Waipio). Derived from the proven gts8pwifi uniLoader board.
 *
 * The Samsung bootloader leaves the panel scanning the cont_splash
 * framebuffer, so simplefb here gives uniLoader (and then the kernel)
 * a visible console on the panel.
 *
 * Geometry comes from the X900 DYDC rev-5 stock DTB:
 *   splash reserved-memory = <0x0 0xb8000000 0x0 0x2b00000> (43 MiB)
 *
 * Scanout is LANDSCAPE 2960x1848. The stock DTB's physical panel size is
 * 313 mm x 196 mm (qcom,mdss-pan-physical-{width,height}-dimension =
 * 0x139/0xc4), ratio about 1.60 == 2960/1848, so the long axis is the scanline.
 * Do NOT use the touch controller's portrait coordinates (1848x2960) —
 * that is the touchscreen's coordinate space, not the display scanout.
 * Getting this backwards renders correctly-sized but diagonally sheared text
 * (each row offset by 2960-1848 px), as in the original X800 investigation.
 * Readable uniLoader/Linux text is observed on X900 in R2–R7; native panel
 * takeover is separate. See device-facts/gts8uwifi/display.md for derivation.
 */

#include <board.h>
#include <util.h>
#include <drivers/framework.h>
#include <lib/simplefb.h>

static struct video_info gts8uwifi_fb = {
	.format = FB_FORMAT_ARGB8888,
	.width = 2960,
	.height = 1848,
	.stride = 4,
	.address = (void *)0xb8000000
};

static const struct device gts8uwifi_devices[] = {
	{ "simplefb", &gts8uwifi_fb, "fb" },
};

struct board_data board_ops = {
	.name = "samsung-gts8uwifi",
	.ops = {
	},
	.devices = gts8uwifi_devices,
	.num_devices = ARRAY_SIZE(gts8uwifi_devices),
	.quirks = 0
};
