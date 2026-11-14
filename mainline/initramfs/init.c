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
