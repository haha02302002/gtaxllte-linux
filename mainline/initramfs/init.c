/* Static initramfs /init for the Samsung SM-T360 (rubenswifi) bring-up.
 *
 * Proven on hardware: this binary runs, and its report reaches the cache
 * partition. The busybox shipped in TWRP could never have done this - it is a
 * dynamic Android PIE (PT_INTERP /sbin/linker) and cannot execute in an
 * initramfs. That single fact explains why nothing was ever logged.
 *
 * It dumps the kernel ring buffer (so a mainline boot's dmesg is recoverable),
 * echoes the report to the HSL UART when one exists, writes everything to the
 * 300 MiB cache partition, then reboots so the report can be read from TWRP.
 *
 * Build: arm-linux-gnueabihf-gcc -static -Os -o init init.c
 */
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/sysmacros.h>
#include <sys/types.h>
#include <unistd.h>

#define SYSLOG_ACTION_READ_ALL 3

static char report[768 * 1024];
static int rlen;

static void add(const char *text)
{
	int room = (int)sizeof(report) - 1 - rlen;
	int len = (int)strlen(text);
	if (room <= 0)
		return;
	if (len > room)
		len = room;
	memcpy(report + rlen, text, (size_t)len);
	rlen += len;
	report[rlen] = 0;
}

static void add_file(const char *path)
{
	int fd = open(path, O_RDONLY);
	if (fd < 0) {
		add("(cannot open)");
		return;
	}
	char buf[4096];
	int n, total = 0;
	while ((n = (int)read(fd, buf, sizeof(buf) - 1)) > 0) {
		buf[n] = 0;
		add(buf);
		total += n;
		if (total > 120 * 1024)
			break;
	}
	close(fd);
}

static void add_dmesg(void)
{
	static char kbuf[384 * 1024];
	int n = (int)syscall(SYS_syslog, SYSLOG_ACTION_READ_ALL, kbuf, sizeof(kbuf) - 1);
	add("\n--- dmesg (kernel ring buffer) ---\n");
	if (n > 0) {
		kbuf[n] = 0;
		add(kbuf);
	} else {
		add("(klogctl returned ");
		char num[16];
		snprintf(num, sizeof(num), "%d)\n", n);
		add(num);
	}
}

static int part_devnum(int part, int *maj, int *min)
{
	char p[64], buf[32];
	snprintf(p, sizeof(p), "/sys/class/block/mmcblk0p%d/dev", part);
	int fd = open(p, O_RDONLY);
	if (fd < 0)
		return -1;
	int n = (int)read(fd, buf, sizeof(buf) - 1);
	close(fd);
	if (n <= 0)
		return -1;
	buf[n] = 0;
	return sscanf(buf, "%d:%d", maj, min) == 2 ? 0 : -1;
}

static unsigned long part_sectors(int part)
{
	char p[64], buf[32];
	snprintf(p, sizeof(p), "/sys/class/block/mmcblk0p%d/size", part);
	int fd = open(p, O_RDONLY);
	if (fd < 0)
		return 0;
	int n = (int)read(fd, buf, sizeof(buf) - 1);
	close(fd);
	if (n <= 0)
		return 0;
	buf[n] = 0;
	return strtoul(buf, NULL, 10);
}

static int node_for(int part)
{
	int maj, min;
	if (part_devnum(part, &maj, &min) != 0)
		return -1;
	char path[64];
	snprintf(path, sizeof(path), "/dev/bringup-p%d", part);
	unlink(path);
	if (mknod(path, S_IFBLK | 0600, makedev(maj, min)) == 0)
		return part;
	snprintf(path, sizeof(path), "/dev/mmcblk0p%d", part);
	if (mknod(path, S_IFBLK | 0600, makedev(maj, min)) == 0)
		return part;
	return -1;
}

static int write_to(int part)
{
	char path[64];
	snprintf(path, sizeof(path), "/dev/bringup-p%d", part);
	int fd = open(path, O_WRONLY);
	if (fd < 0) {
		snprintf(path, sizeof(path), "/dev/mmcblk0p%d", part);
		fd = open(path, O_WRONLY);
		if (fd < 0)
			return -1;
	}
	int n = (int)write(fd, report, (size_t)rlen);
	fsync(fd);
	close(fd);
	return n == rlen ? 0 : -1;
}

/* Echo to the HSL UART: on this board it lives at 0xf991f000. If anything is
 * wired to it, the log is visible live instead of only after a reboot. */
static void echo_console(void)
{
	static const char *devs[] = { "/dev/ttyHSL0", "/dev/ttyMSM0", 0 };
	for (int i = 0; devs[i]; i++) {
		int fd = open(devs[i], O_WRONLY | O_NONBLOCK);
		if (fd >= 0) {
			write(fd, report, (size_t)rlen);
			close(fd);
			return;
		}
	}
}

/* Make a /dev node from its sysfs major:minor. devtmpfs is not enough this
 * early: the driver's class device can exist in sysfs while the node does not.
 */
static int mknod_from_sysfs(const char *sysfs, const char *node, int is_blk)
{
	char buf[32];
	int fd, n, maj, min;

	fd = open(sysfs, O_RDONLY);
	if (fd < 0)
		return -1;
	n = (int)read(fd, buf, sizeof(buf) - 1);
	close(fd);
	if (n <= 0)
		return -1;
	buf[n] = 0;
	if (sscanf(buf, "%d:%d", &maj, &min) != 2)
		return -1;
	unlink(node);
	return mknod(node, (is_blk ? S_IFBLK : S_IFCHR) | 0600,
		     makedev(maj, min));
}

/* Copy the kernel-side RAM log (see earlyscreen/bringup_fb.c) into the report.
 * It survives a reset, so a boot that hung before userspace still leaves text.
 */
static void dump_ring(void)
{
	unsigned char buf[4096];
	int fd, n, i, j;

	add("\n--- RINGLOG (0x30000000) ---\n");
	/* /sys/class/mem/mem/dev does not exist on this vendor kernel, and /dev/mem
	 * is simply character device 1:1, so create it directly.
	 */
	if (mknod_from_sysfs("/sys/class/mem/mem/dev", "/dev/bringup-mem", 0) != 0) {
		unlink("/dev/bringup-mem");
		if (mknod("/dev/bringup-mem", S_IFCHR | 0600, makedev(1, 1)) != 0 &&
		    mknod("/dev/mem", S_IFCHR | 0600, makedev(1, 1)) != 0) {
			add("DEVMEM-NONODE\n");
			return;
		}
		add("DEVMEM-NODE-1:1\n");
	}
	fd = open("/dev/bringup-mem", O_RDONLY);
	if (fd < 0) {
		add("DEVMEM-NOOPEN\n");
		return;
	}
	n = (int)pread(fd, buf, sizeof(buf), (off_t)0x30000000UL);
	close(fd);
	if (n <= 0) {
		add("DEVMEM-NOREAD\n");
		return;
	}
	add("magic: ");
	for (i = 0; i < 5 && i < n; i++) {
		if (buf[i] >= 32 && buf[i] < 127)
			add((char[]){ (char)buf[i], 0 });
		else
			add(".");
	}
	add("\nslots:\n");
	for (j = 0; j < 24; j++) {
		int off = 64 + j * 64;
		int empty = 1;
		if (off >= n)
			break;
		for (i = 0; i < 63 && off + i < n; i++)
			if (buf[off + i])
				empty = 0;
		if (empty)
			continue;
		add("  ");
		for (i = 0; i < 63 && off + i < n && buf[off + i]; i++) {
			unsigned char c = buf[off + i];
			if (c >= 32 && c < 127)
				add((char[]){ (char)c, 0 });
			else
				add("?");
		}
		add("\n");
	}
}

/* Does this panel display anything the kernel writes? With the vendor kernel
 * the MDSS driver has already brought the panel up, so filling fb0 answers the
 * question that blocks all on-screen debugging. */
static void paint_fb(void)
{
	static const char *devs[] = { "/dev/graphics/fb0", "/dev/fb0", 0 };
	static unsigned char buf[64 * 1024];
	/* virtual_size is w,h - this panel reports 800,2560, i.e. TWO 1280-line
	 * frames. Painting only the first leaves the visible one untouched, which
	 * looks exactly like a dead panel. Paint every frame the device reports.
	 */
	unsigned long total = 800UL * 2560UL * 4UL;
	int i, fd = -1;

	for (i = 0; i < (int)sizeof(buf); i += 4) {
		/* top half bright red, bottom half bright green, little endian xRGB */
		buf[i + 0] = 0x00;
		buf[i + 1] = 0x00;
		buf[i + 2] = 0xFF;
		buf[i + 3] = 0x00;
	}
	{
		char vs[64];
		int fd2 = open("/sys/class/graphics/fb0/virtual_size", O_RDONLY);
		if (fd2 >= 0) {
			int n2 = (int)read(fd2, vs, sizeof(vs) - 1);
			close(fd2);
			if (n2 > 0) {
				unsigned long w = 0, h = 0;
				vs[n2] = 0;
				if (sscanf(vs, "%lu,%lu", &w, &h) == 2 && w && h)
					total = w * h * 4;
			}
		}
	}
	/* devtmpfs often has no node yet even though the class device exists */
	mknod_from_sysfs("/sys/class/graphics/fb0/dev", "/dev/fb0", 0);
	mknod_from_sysfs("/sys/class/graphics/fb0/dev", "/dev/graphics/fb0", 0);
	for (i = 0; devs[i]; i++) {
		fd = open(devs[i], O_RDWR);
		if (fd >= 0)
			break;
	}
	if (fd < 0) {
		add("FB-ABSENT no framebuffer device\n");
		return;
	}
	add("FB-OPENED ");
	add(devs[i]);
	add("\n");
	while (total) {
		unsigned long chunk = total < sizeof(buf) ? total : sizeof(buf);
		if (write(fd, buf, (size_t)chunk) != (ssize_t)chunk)
			break;
		total -= chunk;
	}
	fsync(fd);
	close(fd);
	add("FB-PAINTED\n");
}

int main(void)
{
	mkdir("/proc", 0755);
	mkdir("/sys", 0755);
	mkdir("/dev", 0755);
	mount("proc", "/proc", "proc", 0, NULL);
	mount("sysfs", "/sys", "sysfs", 0, NULL);
	mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);

	add("INIT-RAN static bringup init\n");
	add("--- version ---\n");   add_file("/proc/version");    add("\n");
	add("--- cmdline ---\n");   add_file("/proc/cmdline");    add("\n");
	add("--- meminfo ---\n");   add_file("/proc/meminfo");    add("\n");
	add("--- iomem ---\n");     add_file("/proc/iomem");      add("\n");
	add("--- partitions ---\n"); add_file("/proc/partitions"); add("\n");
	add("--- framebuffer ---\n"); add_file("/sys/class/graphics/fb0/virtual_size"); add("\n");
	add_file("/sys/class/graphics/fb0/stride"); add("\n");
	paint_fb();
	dump_ring();
	add_dmesg();

	/* cache is 614400 sectors (300 MiB); fall back to the known number. */
	int target = -1;
	for (int p = 0; p < 64; p++) {
		if (part_sectors(p) == 614400UL) { target = p; break; }
	}
	if (target < 0)
		target = 24;

	char note[96];
	snprintf(note, sizeof(note), "\n--- writing to mmcblk0p%d ---\n", target);
	add(note);

	echo_console();

	int wrote = -1;
	for (int attempt = 0; attempt < 3 && wrote != 0; attempt++) {
		if (node_for(target) >= 0)
			wrote = write_to(target);
		if (wrote != 0)
			sleep(1);
	}
	if (wrote != 0 && node_for(16) >= 0)
		wrote = write_to(16);

	sync();
	sleep(5);
	sync();
	reboot(RB_AUTOBOOT);
	for (;;)
		pause();
}
