/* Static initramfs /init for the Samsung SM-T360 (rubenswifi) bring-up.
 *
 * Needs nothing but the kernel: the busybox shipped in TWRP is a dynamic
 * Android PIE (PT_INTERP /sbin/linker) and cannot execute in an initramfs,
 * which is why earlier attempts produced no log at all.
 *
 * The only durable channel is the "cache" partition. Device nodes may not
 * exist (devtmpfs is optional, and a vendor kernel may not mount it), so this
 * creates the node itself from the major:minor in sysfs before writing.
 *
 * It reboots 5 s after starting: a quick reboot after boot means /init ran,
 * a long gap then reboot means the kernel never reached userspace.
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
#include <sys/sysmacros.h>
#include <sys/types.h>
#include <unistd.h>

static char report[512 * 1024];
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

/* major:minor for a partition, straight from sysfs. */
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

/* Sector count for a partition, from sysfs. */
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
	if (mknod(path, S_IFBLK | 0600, makedev(maj, min)) != 0) {
		char legacy[64];
		snprintf(legacy, sizeof(legacy), "/dev/mmcblk0p%d", part);
		if (mknod(legacy, S_IFBLK | 0600, makedev(maj, min)) == 0)
			return part;
		return -1;
	}
	return part;
}

static int write_to(int part)
{
	char path[64];
	snprintf(path, sizeof(path), "/dev/bringup-p%d", part);
	int fd = open(path, O_WRONLY);
	if (fd < 0)
		return -1;
	int n = (int)write(fd, report, (size_t)rlen);
	fsync(fd);
	close(fd);
	return n == rlen ? 0 : -1;
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
	add("--- version ---\n");   add_file("/proc/version");   add("\n");
	add("--- cmdline ---\n");   add_file("/proc/cmdline");   add("\n");
	add("--- meminfo ---\n");   add_file("/proc/meminfo");   add("\n");
	add("--- iomem ---\n");     add_file("/proc/iomem");     add("\n");
	add("--- partitions ---\n"); add_file("/proc/partitions"); add("\n");

	/* cache is 614400 sectors (300 MiB); fall back to the known numbers. */
	int target = -1;
	for (int p = 0; p < 64; p++) {
		if (part_sectors(p) == 614400UL) { target = p; break; }
	}
	if (target < 0)
		target = 24;

	char note[96];
	snprintf(note, sizeof(note), "\n--- writing to mmcblk0p%d ---\n", target);
	add(note);

	int wrote = -1;
	for (int attempt = 0; attempt < 3 && wrote != 0; attempt++) {
		if (node_for(target) >= 0)
			wrote = write_to(target);
		if (wrote != 0)
			sleep(1);
	}
	/* fota as a second chance, in case cache is not writable */
	if (wrote != 0 && node_for(16) >= 0)
		wrote = write_to(16);

	add(wrote == 0 ? "\nREPORT-WRITTEN\n" : "\nREPORT-WRITE-FAILED\n");
	if (wrote == 0) {
		int t = target;
		if (node_for(t) >= 0)
			write_to(t);
	}

	sync();
	sleep(5);            /* short: a fast reboot means /init really ran */
	sync();
	reboot(RB_AUTOBOOT);
	for (;;)
		pause();
}
