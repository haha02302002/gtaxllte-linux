#!/bin/sh
# tty1 respawn target for the SM-T585: X on the framebuffer plus a desktop.
#
# The panel is fb0 (1200x1920, 32bpp), the only pointer is sec_touchscreen and
# its event node number moves between boots, so it is resolved by device name.
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

# ------------------------------------------------------------------------ X
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
grep -E '\(EE\)|\(II\) Using input driver|no screens' /var/log/Xorg.0.log 2>/dev/null | tail -10

# on-screen keyboard for a tablet with no physical keyboard
for kb in matchbox-keyboard xvkbd; do
    command -v "$kb" >/dev/null 2>&1 && { "$kb" >/dev/null 2>&1 & break; }
done

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
