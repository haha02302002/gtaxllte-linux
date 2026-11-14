/* Earliest possible on-panel progress reporting for the SM-T360 bring-up.
 *
 * Why this exists: mainline hangs before simple-framebuffer probes, so neither
 * fbcon nor the cache-partition report can show us where it died. This file is
 * compiled into the kernel and paints markers directly into the buffer aboot
 * already left on the panel (800x1280x32bpp at 0x03200000), which the display
 * controller keeps scanning out. Each marker is a coloured bar, so "how many
 * bars are visible" is how far boot got without needing a font, a console, a
 * driver or a working UART.
 *
 * Called from init/main.c (see earlyscreen/apply.py in the port repo) and from
 * kernel/panic.c. Never touches memory outside aboot's own splash region.
 */
#include <linux/kernel.h>
#include <linux/types.h>
#include <asm/io.h>

#define FB_PHYS   0x03200000UL
#define FB_W      800
#define FB_STRIDE 3200
#define BAR_W     52
#define BAR_H     60
#define BAR_Y     200

static u32 *const fb = (u32 *)__va(FB_PHYS);

static void fill(int x0, int y0, int w, int h, u32 colour)
{
	int x, y;
	u32 *p;

	for (y = y0; y < y0 + h && y < 1280; y++) {
		if (y < 0)
			continue;
		p = fb + y * (FB_STRIDE / 4) + x0;
		for (x = 0; x < w && x0 + x < FB_W; x++)
			p[x] = colour;
	}
}

void brfb_panic(void)
{
	/* unmistakable: the whole top band goes pure red */
	fill(0, 0, FB_W, 260, 0x00FF0000);
	fill(0, 264, FB_W, 260, 0x00000000);
}

void brfb(int n)
{
	static const u32 colours[] = {
		0x00FFFFFF, /* slot 1  white   - mapping/paging_init done */
		0x0000FF00, /* slot 2  green   - setup_arch returned */
		0x000000FF, /* slot 3  blue    - mm_init done */
		0x00FFFF00, /* slot 4  yellow  - sched_init done */
		0x0000FFFF, /* slot 5  cyan    - time_init done */
		0x00FF00FF, /* slot 6  magenta - console_init done */
		0x00FF8000, /* slot 7  orange  - rest_init reached */
	};

	if (n <= 0) {
		fill(0, 0, FB_W, 1280, 0x00000000);
		return;
	}
	if (n == 1)
		/* wipe the logo so the bars cannot be confused with it */
		fill(0, 0, FB_W, 1280, 0x00000000);
	if (n <= 7) {
		fill(120 + (n - 1) * (BAR_W + 8), BAR_Y, BAR_W, BAR_H,
		     colours[n - 1]);
	}
}
