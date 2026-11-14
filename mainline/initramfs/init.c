/* Static initramfs /init for the Samsung SM-T360 (rubenswifi) bring-up.
 *
 * The busybox pulled out of TWRP is a dynamic Android PIE binary (PT_INTERP
 * /sbin/linker), so it cannot execute in a bare initramfs - which is why every
 * earlier attempt produced no log anywhere. This binary is built with -static
 * and needs nothing but the kernel.
 *
 * It mounts the pseudo filesystems, collects a boot report and writes it to the
 * "cache" partition (the only durable channel: no UART, no usable console, and
 * the bootloader watchdog resets the board).
 *
 * Build: arm-linux-gnueabihf-gcc -static -Os -o init init.c
 */
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

static int append(const char *out, int cap, const char *text)
{
	int n = (int)strlen(out);
	if (n >= cap - 1)
		return n;
	int room = cap - 1 - n;
	int len = (int)strlen(text);
	if (len > room)
		len = room;
	memcpy((char *)out + n, text, (size_t)len);
	((char *)out)[n + len] = 0;
	return n + len;
}

static int append_file(const char *out, int cap, const char *path)
{
	int fd = open(path, O_RDONLY);
	if (fd < 0) {
		append(out, cap, "(cannot open)");
		return 0;
	}
	char buf[8192];
	int n, total = 0;
	while ((n = (int)read(fd, buf, sizeof(buf) - 1)) > 0 && total < 8 * 1024 * 1024) {
		buf[n] = 0;
		append(out, cap, buf);
		total += n;
		if (total > 200 * 1024)          /* keep the report readable */
			break;
	}
	close(fd);
	return total;
}

/* Locate the cache partition: fixed path first, then whatever block device is
 * exactly 614400 sectors (300 MiB), independent of recovery fstab quirks. */
static int find_cache(char *path, size_t len)
{
	static const char *candidates[] = {
		"/dev/mmcblk0p24", "/dev/block/mmcblk0p24",
		"/dev/block/bootdevice/by-name/cache", "/dev/block/by-name/cache", 0
	};
	for (int i = 0; candidates[i]; i++) {
		if (access(candidates[i], F_OK) == 0) {
			snprintf(path, len, "%s", candidates[i]);
			return 0;
		}
	}
	for (int part = 0; part < 64; part++) {
		char p[64], size[32];
		snprintf(p, sizeof(p), "/sys/class/block/mmcblk0p%d/size", part);
		int fd = open(p, O_RDONLY);
		if (fd < 0)
			continue;
		int n = (int)read(fd, size, sizeof(size) - 1);
		close(fd);
		if (n <= 0)
			continue;
		size[n] = 0;
		if (strncmp(size, "614400", 6) == 0) {
			snprintf(path, len, "/dev/mmcblk0p%d", part);
			return 0;
		}
	}
	return -1;
}

static int write_report(const char *path, const char *data, int len)
{
	int fd = open(path, O_WRONLY);
	if (fd < 0)
		return -1;
	int n = (int)write(fd, data, (size_t)len);
	fsync(fd);
	close(fd);
	return n == len ? 0 : -1;
}

int main(void)
{
	mkdir("/proc", 0755);
	mkdir("/sys", 0755);
	mkdir("/dev", 0755);
	mount("proc", "/proc", "proc", 0, NULL);
	mount("sysfs", "/sys", "sysfs", 0, NULL);
	mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);

	static char report[512 * 1024];
	report[0] = 0;
	append(report, sizeof(report), "INIT-RAN static bringup init\n");
	append(report, sizeof(report), "--- version ---\n");
	append_file(report, sizeof(report), "/proc/version");
	append(report, sizeof(report), "\n--- cmdline ---\n");
	append_file(report, sizeof(report), "/proc/cmdline");
	append(report, sizeof(report), "\n--- memory ---\n");
	append_file(report, sizeof(report), "/proc/meminfo");
	append(report, sizeof(report), "\n--- iomem ---\n");
	append_file(report, sizeof(report), "/proc/iomem");
	append(report, sizeof(report), "\n--- partitions ---\n");
	append_file(report, sizeof(report), "/proc/partitions");

	char cache[64];
	int have = find_cache(cache, sizeof(cache)) == 0;
	char line[128];
	snprintf(line, sizeof(line), "\n--- cache device: %s ---\n", have ? cache : "NOT FOUND");
	append(report, sizeof(report), line);

	int len = (int)strlen(report);
	int ok = 0;
	if (have && write_report(cache, report, len) == 0)
		ok = 1;
	if (!ok && write_report("/dev/mmcblk0p16", report, len) == 0)
		ok = 2;

	/* Reboot so the next stage (recovery/TWRP) can read the report even if no
	 * watchdog is armed. */
	sync();
	sleep(3);
	reboot(RB_AUTOBOOT);

	for (;;)
		pause();
}
