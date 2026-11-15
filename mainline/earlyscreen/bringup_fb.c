/* Earliest possible on-panel progress reporting for the SM-T360 bring-up.
 *
 * Why this exists: mainline hangs before drm/simpledrm probes, so neither fbcon
 * nor the cache-partition report can show where it died. This file is compiled
 * into the kernel and paints markers directly into the buffer aboot already
 * left on the panel (800x1280x32bpp at 0x03200000), which the display
 * controller keeps scanning out. Each marker is a coloured bar, so "how many
 * bars are visible" is how far boot got - no font, console, driver or working
 * UART needed.
 *
 * Called from init/main.c and kernel/panic.c (see earlyscreen/apply.py in the
 * port repo). Never touches memory outside aboot's own splash region.
 */
#include <linux/kernel.h>
#include <linux/types.h>
#include <linux/io.h>

/* Where the log has to live.
 *
 * The vendor kernel refuses to open /dev/mem (ENXIO - raw RAM is blocked on
 * this device), so a plain RAM address is unreadable on the next boot no matter
 * what survived in it. /dev/fb0, however, opens fine and maps aboot's splash
 * reservation at 0x03200000 (2 x 800x1280x4 = 0x7d0000 bytes). So the log is
 * written into the first 4 KiB of the SECOND frame - a strip the bars never
 * touch - and read back through the framebuffer on the next boot.
 */
#define BRL_PHYS  0x035e8000UL	/* 0x03200000 + one 800x1280x4 frame */
#define FB_PHYS   0x03200000UL
#define FB_W      800
#define FB_STRIDE 3200
#define BAR_W     52
#define BAR_H     60
#define BAR_Y     200

void brfb(int n);
void brfb_panic(void);
void brlog_panic(const char *msg);

/* A hang on this tablet is invisible: aboot hands over with the panel dark, so
 * neither fbcon nor the markers above can be assumed readable. Samsung's own
 * design solves this with a log in RAM that outlives a reset (their sec_log at
 * 0x3fe00008); this is the same trick in a region nothing else uses. The next
 * boot - any kernel - can read it, and this port's initramfs dumps it.
 */
static void brl_slot(int slot, const char *text)
{
	u8 *p = (u8 *)__va(BRL_PHYS);
	u8 *hdr = p;
	int i;

	hdr[0] = 'B';
	hdr[1] = 'R';
	hdr[2] = 'U';
	hdr[3] = 'P';
	hdr[4] = '1';
	hdr[5] = 0;

	p += 64 + slot * 64;
	for (i = 0; i < 63 && text[i]; i++)
		p[i] = (u8)text[i];
	p[i] = 0;
}

#define FRAME_BYTES (FB_W * 1280 * 4)	/* one 800x1280 frame, 0x3e8000 */

static void fill_frame(int frame, int x0, int y0, int w, int h, u32 colour)
{
	/* resolved at call time: __va() is not a constant initializer here */
	u32 *fb = (u32 *)((u8 *)__va(FB_PHYS) + (unsigned long)frame * FRAME_BYTES);
	int x, y;

	for (y = y0; y < y0 + h && y < 1280; y++) {
		u32 *row;

		if (y < 0)
			continue;
		row = fb + y * (FB_STRIDE / 4) + x0;
		for (x = 0; x < w && x0 + x < FB_W; x++)
			row[x] = colour;
	}
}

/* aboot reserves 0xfa0000 bytes here - four 1280-line frames - and which one
 * the display controller is scanning out is not documented. Paint all of them,
 * otherwise a marker can land in a buffer nobody sees and look like a hang.
 */
static void fill(int x0, int y0, int w, int h, u32 colour)
{
	int f;

	for (f = 0; f < 4; f++)
		fill_frame(f, x0, y0, w, h, colour);
}

void brfb_panic(void)
{
	/* unmistakable: the whole top band goes pure red */
	fill(0, 0, FB_W, 260, 0x00FF0000);
	fill(0, 264, FB_W, 260, 0x00000000);
}

/* panic() hands us the formatted message: keep it, it is the whole point */
void brlog_panic(const char *msg)
{
	brfb_panic();
	brl_slot(20, msg);
}

void brfb(int n)
{
	static const u32 colours[] = {
		0x00FFFFFF, /* slot 1  white   - setup_arch returned, lowmem mapped */
		0x0000FF00, /* slot 2  green   - early_security_init done */
		0x000000FF, /* slot 3  blue    - mm_core_init done */
		0x00FFFF00, /* slot 4  yellow  - sched_init done */
		0x0000FFFF, /* slot 5  cyan    - time_init done */
		0x00FF00FF, /* slot 6  magenta - console_init done */
		0x00FF8000, /* slot 7  orange  - rest_init reached */
	};

	{
		static const char *const names[] = {
			"0", "setup_arch", "security", "mm_core", "sched",
			"time", "console", "rest_init",
		};
		if (n >= 1 && n <= 7)
			brl_slot(n, names[n]);
	}
	if (n <= 0)
		return;
	/* deliberately no full-screen wipe: the log lives in the top rows of the
	 * second frame, and the bars sit at y=200..260, so neither destroys the
	 * other and the splash is left alone
	 */
	if (n <= 7)
		fill(120 + (n - 1) * (BAR_W + 8), BAR_Y, BAR_W, BAR_H,
		     colours[n - 1]);
}
