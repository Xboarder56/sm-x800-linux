// SPDX-License-Identifier: GPL-2.0-only
/*
 * Samsung S6TUUM1 AMSA24VU01 WQXGA AMOLED panel (Galaxy Tab S8+, SM-X800).
 * Samsung S6TUUM1 AMSA46AS01 WQXGA AMOLED panel (Galaxy Tab S8 Ultra, SM-X900).
 *
 * AMSA24VU01 (original Galaxy Tab S8+ path):
 * 2800x1752 landscape raster, DSI command mode, 4 lanes, DSC 1.1
 * (8 bpp, two 1400x12 slices per line). Init sequence, DSC parameters and
 * power/reset facts extracted from the stock DTB's ss_dsi_panel node and
 * the downstream techpack driver — see device-facts/display-s6tuum1.md
 * for the full derivation.
 *
 * Modeled on panel-samsung-s6e3ha8.c (same tree). The PPS is replayed
 * verbatim as a DCS write to 0x9E — this DDIC ignores the standard MIPI
 * PPS packet type (see the comment at the write); the DPU side's
 * drm_dsc_config matches the replayed bytes.
 *
 * Only the 120 Hz timing is implemented (DDIC reg 0x60 = 0x20; stock also
 * has a 60 Hz variant with 0x60 = 0x00 for VRR — later work).
 *
 * AMSA46AS01 adds the Galaxy Tab S8 Ultra's 2960x1848 landscape raster,
 * DSC 1.1 at 8 bpp with two 1480x132 slices per line, and its distinct
 * power/reset and command sequence. See device-facts/gts8uwifi/display.md
 * for the stock CYB1/DYDC derivation. The X900 path runs at 120 Hz; the
 * existing AMSA24VU01 sequence and timing are retained separately.
 */

#include <linux/backlight.h>
#include <linux/delay.h>
#include <linux/gpio/consumer.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/regulator/consumer.h>
#include <linux/property.h>
#include <linux/workqueue.h>

#include <drm/display/drm_dsc.h>
#include <drm/display/drm_dsc_helper.h>
#include <drm/drm_mipi_dsi.h>
#include <drm/drm_probe_helper.h>
#include <drm/drm_panel.h>

#include <video/mipi_display.h>

struct s6tuum1;

struct s6tuum1_panel_desc {
	const struct drm_display_mode *mode;
	void (*reset)(struct s6tuum1 *priv);
	int (*on)(struct s6tuum1 *priv);
	int (*enable)(struct s6tuum1 *priv);
	int (*set_refresh)(struct s6tuum1 *priv);
	unsigned int slice_width;
	unsigned int slice_height;
	unsigned int default_brightness;
	unsigned int max_brightness;
	/*
	 * Stock samsung,delayed-display-on: display-on follows the first
	 * frame, so the panel never scans out its post-reset frame memory.
	 * Zero sends display-on directly from the enable callback.
	 */
	unsigned int display_on_delay_ms;
	/*
	 * Stock always-on-touch policy: display-off only sends display-off
	 * and sleep-in. The panel supply stays on and reset is never asserted
	 * while the TCON reports ready, including at the bootloader handoff.
	 */
	bool keep_power;
};

struct s6tuum1 {
	struct drm_panel panel;
	struct mipi_dsi_device *dsi;
	struct drm_dsc_config dsc;
	struct gpio_desc *reset_gpio;
	struct gpio_desc *tcon_rdy_gpio;
	struct regulator *vdd;
	const struct s6tuum1_panel_desc *desc;
	struct delayed_work display_on_work;
	bool powered;
	/* The bootloader's panel state has not been replaced yet. */
	bool boot_on;
	/* The running bootloader state was adopted without a reset. */
	bool adopted;
};

static inline struct s6tuum1 *to_s6tuum1(struct drm_panel *panel)
{
	return container_of(panel, struct s6tuum1, panel);
}

static void s6tuum1_amsa24_reset(struct s6tuum1 *priv)
{
	gpiod_set_value_cansleep(priv->reset_gpio, 1);
	usleep_range(5000, 6000);
	gpiod_set_value_cansleep(priv->reset_gpio, 0);
	usleep_range(5000, 6000);
	gpiod_set_value_cansleep(priv->reset_gpio, 1);
	usleep_range(10000, 11000);
}

/* X900 stock qcom,mdss-dsi-reset-sequence = <0 2 1 1>. */
static void s6tuum1_amsa46_reset(struct s6tuum1 *priv)
{
	gpiod_set_value_cansleep(priv->reset_gpio, 0);
	usleep_range(2000, 3000);
	gpiod_set_value_cansleep(priv->reset_gpio, 1);
	usleep_range(1000, 2000);
}

/*
 * This DDIC is an Anapass TCON (stock: samsung,anapass-power-seq). It
 * BOOTS after reset — on the order of 200 ms — and signals readiness on
 * a dedicated pin (stock: samsung,tcon-rdy-gpio, tlmm 1). Commands sent
 * before then land in a booting TCON and are silently lost, which is
 * exactly what r36 looked like: sleep-out/PPS/init all void, panel dark,
 * no DSI errors. Downstream (wait_tcon_ready) sleeps a flat 200 ms and
 * then polls up to 300 ms more; mirror that.
 */
static void s6tuum1_wait_tcon_ready(struct s6tuum1 *priv)
{
	struct device *dev = &priv->dsi->dev;
	int i;

	if (!priv->tcon_rdy_gpio) {
		/* downstream fallback: flat 60 ms */
		usleep_range(60000, 61000);
		return;
	}

	msleep(200);
	for (i = 0; i < 300; i++) {
		if (gpiod_get_value_cansleep(priv->tcon_rdy_gpio))
			break;
		usleep_range(1000, 1100);
	}

	dev_info(dev, "tcon_rdy=%d after %d ms\n",
		 gpiod_get_value_cansleep(priv->tcon_rdy_gpio), 200 + i);
}

/*
 * Stock qcom,mdss-dsi-on-command, in order. Register meanings are the
 * DDIC's own; the visible landmarks are 0x60 = refresh rate select and
 * the 0xB0 global-parameter pointer writes.
 */
static int s6tuum1_amsa24_on(struct s6tuum1 *priv)
{
	struct mipi_dsi_multi_context ctx = { .dsi = priv->dsi };

	/*
	 * Commands go in HS mode: stock sets on/off-command-state =
	 * "dsi_hs_mode" and samsung,mdss-dsi-sot-hs-mode. Do NOT set
	 * MIPI_DSI_MODE_LPM here — with LP commands (r30..r32) the short
	 * writes landed (panel emitted TE briefly) but init never fully took
	 * and TE died before the first frame.
	 */
	mipi_dsi_dcs_exit_sleep_mode_multi(&ctx);
	mipi_dsi_msleep(&ctx, 120);

	mipi_dsi_dcs_write_seq_multi(&ctx, 0xd3, 0x4d);
	mipi_dsi_dcs_write_seq_multi(&ctx, 0x98, 0x00);
	mipi_dsi_dcs_write_seq_multi(&ctx, 0x60, 0x20);	/* 120 Hz */
	mipi_dsi_msleep(&ctx, 50);
	mipi_dsi_dcs_write_seq_multi(&ctx, 0xb0, 0x00, 0x08, 0x78);
	mipi_dsi_dcs_write_seq_multi(&ctx, 0x78, 0x30);
	mipi_dsi_dcs_write_seq_multi(&ctx, 0xb0, 0x00, 0x39, 0x78);
	mipi_dsi_dcs_write_seq_multi(&ctx, 0x78, 0x3c);
	mipi_dsi_dcs_write_seq_multi(&ctx, 0xb0, 0x00, 0x3e, 0x78);
	mipi_dsi_dcs_write_seq_multi(&ctx, 0x78, 0x3c);

	mipi_dsi_compression_mode_multi(&ctx, true);

	/*
	 * PPS delivery: this DDIC takes the PPS as a DCS long write to
	 * register 0x9E (stock: "39 ... 59 9e 11 01 00 89 ..."), NOT as the
	 * standard MIPI PPS packet type — sent that way (r30/r31), the panel
	 * emitted a few TEs and then dropped TE the moment compressed frames
	 * arrived, i.e. it never had a PPS. Bytes below are the stock PPS
	 * verbatim; its RC parameters decode to the same standard pre-SCR
	 * table the msm DSI host computes for the DPU side, so both ends of
	 * the link agree.
	 */
	mipi_dsi_dcs_write_seq_multi(&ctx, 0x9e,
		0x11, 0x01, 0x00, 0x89, 0x30, 0x80, 0x06, 0xd8, 0x0a, 0xf0,
		0x00, 0x0c, 0x05, 0x78, 0x05, 0x78, 0x02, 0x00, 0x03, 0xbd,
		0x00, 0x20, 0x01, 0x9c, 0x00, 0x13, 0x00, 0x0c, 0x08, 0xbb,
		0x03, 0x45, 0x18, 0x00, 0x10, 0xf0, 0x03, 0x0c, 0x20, 0x00,
		0x06, 0x0b, 0x0b, 0x33, 0x0e, 0x1c, 0x2a, 0x38, 0x46, 0x54,
		0x62, 0x69, 0x70, 0x77, 0x79, 0x7b, 0x7d, 0x7e, 0x01, 0x02,
		0x01, 0x00, 0x09, 0x40, 0x09, 0xbe, 0x19, 0xfc, 0x19, 0xfa,
		0x19, 0xf8, 0x1a, 0x38, 0x1a, 0x78, 0x1a, 0xb6, 0x2a, 0xf6,
		0x2b, 0x34, 0x2b, 0x74, 0x3b, 0x74, 0x63, 0xf4);

	mipi_dsi_dcs_write_seq_multi(&ctx, 0x9a, 0x00);
	mipi_dsi_dcs_write_seq_multi(&ctx, 0x79, 0x02);
	mipi_dsi_dcs_write_seq_multi(&ctx, 0x86, 0x0a, 0x6b);
	mipi_dsi_dcs_write_seq_multi(&ctx, 0xb0, 0x00, 0x08, 0x5d);
	mipi_dsi_dcs_write_seq_multi(&ctx, 0x5d, 0x00);

	/* TE on, dimming control (stock gamma_mode2 companion write) */
	mipi_dsi_dcs_set_tear_on_multi(&ctx, MIPI_DSI_DCS_TEAR_MODE_VBLANK);
	mipi_dsi_dcs_write_seq_multi(&ctx, 0x53, 0x20);

	return ctx.accum_err;
}

/*
 * AMSA46AS01 stock qcom,mdss-dsi-on-command. The 88-byte PPS is
 * copied verbatim from the X900 rev-5 stock DTB (CYB1 and DYDC match).
 * See device-facts/gts8uwifi/display.md for provenance. Samsung sends compression
 * mode before the PPS. The stock 60 Hz and 120 Hz streams differ only in
 * the refresh select, 0x60 = 0x00 or 0x20, with a 50 ms post-write delay.
 */
static int s6tuum1_amsa46_on(struct s6tuum1 *priv)
{
	struct mipi_dsi_multi_context ctx = { .dsi = priv->dsi };

	mipi_dsi_dcs_exit_sleep_mode_multi(&ctx);
	mipi_dsi_msleep(&ctx, 120);

	mipi_dsi_dcs_write_seq_multi(&ctx, 0xd3, 0x4f);
	mipi_dsi_dcs_write_seq_multi(&ctx, 0x98, 0x00);

	mipi_dsi_compression_mode_multi(&ctx, true);

	mipi_dsi_dcs_write_seq_multi(&ctx, 0x9e,
		0x11, 0x01, 0x00, 0x89, 0x30, 0x80, 0x07, 0x38, 0x0b, 0x90,
		0x00, 0x84, 0x05, 0xc8, 0x05, 0xc8, 0x02, 0x00, 0x03, 0xe5,
		0x00, 0x20, 0x13, 0x0f, 0x00, 0x14, 0x00, 0x0c, 0x00, 0xbc,
		0x00, 0x48, 0x18, 0x00, 0x10, 0xf0, 0x03, 0x0c, 0x20, 0x00,
		0x06, 0x0b, 0x0b, 0x33, 0x0e, 0x1c, 0x2a, 0x38, 0x46, 0x54,
		0x62, 0x69, 0x70, 0x77, 0x79, 0x7b, 0x7d, 0x7e, 0x01, 0x02,
		0x01, 0x00, 0x09, 0x40, 0x09, 0xbe, 0x19, 0xfc, 0x19, 0xfa,
		0x19, 0xf8, 0x1a, 0x38, 0x1a, 0x78, 0x1a, 0xb6, 0x2a, 0xf6,
		0x2b, 0x34, 0x2b, 0x74, 0x3b, 0x74, 0x6b, 0xf4);

	mipi_dsi_dcs_write_seq_multi(&ctx, 0x79, 0x02);
	mipi_dsi_dcs_write_seq_multi(&ctx, 0xb0, 0x00, 0x03, 0x68);
	mipi_dsi_dcs_write_seq_multi(&ctx, 0x68, 0x14);
	mipi_dsi_dcs_write_seq_multi(&ctx, 0x51, 0xff, 0x07);
	mipi_dsi_dcs_write_seq_multi(&ctx, 0x53, 0x20);
	if (drm_mode_vrefresh(priv->desc->mode) == 120)
		mipi_dsi_dcs_write_seq_multi(&ctx, 0x60, 0x20);
	else
		mipi_dsi_dcs_write_seq_multi(&ctx, 0x60, 0x00);
	mipi_dsi_msleep(&ctx, 50);
	mipi_dsi_dcs_write_seq_multi(&ctx, 0x86, 0x00, 0x03);
	mipi_dsi_dcs_write_seq_multi(&ctx, 0x68, 0x19);
	mipi_dsi_dcs_write_seq_multi(&ctx, 0xb0, 0x00, 0xc3, 0xb3);
	mipi_dsi_dcs_write_seq_multi(&ctx, 0xb3, 0x0d);

	/*
	 * This TCON takes tear-on without a parameter. The standard two-byte
	 * form switched TE off altogether, leaving the DPU on its free-running
	 * vsync fallback at half the panel rate. Stock sends no tear-on here;
	 * the parameterless form restores the 230 us pulse per 8.3 ms frame.
	 */
	mipi_dsi_dcs_write_seq_multi(&ctx, MIPI_DCS_SET_TEAR_ON);

	return ctx.accum_err;
}

static bool s6tuum1_tcon_ready(struct s6tuum1 *priv)
{
	return priv->tcon_rdy_gpio &&
	       gpiod_get_value_cansleep(priv->tcon_rdy_gpio);
}

static int s6tuum1_power_off(struct s6tuum1 *priv)
{
	gpiod_set_value_cansleep(priv->reset_gpio, 0);
	/* stock supply entry: 15 ms pre-off */
	usleep_range(15000, 16000);
	priv->powered = false;
	return regulator_disable(priv->vdd);
}

/*
 * Historical X800 bring-up note, retained for the takeover investigation.
 * The current prepare path cold-initializes the AMSA24VU01; a keep-power
 * panel is adopted from the bootloader instead, as described in prepare.
 *
 * TAKEOVER EXPERIMENT (r34): across r30-r33 the panel emitted exactly 7 TE
 * pulses and then went permanently silent, regardless of init variations
 * (PPS delivery, LP vs HS commands). Best reading: those pulses are the
 * BOOTLOADER's still-running display, killed by our reset pulse — and our
 * re-init never revives the panel. This build does not touch the panel at
 * all: no reset, no init commands. ABL left it initialized, scanning and
 * DSC-configured (same PPS); if frames display, the entire DPU/DSI/DSC
 * pipeline is proven and only the cold-init path is at fault.
 */
static int s6tuum1_prepare(struct drm_panel *panel)
{
	struct s6tuum1 *priv = to_s6tuum1(panel);
	int ret;

	if (!priv->powered) {
		ret = regulator_enable(priv->vdd);
		if (ret < 0)
			return ret;
		priv->powered = true;

		/* stock supply entry: 11 ms post-on */
		usleep_range(11000, 12000);
	}

	priv->adopted = false;
	if (priv->desc->keep_power && s6tuum1_tcon_ready(priv)) {
		/*
		 * Stock tcon_prepare() skips the reset while tcon_rdy is high
		 * and adopts the bootloader's panel untouched. A warm reset
		 * here flashed the panel and intermittently left the TCON
		 * dropping its ready line within a second of the init
		 * sequence.
		 */
		if (priv->boot_on) {
			priv->boot_on = false;
			priv->adopted = true;
			return 0;
		}
	} else {
		priv->desc->reset(priv);
		s6tuum1_wait_tcon_ready(priv);
	}
	priv->boot_on = false;

	ret = priv->desc->on(priv);
	if (ret < 0) {
		if (!priv->desc->keep_power)
			s6tuum1_power_off(priv);
		return ret;
	}

	return 0;
}

static int s6tuum1_amsa24_enable(struct s6tuum1 *priv)
{
	struct mipi_dsi_multi_context ctx = { .dsi = priv->dsi };

	mipi_dsi_dcs_set_display_on_multi(&ctx);
	mipi_dsi_msleep(&ctx, 17);	/* stock display_on wait */

	return ctx.accum_err;
}

static int s6tuum1_amsa46_enable(struct s6tuum1 *priv)
{
	struct mipi_dsi_multi_context ctx = { .dsi = priv->dsi };

	/* X900 stock samsung,first_display_on_tx_cmds_revA, before 0x29. */
	mipi_dsi_dcs_write_seq_multi(&ctx, 0xf8, 0x58, 0x00, 0xd0, 0x1d);
	mipi_dsi_dcs_write_seq_multi(&ctx, 0xf9, 0x00, 0x00, 0x00, 0x00);
	mipi_dsi_dcs_set_display_on_multi(&ctx);
	mipi_dsi_msleep(&ctx, 17);	/* stock display_on wait */

	return ctx.accum_err;
}

/* Stock samsung,vrr_tx_cmds: refresh select on an already running panel. */
static int s6tuum1_amsa46_set_refresh(struct s6tuum1 *priv)
{
	struct mipi_dsi_multi_context ctx = { .dsi = priv->dsi };

	if (drm_mode_vrefresh(priv->desc->mode) == 120)
		mipi_dsi_dcs_write_seq_multi(&ctx, 0x60, 0x20);
	else
		mipi_dsi_dcs_write_seq_multi(&ctx, 0x60, 0x00);

	return ctx.accum_err;
}

static void s6tuum1_display_on_work(struct work_struct *work)
{
	struct s6tuum1 *priv = container_of(to_delayed_work(work),
					    struct s6tuum1, display_on_work);
	int ret;

	ret = priv->desc->enable(priv);
	if (ret < 0)
		dev_err(&priv->dsi->dev, "display-on failed: %d\n", ret);
}

static int s6tuum1_enable(struct drm_panel *panel)
{
	struct s6tuum1 *priv = to_s6tuum1(panel);

	/* An adopted panel is already lit; only select the refresh rate. */
	if (priv->adopted)
		return priv->desc->set_refresh(priv);

	if (!priv->desc->display_on_delay_ms)
		return priv->desc->enable(priv);

	/*
	 * The first frame is kicked off after this callback returns and is
	 * transferred on the next TE. Light the panel once it has landed.
	 */
	schedule_delayed_work(&priv->display_on_work,
			      msecs_to_jiffies(priv->desc->display_on_delay_ms));

	return 0;
}

static int s6tuum1_disable(struct drm_panel *panel)
{
	struct s6tuum1 *priv = to_s6tuum1(panel);
	struct mipi_dsi_multi_context ctx = { .dsi = priv->dsi };

	cancel_delayed_work_sync(&priv->display_on_work);

	mipi_dsi_dcs_set_display_off_multi(&ctx);
	mipi_dsi_dcs_enter_sleep_mode_multi(&ctx);
	mipi_dsi_msleep(&ctx, 100);	/* stock display_off wait */

	return ctx.accum_err;
}

static int s6tuum1_unprepare(struct drm_panel *panel)
{
	struct s6tuum1 *priv = to_s6tuum1(panel);

	/*
	 * Cutting only the panel supply left this panel driving a bright
	 * white field; stock leaves it powered in sleep-in.
	 */
	if (priv->desc->keep_power)
		return 0;

	return s6tuum1_power_off(priv);
}

/* Stock 120 Hz timing: porches h 64/48/64 (fp/bp/pw), v 48/48/64 */
static const struct drm_display_mode s6tuum1_amsa24_mode = {
	.clock = (2800 + 64 + 64 + 48) * (1752 + 48 + 64 + 48) * 120 / 1000,
	.hdisplay = 2800,
	.hsync_start = 2800 + 64,
	.hsync_end = 2800 + 64 + 64,
	.htotal = 2800 + 64 + 64 + 48,
	.vdisplay = 1752,
	.vsync_start = 1752 + 48,
	.vsync_end = 1752 + 48 + 64,
	.vtotal = 1752 + 48 + 64 + 48,
	.width_mm = 267,
	.height_mm = 167,
	.type = DRM_MODE_TYPE_DRIVER | DRM_MODE_TYPE_PREFERRED,
};

/*
 * AMSA46AS01 120 Hz. This is a command-mode panel: the blanking below is
 * never scanned out, it only sets the link rate the DSI host derives from
 * the mode. Stock describes both rates with 200/200/200 porches (v front
 * porch 192 at 120 Hz) plus a separate 1530 Mbit/s lane rate and 7533 us
 * transfer time; taken as video blanking those porches give a 1042 MHz
 * mode at 120 Hz, which the DPU rejects against its 500 MHz core clock
 * limit.
 *
 * Choose the blanking for the stock lane rate instead. DSC at 8 bpp
 * carries 987 compressed pixels per line, so the host computes
 * (987 + 138) * 1888 * 120 * 24 / 4 = 1529 Mbit/s per lane, the same
 * derivation that yields 1528 Mbit/s from the AMSA24VU01 stock porches.
 */
static const struct drm_display_mode s6tuum1_amsa46_mode = {
	.clock = (2960 + 48 + 32 + 58) * (1848 + 16 + 8 + 16) * 120 / 1000,
	.hdisplay = 2960,
	.hsync_start = 2960 + 48,
	.hsync_end = 2960 + 48 + 32,
	.htotal = 2960 + 48 + 32 + 58,
	.vdisplay = 1848,
	.vsync_start = 1848 + 16,
	.vsync_end = 1848 + 16 + 8,
	.vtotal = 1848 + 16 + 8 + 16,
	.width_mm = 313,
	.height_mm = 196,
	.type = DRM_MODE_TYPE_DRIVER | DRM_MODE_TYPE_PREFERRED,
};

static const struct s6tuum1_panel_desc s6tuum1_amsa24_desc = {
	.mode = &s6tuum1_amsa24_mode,
	.reset = s6tuum1_amsa24_reset,
	.on = s6tuum1_amsa24_on,
	.enable = s6tuum1_amsa24_enable,
	.slice_width = 1400,
	.slice_height = 12,
	/*
	 * DBV is 11 bits on this DDIC: downstream fills 0x51 with
	 * DBV[7:0] + DBV[10:8] and the candela table tops out at
	 * 0x7ff (420 nits). Values above 2047 wrap — 2048 reads
	 * back as DBV 0, i.e. a black screen.
	 */
	.default_brightness = 0x5d8,
	.max_brightness = 0x7ff,
};

static const struct s6tuum1_panel_desc s6tuum1_amsa46_desc = {
	.mode = &s6tuum1_amsa46_mode,
	.reset = s6tuum1_amsa46_reset,
	.on = s6tuum1_amsa46_on,
	.enable = s6tuum1_amsa46_enable,
	.set_refresh = s6tuum1_amsa46_set_refresh,
	.slice_width = 1480,
	.slice_height = 132,
	.default_brightness = 0x5d8,
	.max_brightness = 0x7ff,
	/* The TE wait plus one frame transfer, with margin: six 8.3 ms frames. */
	.display_on_delay_ms = 50,
	.keep_power = true,
};

static int s6tuum1_get_modes(struct drm_panel *panel,
			     struct drm_connector *connector)
{
	struct s6tuum1 *priv = to_s6tuum1(panel);

	return drm_connector_helper_get_modes_fixed(connector, priv->desc->mode);
}

static const struct drm_panel_funcs s6tuum1_panel_funcs = {
	.prepare = s6tuum1_prepare,
	.enable = s6tuum1_enable,
	.disable = s6tuum1_disable,
	.unprepare = s6tuum1_unprepare,
	.get_modes = s6tuum1_get_modes,
};

static int s6tuum1_bl_update_status(struct backlight_device *bl)
{
	struct mipi_dsi_device *dsi = bl_get_data(bl);

	/*
	 * LSB first: stock gamma_mode2 sends "51 d8 0d" for 0x0dd8, i.e.
	 * the DCS-standard little-endian order, not the _large variant.
	 */
	return mipi_dsi_dcs_set_display_brightness(dsi,
					backlight_get_brightness(bl));
}

static const struct backlight_ops s6tuum1_bl_ops = {
	.update_status = s6tuum1_bl_update_status,
};

static struct backlight_device *
s6tuum1_create_backlight(struct s6tuum1 *priv)
{
	struct mipi_dsi_device *dsi = priv->dsi;
	struct device *dev = &dsi->dev;
	const struct backlight_properties props = {
		.type = BACKLIGHT_RAW,
		.brightness = priv->desc->default_brightness,
		.max_brightness = priv->desc->max_brightness,
	};

	return devm_backlight_device_register(dev, dev_name(dev), dev, dsi,
					      &s6tuum1_bl_ops, &props);
}

static int s6tuum1_probe(struct mipi_dsi_device *dsi)
{
	struct device *dev = &dsi->dev;
	struct s6tuum1 *priv;
	int ret;

	priv = devm_drm_panel_alloc(dev, struct s6tuum1, panel,
				    &s6tuum1_panel_funcs,
				    DRM_MODE_CONNECTOR_DSI);
	if (IS_ERR(priv))
		return PTR_ERR(priv);

	priv->desc = device_get_match_data(dev);
	if (!priv->desc)
		return dev_err_probe(dev, -ENODEV, "missing panel descriptor\n");

	/* The bootloader leaves a keep-power panel running at handoff. */
	priv->boot_on = priv->desc->keep_power;
	INIT_DELAYED_WORK(&priv->display_on_work, s6tuum1_display_on_work);

	priv->vdd = devm_regulator_get(dev, "vdd");
	if (IS_ERR(priv->vdd))
		return dev_err_probe(dev, PTR_ERR(priv->vdd),
				     "failed to get vdd\n");

	priv->reset_gpio = devm_gpiod_get(dev, "reset", GPIOD_OUT_HIGH);
	if (IS_ERR(priv->reset_gpio))
		return dev_err_probe(dev, PTR_ERR(priv->reset_gpio),
				     "failed to get reset gpio\n");

	priv->tcon_rdy_gpio = devm_gpiod_get_optional(dev, "tcon-rdy",
						      GPIOD_IN);
	if (IS_ERR(priv->tcon_rdy_gpio))
		return dev_err_probe(dev, PTR_ERR(priv->tcon_rdy_gpio),
				     "failed to get tcon-rdy gpio\n");

	priv->dsi = dsi;
	mipi_dsi_set_drvdata(dsi, priv);

	dsi->lanes = 4;
	dsi->format = MIPI_DSI_FMT_RGB888;
	dsi->mode_flags = MIPI_DSI_CLOCK_NON_CONTINUOUS;

	priv->panel.prepare_prev_first = true;

	priv->panel.backlight = s6tuum1_create_backlight(priv);
	if (IS_ERR(priv->panel.backlight))
		return dev_err_probe(dev, PTR_ERR(priv->panel.backlight),
				     "failed to create backlight\n");

	drm_panel_add(&priv->panel);

	/* DSC 1.1, decoded from the stock PPS (see device-facts) */
	dsi->dsc = &priv->dsc;
	priv->dsc.dsc_version_major = 1;
	priv->dsc.dsc_version_minor = 1;
	priv->dsc.slice_height = priv->desc->slice_height;
	priv->dsc.slice_width = priv->desc->slice_width;
	priv->dsc.slice_count = priv->desc->mode->hdisplay / priv->dsc.slice_width;
	priv->dsc.bits_per_component = 8;
	priv->dsc.bits_per_pixel = 8 << 4;	/* 4 fractional bits */
	priv->dsc.block_pred_enable = true;

	ret = mipi_dsi_attach(dsi);
	if (ret < 0) {
		drm_panel_remove(&priv->panel);
		return dev_err_probe(dev, ret, "failed to attach to DSI host\n");
	}

	return 0;
}

static void s6tuum1_remove(struct mipi_dsi_device *dsi)
{
	struct s6tuum1 *priv = mipi_dsi_get_drvdata(dsi);

	mipi_dsi_detach(dsi);
	drm_panel_remove(&priv->panel);
	cancel_delayed_work_sync(&priv->display_on_work);
}

static const struct of_device_id s6tuum1_of_match[] = {
	{
		.compatible = "samsung,s6tuum1-amsa24vu01",
		.data = &s6tuum1_amsa24_desc,
	},
	{
		.compatible = "samsung,s6tuum1-amsa46as01",
		.data = &s6tuum1_amsa46_desc,
	},
	{ }
};
MODULE_DEVICE_TABLE(of, s6tuum1_of_match);

static struct mipi_dsi_driver s6tuum1_driver = {
	.probe = s6tuum1_probe,
	.remove = s6tuum1_remove,
	.driver = {
		.name = "panel-samsung-s6tuum1",
		.of_match_table = s6tuum1_of_match,
	},
};
module_mipi_dsi_driver(s6tuum1_driver);

MODULE_DESCRIPTION("Samsung S6TUUM1 WQXGA AMOLED panel driver");
MODULE_LICENSE("GPL");
