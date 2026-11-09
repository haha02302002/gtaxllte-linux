#!/bin/sh
# Bring up and record the firmware-backed drivers once per boot.
LOG=/var/log/drivers.log
mkdir -p /var/log 2>/dev/null
exec >> "$LOG" 2>&1
echo "=== driver-check $(date 2>/dev/null) ==="
for f in bdwlan30.bin qwlan30.bin otp30.bin utf30.bin mfc_fw.bin; do
    if [ -s "/lib/firmware/$f" ]; then echo "fw $f: $(stat -c%s "/lib/firmware/$f" 2>/dev/null) bytes"; else echo "fw $f: MISSING"; fi
done
[ -s /lib/firmware/wlan/qca_cld/WCNSS_qcom_cfg.ini ] && echo "fw wlan cfg: present" || echo "fw wlan cfg: MISSING"

# qcacld is built in, so hdd_module_init() returns at once and the real
# init waits for fwpath_changed_handler; Android init fires it by writing
# the fwpath module parameter. Without this no SDIO driver registers.
if [ -e /sys/module/wlan/parameters/fwpath ]; then
    echo sta > /sys/module/wlan/parameters/fwpath 2>/dev/null
    echo "wlan: fwpath=$(cat /sys/module/wlan/parameters/fwpath 2>/dev/null)"
else
    echo "wlan: fwpath parameter MISSING"
fi
i=0
while [ $i -lt 10 ]; do [ -e /sys/class/net/wlan0 ] && break; i=$((i + 1)); sleep 3; done

# Join the saved network at boot, then correct the clock. Without NTP the
# SoC starts in 2016, so every TLS connection (apk, https) fails cert checks.
if [ -e /sys/class/net/wlan0 ] && [ -e /etc/wpa_supplicant/wpa_supplicant.conf ]; then
    killall wpa_supplicant 2>/dev/null
    wpa_supplicant -B -i wlan0 -c /etc/wpa_supplicant/wpa_supplicant.conf >/dev/null 2>&1
    sleep 8
    udhcpc -i wlan0 -b -q >/dev/null 2>&1
    echo "wlan0: $(ifconfig wlan0 2>/dev/null | grep -o "inet addr:[0-9.]*")"
    timeout 20 ntpd -q -p pool.ntp.org >/dev/null 2>&1 || echo "clock: ntp sync skipped"
    echo "clock: $(date)"
fi
if [ -e /sys/class/net/wlan0 ]; then
    echo "wlan0: present after ~$((i * 3))s"
    ifconfig wlan0 up 2>/dev/null || ip link set wlan0 up 2>/dev/null
    echo "wlan0 state: $(cat /sys/class/net/wlan0/operstate 2>/dev/null)"
    echo "wlan0 mac: $(cat /sys/class/net/wlan0/address 2>/dev/null)"
else
    echo "wlan0: absent"
fi
dmesg 2>/dev/null | grep -i -e wlan -e cnss -e firmware | tail -8
# The QCA6174 BT side is on a UART and needs a userspace attach (bluez
# deprecated hciattach); without it no hci0 exists even though the kernel
# stack (RFCOMM/BNEP/HIDP) is initialised.
# hciattach looks for the QCA blobs under /etc/firmware; the image keeps them
# in /lib/firmware, so link them into place before attaching.
mkdir -p /etc/firmware
for f in nvm_tlv_tf_1.1.bin rampatch_tlv_tf_1.1.tlv; do
    [ -e "/lib/firmware/$f" ] && ln -sf "/lib/firmware/$f" "/etc/firmware/$f"
done
if [ ! -e /sys/class/bluetooth/hci0 ] && command -v hciattach >/dev/null 2>&1; then
    for t in /dev/ttySAC1 /dev/ttySAC2; do
        [ -e "$t" ] || continue
        echo "bt: attaching $t"
        timeout 25 hciattach "$t" qca 3000000 flow -t 20 >/tmp/btattach.log 2>&1 &
        sleep 8
        if [ -e /sys/class/bluetooth/hci0 ]; then echo "bt: hci0 up via $t"; break; fi
        echo "bt: no hci0 via $t ($(tail -c 120 /tmp/btattach.log 2>/dev/null | tr "
" " "))"
    done
fi
if [ -e /sys/class/bluetooth/hci0 ]; then
    echo "hci0: present"
    hciconfig hci0 up 2>/dev/null
    hciconfig hci0 2>/dev/null | head -4
else
    echo "hci0: absent"
fi
if dmesg 2>/dev/null | grep -q "mfc_fw.bin failed"; then echo "mfc: firmware load STILL failing"; else echo "mfc: no load error"; fi
echo "sound: $(sed -n 1,2p /proc/asound/cards 2>/dev/null | tr '\n' ' ')"
echo "mali: $(cat /sys/class/misc/mali0/device/power/runtime_status 2>/dev/null)"
echo "backlight: $(cat /sys/class/backlight/panel/brightness 2>/dev/null)/$(cat /sys/class/backlight/panel/max_brightness 2>/dev/null)"
echo "battery: $(cat /sys/class/power_supply/battery/capacity 2>/dev/null)%"
echo "=== done ==="
