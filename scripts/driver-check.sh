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
i=0
while [ $i -lt 10 ]; do [ -e /sys/class/net/wlan0 ] && break; i=$((i + 1)); sleep 3; done
if [ -e /sys/class/net/wlan0 ]; then
    echo "wlan0: present after ~$((i * 3))s"
    ifconfig wlan0 up 2>/dev/null || ip link set wlan0 up 2>/dev/null
    echo "wlan0 state: $(cat /sys/class/net/wlan0/operstate 2>/dev/null)"
    echo "wlan0 mac: $(cat /sys/class/net/wlan0/address 2>/dev/null)"
else
    echo "wlan0: absent"
fi
dmesg 2>/dev/null | grep -i -e wlan -e cnss -e firmware | tail -8
if [ -e /sys/class/bluetooth/hci0 ]; then echo "hci0: present"; hciconfig hci0 up 2>/dev/null; hciconfig hci0 2>/dev/null | head -4; else echo "hci0: absent"; fi
if dmesg 2>/dev/null | grep -q "mfc_fw.bin failed"; then echo "mfc: firmware load STILL failing"; else echo "mfc: no load error"; fi
echo "sound: $(sed -n 1,2p /proc/asound/cards 2>/dev/null | tr '\n' ' ')"
echo "mali: $(cat /sys/class/misc/mali0/device/power/runtime_status 2>/dev/null)"
echo "backlight: $(cat /sys/class/backlight/panel/brightness 2>/dev/null)/$(cat /sys/class/backlight/panel/max_brightness 2>/dev/null)"
echo "battery: $(cat /sys/class/power_supply/battery/capacity 2>/dev/null)%"
echo "=== done ==="
