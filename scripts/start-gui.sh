#!/bin/sh
# tty1 respawn target for the SM-T585: X on the framebuffer plus a desktop.
#
# The panel is fb0 (1200x1920, 32bpp) and the only pointer is sec_touchscreen.
# Its event node number moves between boots, so it is resolved by device name.
# Everything is logged to /var/log/desktop.log because output on tty1 is
# invisible while X owns the framebuffer.
#
# A desktop that half-starts is worse than none: X leaves a black root window
# and the panel is not drawn, so the screen looks dead. Every step below is
# therefore checked, and if the session is not actually drawing, this script
# hands the framebuffer back to the text console with the failure on screen.

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

# ------------------------------------------------------------------ gdk-pixbuf
# Without a loaders.cache gdk-pixbuf registers no image loaders at all, so
# every PNG fails with "Unrecognized image file format". GTK then aborts the
# panel and the desktop (Wnck/Gtk assertions), which is the black screen.
PIXBUF_DIR=/usr/lib/gdk-pixbuf-2.0/2.10.0
export GDK_PIXBUF_MODULEDIR="$PIXBUF_DIR/loaders"
if [ ! -s "$PIXBUF_DIR/loaders.cache" ] && command -v gdk-pixbuf-query-loaders >/dev/null 2>&1; then
    echo "generating $PIXBUF_DIR/loaders.cache"
    gdk-pixbuf-query-loaders --update-cache
fi
if [ -s "$PIXBUF_DIR/loaders.cache" ]; then
    export GDK_PIXBUF_MODULE_FILE="$PIXBUF_DIR/loaders.cache"
    echo "pixbuf cache: $(grep -c '^"' "$PIXBUF_DIR/loaders.cache") entries"
else
    echo "pixbuf cache: MISSING - icons will fail"
fi

# gdk-pixbuf picks a loader by MIME type, so the shared MIME database has to be
# there as well. apk --no-scripts skips shared-mime-info's trigger, and without
# /usr/share/mime/mime.cache even a valid PNG fails with "Unrecognized image file
# format", which aborts the panel and leaves a black root window.
if [ ! -s /usr/share/mime/mime.cache ] && command -v update-mime-database >/dev/null 2>&1; then
    echo "generating /usr/share/mime/mime.cache"
    update-mime-database /usr/share/mime
fi
echo "mime db: $( [ -s /usr/share/mime/mime.cache ] && echo present || echo MISSING )"

# --------------------------------------------------------------- touch pointer
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

# ---------------------------------------------------------------------- udev
# libinput discovers devices through udev, and the ID_INPUT_* tags that tell it
# "this is a touchscreen" are produced by udev's input_id builtin. Without the
# daemon plus one coldplug pass libinput enumerates nothing and the desktop ends
# up with no pointer at all.
if command -v udevd >/dev/null 2>&1; then
    mkdir -p /run/udev
    pidof udevd >/dev/null 2>&1 || udevd --daemon 2>/dev/null
    sleep 1
    udevadm trigger --action=add --type=subsystems 2>/dev/null
    udevadm trigger --action=add --type=devices 2>/dev/null
    udevadm settle --timeout=10 2>/dev/null
    echo "udev: $(ls /run/udev/data 2>/dev/null | wc -l) device records"
    echo "touch tags: $(udevadm info "$EV" 2>/dev/null | grep -o 'ID_INPUT[A-Z_]*=[0-9]' | tr '\n' ' ')"
else
    echo "udev: not installed"
fi

# ------------------------------------------------------------------- X input
# sec_touchscreen reports ABS_MT_POSITION_X/Y (protocol B) and no ABS_X/ABS_Y.
# xf86-input-evdev needs the single-touch axes for an absolute device, so it
# configures this panel as a relative mouse, ignores every touch ("evdev: touch:
# ignoring absolute axes") and the screen does nothing when touched. libinput
# speaks the MT protocol directly, so it is used whenever the image has it.
if [ -e /usr/lib/xorg/modules/input/libinput_drv.so ]; then
    TOUCH_DRIVER=libinput
else
    TOUCH_DRIVER=evdev
fi
echo "touch driver: $TOUCH_DRIVER"

# The panel cannot be read back and shows no difference between "blanked" and
# "broken", so the server is told never to blank, and the saver is disabled
# again after X starts.
if [ "$TOUCH_DRIVER" = "libinput" ]; then
    cat > /etc/X11/xorg.conf <<CONF
Section "ServerFlags"
    Option "BlankTime" "0"
    Option "StandbyTime" "0"
    Option "SuspendTime" "0"
    Option "OffTime" "0"
    Option "DontZap" "false"
EndSection
Section "ServerLayout"
    Identifier "layout"
    Screen "screen"
EndSection
Section "Device"
    Identifier "fb"
    Driver "fbdev"
    Option "fbdev" "/dev/fb0"
    Option "DPMS" "false"
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
Section "InputClass"
    Identifier "touch-tuning"
    MatchIsTouchscreen "on"
    Driver "libinput"
    Option "Tapping" "on"
    Option "TappingDrag" "on"
    Option "DisableWhileTyping" "false"
    Option "ScrollMethod" "twofinger"
    Option "AccelProfile" "flat"
EndSection
Section "InputClass"
    Identifier "ignore-sensors"
    MatchProduct "accelerometer_sensor|light_sensor|grip_sensor_wifi|hall|meta_event"
    Option "Ignore" "true"
EndSection
CONF
else
    cat > /etc/X11/xorg.conf <<CONF
Section "ServerFlags"
    Option "BlankTime" "0"
    Option "StandbyTime" "0"
    Option "SuspendTime" "0"
    Option "OffTime" "0"
EndSection
Section "ServerLayout"
    Identifier "layout"
    Screen "screen"
EndSection
Section "Device"
    Identifier "fb"
    Driver "fbdev"
    Option "fbdev" "/dev/fb0"
    Option "DPMS" "false"
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
CONF
fi

# xfce4-session refuses to run without a session bus, and nothing else starts one
if [ -z "$DBUS_SESSION_BUS_ADDRESS" ]; then
    ADDR=$(dbus-daemon --session --fork --print-address 2>/dev/null | head -1)
    [ -n "$ADDR" ] && export DBUS_SESSION_BUS_ADDRESS="$ADDR"
fi
echo "dbus: ${DBUS_SESSION_BUS_ADDRESS:-none}"

# ------------------------------------------------------------------------ X
# DECON keeps scanning whatever buffer the bootloader left it with, so the first
# X frame can land in memory nobody displays: a live session and a black screen.
# fb_set_var() returns early when the var is unchanged, so the depth is nudged
# back and forth - here, BEFORE X opens fb0 and before anything is mapped.
if command -v fbset >/dev/null 2>&1; then
    fbset -depth 32 2>/dev/null
    fbset -depth 24 2>/dev/null
    echo "fb mode: $(fbset 2>/dev/null | grep -m1 geometry)"
fi

Xorg :0 vt1 -keeptty -nolisten tcp &
XPID=$!
sleep 5

if ! kill -0 "$XPID" 2>/dev/null; then
    echo "Xorg exited immediately"
    grep -E '\(EE\)|Fatal|no screens' /var/log/Xorg.0.log 2>/dev/null | tail -12
    # hand the visible console back with the reason on it, not a black panel
    {
        echo
        echo "=== X failed to start on /dev/fb0 ==="
        tail -25 /var/log/Xorg.0.log 2>/dev/null
        echo "=== full log: /var/log/desktop.log ==="
    } > /dev/tty1 2>&1
    exit 1
fi
echo "Xorg up (pid $XPID)"

# No framebuffer pokes here, deliberately. fbset -depth and fb0/blank both make
# the DECON driver reallocate the buffer it has already handed to X, while X
# keeps drawing into the old memory: that oopses in the fb driver, and the
# bootloader's oops=panic turns it into a kernel panic. The mode is nudged once
# before X starts instead (see above), which is safe.

# Never let the screen blank itself: a DPMS save on this panel is
# indistinguishable from the black-screen failure.
if command -v xset >/dev/null 2>&1; then
    xset s off -dpms 2>/dev/null
    xset s noblank 2>/dev/null
    xset dpms force on 2>/dev/null
    echo "screensaver: $(xset q 2>/dev/null | grep -m1 -i 'timeout')"
fi

grep -E '\(EE\)|Using input driver|libinput|no screens' /var/log/Xorg.0.log 2>/dev/null | tail -12

# On-screen keyboard for a tablet with no physical keyboard. The panel is
# 1200x1920; matchbox-keyboard 0.1.1 has no size flag, its layout file sets
# key size, so it is started plainly (the layout in ~/.matchbox does sizing).
if command -v matchbox-keyboard >/dev/null 2>&1; then
    # The tablet layout has to live in ~/.matchbox/keyboard.xml: that is the
    # file matchbox-keyboard reads at start-up, and without it every key is
    # the stock 30 px size. cat (not cp) so the write is one syscall and a
    # reset cannot leave an empty file behind.
    LAYOUT=/usr/share/matchbox-keyboard/keyboard-tablet.xml
    if [ -f "$LAYOUT" ]; then
        # Both places: ~/.matchbox is what matchbox-keyboard reads, and the
        # default file is the fallback when HOME is not /root. Whichever it
        # picks, the keys are the tablet-sized ones.
        mkdir -p /root/.matchbox /usr/share/matchbox-keyboard
        cat "$LAYOUT" > /root/.matchbox/keyboard.xml 2>/dev/null
        cat "$LAYOUT" > /usr/share/matchbox-keyboard/keyboard.xml 2>/dev/null
        sync
    fi
    matchbox-keyboard >/dev/null 2>&1 &
    echo "osk: matchbox-keyboard"
elif command -v xvkbd >/dev/null 2>&1; then
    xvkbd -geometry 1160x420+20+1480 >/dev/null 2>&1 &
    echo "osk: xvkbd"
else
    echo "osk: none installed"
fi

# -------------------------------------------------------------------- session
SESSION=""
if [ -x /usr/bin/startxfce4 ]; then
    startxfce4 &
    SESSION=$!
fi

# Give the session time to lay out the desktop, then check that something that
# actually paints the root window and the panel is really running. A panel that
# aborted on a broken icon theme leaves only X + a black root window.
i=0
while [ $i -lt 15 ]; do
    sleep 1
    i=$((i + 1))
done
DRAWING=""
ps w 2>/dev/null | grep -q '[x]fce4-panel' && DRAWING=xfce
[ -n "$DRAWING" ] || { ps w 2>/dev/null | grep -q '[x]fdesktop' && DRAWING=xfdesktop; }

if [ -z "$DRAWING" ]; then
    echo "--- desktop did not come up, desktop.log tail ---"
    tail -20 /var/log/desktop.log
    echo "--- falling back to a plain X session (no pixbuf involved) ---"
    [ -n "$SESSION" ] && kill "$SESSION" 2>/dev/null
    if command -v twm >/dev/null 2>&1; then
        twm >/dev/null 2>&1 &
        DRAWING=twm
    fi
    if command -v xterm >/dev/null 2>&1; then
        xterm -geometry 64x34+0+240 -bg black -fg white -fa Monospace -fs 14 >/dev/null 2>&1 &
    fi
fi

echo "session: X pid $XPID, drawing via ${DRAWING:-nothing}"

# Stay alive while X lives; if X dies, put the reason on the console so the
# tablet never just sits on a black screen.
wait "$XPID"
echo "Xorg exited"
{
    echo
    echo "=== the desktop session ended ==="
    tail -20 /var/log/desktop.log 2>/dev/null
    echo "=== full log: /var/log/desktop.log ==="
} > /dev/tty1 2>&1
exit 1
