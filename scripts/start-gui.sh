#!/bin/sh
# tty1 respawn target for the SM-T585: X on the framebuffer plus a desktop.
#
# The panel is fb0 (1200x1920, 32bpp), the only pointer is sec_touchscreen and
# its event node number moves between boots, so it is resolved by device name.
# Everything is logged to /var/log/desktop.log because output on tty1 is
# invisible without a screen.
exec >/var/log/desktop.log 2>&1
echo "=== start-gui $(date 2>/dev/null) ==="

# keep init from disabling this respawn when a session fails fast
sleep 5

export HOME=/root
export DISPLAY=:0
export LANG=C
export XDG_RUNTIME_DIR=/run/xdg
mkdir -p "$XDG_RUNTIME_DIR" /etc/X11
chmod 700 "$XDG_RUNTIME_DIR"
rm -f /tmp/.X0-lock /tmp/.X11-unix/X0

EV=""
for f in /sys/class/input/event*/device/name; do
    [ -e "$f" ] || continue
    if [ "$(cat "$f" 2>/dev/null)" = "sec_touchscreen" ]; then
        EV=/dev/input/$(basename $(dirname $(dirname "$f")))
        break
    fi
done
[ -n "$EV" ] || EV=/dev/input/event1
echo "touchscreen: $EV"

cat > /etc/X11/xorg.conf <<CONF
Section "ServerLayout"
    Identifier "layout"
    Screen "screen"
    InputDevice "touch"
EndSection
Section "Device"
    Identifier "fb"
    Driver "fbdev"
    Option "fbdev" "/dev/fb0"
EndSection
Section "Screen"
    Identifier "screen"
    Device "fb"
    DefaultDepth 24
    SubSection "Display"
        Depth 24
        Modes "1200x1920"
    EndSubSection
EndSection
Section "InputDevice"
    Identifier "touch"
    Driver "evdev"
    Option "Device" "$EV"
    Option "IgnoreRelativeAxes" "true"
EndSection
CONF

# xfce4-session refuses to run without a session bus, and nothing else starts one
if [ -z "$DBUS_SESSION_BUS_ADDRESS" ]; then
    ADDR=$(dbus-daemon --session --fork --print-address 2>/dev/null | head -1)
    [ -n "$ADDR" ] && export DBUS_SESSION_BUS_ADDRESS="$ADDR"
fi
echo "dbus: ${DBUS_SESSION_BUS_ADDRESS:-none}"

Xorg :0 vt1 -keeptty -nolisten tcp &
sleep 4
echo "--- Xorg log ---"
grep -E '\(EE\)|\(II\) Using input driver|Fatal|no screens' /var/log/Xorg.0.log 2>/dev/null | tail -12

# on-screen keyboard for a tablet with no physical keyboard
for kb in matchbox-keyboard xvkbd; do
    command -v "$kb" >/dev/null 2>&1 && { "$kb" >/dev/null 2>&1 & break; }
done

if [ -x /usr/bin/startxfce4 ]; then
    startxfce4
    echo "startxfce4 exited: $?"
fi
if [ -x /usr/bin/twm ]; then
    xterm -geometry 80x25+40+300 >/dev/null 2>&1 &
    exec twm
fi
exec sh
