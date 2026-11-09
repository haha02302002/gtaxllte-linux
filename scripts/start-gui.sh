#!/bin/sh
# tty1 respawn target for the SM-T585 (gtaxllte): X on the framebuffer.
#
# Panel: BOE HX8279D <- DSIM <- DECON <- /dev/fb0 (1200x1920x32).
#
# X's KD_GRAPHICS VT switch makes fbcon blank the console, and that
# fb_blank(POWERDOWN) is decon_blank() -> decon_disable(): DECON stops
# scanning, the DSI stream stops and the panel goes dark, with nothing to
# restore it. fbcon is detached from the VT below. The backlight is never set
# on a Linux boot either (decon_probe skips hx8279d_displayon).
#
# DECON's fb read/write are stubs, so "black" and "drawing" look identical
# from here: log everything to /var/log/desktop.log, print failures on the
# panel, and give the desktop a solid colour so a painting X is unambiguous.

LOG=/var/log/desktop.log
if : > "$LOG" 2>/dev/null; then
    exec > "$LOG" 2>&1
else
    exec >/dev/null 2>&1
fi

echo "=== start-gui v5 $(date 2>/dev/null) ==="
sleep 5   # stop init disabling this respawn when a session fails fast

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export HOME=/root DISPLAY=:0 LANG=C
export XDG_CURRENT_DESKTOP=XFCE XDG_RUNTIME_DIR=/run/xdg
mkdir -p "$XDG_RUNTIME_DIR" /etc/X11 /root/.config /root/.cache
chmod 700 "$XDG_RUNTIME_DIR"
rm -f /tmp/.X0-lock /tmp/.X11-unix/X0

BLANK=/sys/class/graphics/fb0/blank
VTC=/sys/class/vtconsole/vtcon1/bind
PANEL=/sys/class/backlight/panel

backlight() {
    for d in /sys/class/backlight/*/; do
        [ -r "$d/max_brightness" ] || continue
        m=$(cat "$d/max_brightness" 2>/dev/null)
        case "$m" in ''|*[!0-9]*) m=255 ;; esac
        [ "$m" -gt 0 ] 2>/dev/null || m=255
        echo "$m" > "$d/brightness" 2>/dev/null
        echo 0 > "$d/bl_power" 2>/dev/null
    done
    for d in /sys/class/leds/*backlight*/; do
        [ -e "$d/brightness" ] && echo 255 > "$d/brightness" 2>/dev/null
    done
}

# FBIOBLANK UNBLANK -> decon_enable(): reprograms the default window from
# fbinfo (decon_reg_set_regs_data_init) and restarts the DSI stream. The only
# userspace path that turns DECON back on.
unblank() {
    echo 0 > "$BLANK" 2>/dev/null
    echo "  fb0/blank=$(cat "$BLANK" 2>/dev/null) backlight=$(cat "$PANEL/brightness" 2>/dev/null)/$(cat "$PANEL/max_brightness" 2>/dev/null)"
}


i=0
while [ $i -lt 10 ] && [ ! -e "$PANEL/brightness" ]; do
    sleep 0.1 2>/dev/null || sleep 1
    i=$((i+1))
done
backlight
unblank

# APK was installed with --no-scripts: without loaders.cache no image loader
# registers, every PNG fails and GTK aborts the panel.
PIXBUF_DIR=/usr/lib/gdk-pixbuf-2.0/2.10.0
export GDK_PIXBUF_MODULEDIR="$PIXBUF_DIR/loaders"
if [ ! -s "$PIXBUF_DIR/loaders.cache" ] && command -v gdk-pixbuf-query-loaders >/dev/null 2>&1; then
    gdk-pixbuf-query-loaders --update-cache
fi
if [ -s "$PIXBUF_DIR/loaders.cache" ]; then
    export GDK_PIXBUF_MODULE_FILE="$PIXBUF_DIR/loaders.cache"
    echo "pixbuf cache: present"
else
    echo "pixbuf cache: MISSING - icons will fail"
fi
if [ ! -s /usr/share/mime/mime.cache ] && command -v update-mime-database >/dev/null 2>&1; then
    update-mime-database /usr/share/mime 2>/dev/null
fi
echo "mime db: $( [ -s /usr/share/mime/mime.cache ] && echo present || echo MISSING )"

# sec_touchscreen's eventN moves between boots; resolve it by name.
EV=""
for f in /sys/class/input/event*/device/name; do
    [ -e "$f" ] || continue
    [ "$(cat "$f" 2>/dev/null)" = "sec_touchscreen" ] && \
        EV=/dev/input/$(basename "$(dirname "$(dirname "$f")")") && break
done
[ -n "$EV" ] || EV=/dev/input/event1
echo "touchscreen: $EV"

# libinput needs udev's ID_INPUT_* tags, so one coldplug pass is required.
if command -v udevd >/dev/null 2>&1; then
    mkdir -p /run/udev
    pidof udevd >/dev/null 2>&1 || udevd --daemon 2>/dev/null
    sleep 1
    udevadm trigger --action=add --type=subsystems 2>/dev/null
    udevadm trigger --action=add --type=devices 2>/dev/null
    udevadm settle --timeout=10 2>/dev/null
    echo "udev: $(ls /run/udev/data 2>/dev/null | wc -l) device records"
fi

# sec_touchscreen is MT protocol B (ABS_MT_*, no ABS_X/Y): evdev reads that as a
# relative mouse and ignores every touch, libinput speaks MT directly.
if [ -e /usr/lib/xorg/modules/input/libinput_drv.so ]; then
    TOUCH_DRIVER=libinput
    TOUCH_OPTS="\"Device\" \"$EV\""
else
    TOUCH_DRIVER=evdev
    TOUCH_OPTS="\"Device\" \"$EV\"
    Option \"IgnoreRelativeAxes\" \"true\""
fi
echo "touch driver: $TOUCH_DRIVER"

# No "Modes": fbdevHWSetVideoModes() returns early when display->modes is NULL,
# so fbdev keeps the console's mode and issues no second FBIOPUT_VSCREENINFO.
# Blank/DPMS at zero: a DPMS save here looks exactly like the failure above.
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
    InputDevice "touch"
EndSection
Section "Device"
    Identifier "fb"
    Driver "fbdev"
    Option "fbdev" "/dev/fb0"
    Option "DPMS" "false"
    Option "ShadowFB" "true"
EndSection
Section "Screen"
    Identifier "screen"
    Device "fb"
    DefaultDepth 24
    DefaultFbBpp 32
    SubSection "Display"
        Depth 24
    EndSubSection
EndSection
Section "InputDevice"
    Identifier "touch"
    Driver "$TOUCH_DRIVER"
    Option $TOUCH_OPTS
EndSection
CONF

# xfwm4 composites through XRender; fbdev is not DRI capable and without GL the
# composite overlay can stay empty, which is a black screen over a live session.
XFC=/root/.config/xfce4/xfconf/xfce-perchannel-xml
mkdir -p "$XFC"
cat > "$XFC/xfwm4.xml" <<'XFCONF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <property name="use_compositing" type="bool" value="false"/>
  </property>
</channel>
XFCONF

# Solid colour instead of wallpaper: no image to decode, and a black root window
# could not be told apart from a panel that is off.
cat > "$XFC/xfdesktop.xml" <<'XFCONF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfdesktop" version="1.0">
  <property name="backdrop" type="empty">
    <property name="screen0" type="empty">
      <property name="monitor0" type="empty">
        <property name="image-style" type="int" value="0"/>
        <property name="color-style" type="int" value="0"/>
        <property name="rgba1" type="array">
          <value type="double" value="0.145"/>
          <value type="double" value="0.300"/>
          <value type="double" value="0.500"/>
          <value type="double" value="1.000"/>
        </property>
      </property>
    </property>
  </property>
</channel>
XFCONF

# xfce4-power-manager autostarts with the session and dims to zero on battery.
mkdir -p /root/.config/autostart
printf '[Desktop Entry]\nType=Application\nName=xfce4-power-manager\nHidden=true\n' \
    > /root/.config/autostart/xfce4-power-manager.desktop 2>/dev/null
pkill xfce4-power-manager 2>/dev/null

# The fix: X's KD_GRAPHICS switch is what makes fbcon blank the console, and
# that power-down is what kills the panel. X talks to /dev/fb0 directly and
# needs no console, so fbcon is detached here; on failure it is rebound so the
# diagnostics are readable on the panel.
# fbcon is deliberately left bound. Detaching it runs do_unbind_con_driver ->
# fb_blank(FB_BLANK_NORMAL) -> decon_blank() -> decon_disable(), which is what
# cut the panel's rails in every earlier build.
echo "vtconsole: $(cat "$VTC" 2>/dev/null) (fbcon left bound)"
unblank

# xfce4-session needs a session bus
if [ -z "$DBUS_SESSION_BUS_ADDRESS" ]; then
    ADDR=$(dbus-daemon --session --fork --print-address 2>/dev/null | tail -1)
    [ -n "$ADDR" ] && export DBUS_SESSION_BUS_ADDRESS="$ADDR"
fi
echo "dbus: ${DBUS_SESSION_BUS_ADDRESS:-none}"

# Never touch the mode before X starts: a mode change at that moment is what
# left earlier builds with a live session and a dark panel.
Xorg :0 vt1 -keeptty -nolisten tcp &
XPID=$!
sleep 5

if ! kill -0 "$XPID" 2>/dev/null; then
    echo "Xorg exited immediately"
    grep -E '\(EE\)|Fatal|no screens' /var/log/Xorg.0.log 2>/dev/null | tail -12
    unblank
    {
        echo; echo "=== X failed to start on /dev/fb0 ==="
        tail -25 /var/log/Xorg.0.log 2>/dev/null
        echo "=== full log: /var/log/desktop.log ==="
    } > /dev/tty1 2>&1
    sleep 60
    exit 1
fi
echo "Xorg up (pid $XPID)"

# X owns the screen: cycle the panel so the real decon_enable()/dsim_enable()
# path runs and dsim_panel_displayon() restores the rails.
unblank

grep -E '\(EE\)|Using input driver|no screens' /var/log/Xorg.0.log 2>/dev/null | tail -12

for kb in matchbox-keyboard xvkbd; do
    command -v "$kb" >/dev/null 2>&1 && { "$kb" >/dev/null 2>&1 & break; }
done

# watchdog: pin the backlight, keep the power manager dead
(
    while kill -0 "$XPID" 2>/dev/null; do
        sleep 20
        backlight
        unblank
        pkill xfce4-power-manager 2>/dev/null
    done
) &
KEEPER=$!

startxfce4 &
SESSION=$!

# check something that really paints, not just a running session
i=0
DRAWING=""
while [ $i -lt 10 ]; do
    sleep 2
    i=$((i+1))
    ps w 2>/dev/null | grep -q '[x]fce4-panel' && DRAWING=xfce
    [ -n "$DRAWING" ] || { ps w 2>/dev/null | grep -q '[x]fdesktop' && DRAWING=xfdesktop; }
    [ -n "$DRAWING" ] && break
done

if [ -z "$DRAWING" ]; then
    [ -n "$SESSION" ] && kill "$SESSION" 2>/dev/null

    # A plain X root window is solid black; the fallback must paint something
    # unmistakable: a white terminal holding the diagnostics.
    unblank
    cat > /tmp/gui-report <<'EOF'
#!/bin/sh
tail -40 /var/log/desktop.log 2>/dev/null
exec /bin/sh
EOF
    chmod 700 /tmp/gui-report 2>/dev/null
    command -v xterm >/dev/null 2>&1 && \
        xterm -geometry 100x50+2+2 -bg white -fg black -e /tmp/gui-report >/dev/null 2>&1 &
    DRAWING=report
    command -v twm >/dev/null 2>&1 && { twm >/dev/null 2>&1 & DRAWING="$DRAWING+twm"; }
fi
echo "panel: bl=$(cat "$PANEL/brightness" 2>/dev/null)/$(cat "$PANEL/max_brightness" 2>/dev/null) vtcon=$(cat "$VTC" 2>/dev/null) size=$(cat /sys/class/graphics/fb0/virtual_size 2>/dev/null) bpp=$(cat /sys/class/graphics/fb0/bits_per_pixel 2>/dev/null) stride=$(cat /sys/class/graphics/fb0/stride 2>/dev/null)"
echo "session: X pid $XPID, drawing via $DRAWING"

kill "$KEEPER" 2>/dev/null
wait "$XPID"
echo "Xorg exited"
{
    echo; echo "=== the desktop session ended ==="
    tail -20 /var/log/desktop.log 2>/dev/null
    echo "=== full log: /var/log/desktop.log ==="
} > /dev/tty1 2>&1
exit 1
