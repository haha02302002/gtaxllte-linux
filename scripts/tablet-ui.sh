#!/bin/sh
# Tablet tuning for the SM-T585 (gtaxllte): touch-friendly XFCE defaults plus
# bindings for the hardware volume and power keys.
#
# Installed as an XFCE autostart entry so it runs inside the session, where
# DISPLAY and the session bus already exist and xfconfd is reachable.

export DISPLAY="${DISPLAY:-:0}"

put() {  # channel property value [type]
    ch="$1"; prop="$2"; val="$3"; typ="${4:-string}"
    xfconf-query -c "$ch" -p "$prop" -n -t "$typ" -s "$val" 2>/dev/null \
        || xfconf-query -c "$ch" -p "$prop" -s "$val" 2>/dev/null
    return 0
}

# ---------------------------------------------------------------- touch sizes
put xsettings /Gtk/IconSizes "gtk-menu=32,32;gtk-button=32,32;gtk-small-toolbar=24,24;gtk-large-toolbar=40,40;gtk-dnd=40,40"
put xsettings /Gtk/ToolbarStyle icons
put xsettings /Gtk/DialogsUseHeader true
put xsettings /Net/IconThemeName Adwaita
put xsettings /Gtk/FontName "Noto Sans 11"
put xsettings /Xft/DPI 120 int
put xsettings /Gtk/EnableAnimations false

# One tap opens a file, big rows, always thumbnails: this is a touch screen.
put thunar /misc-single-click true
put thunar /misc-thumbnail-mode THUNAR_THUMBNAIL_MODE_ALWAYS
put thunar /misc-date-style THUNAR_DATE_STYLE_SHORT

# No title bar on a maximised window: the screen is 1200 px wide and the panel
# plus a title bar is a lot of it. Close/maximise stay on the right.
put xfwm4 /general/titleless_maximize true
put xfwm4 /general/theme Adwaita
put xfwm4 /general/button_layout "O|HMC"
put xfwm4 /general/snap_to_border true

# ------------------------------------------------------------- hardware keys
# gpio_keys exposes the volume rocker and power key as an evdev keyboard, so
# X sees them as XF86 keysyms and they can be bound here without a daemon.
put xfce4-keyboard-shortcuts /commands/custom/XF86AudioRaiseVolume "amixer -q sset Master 5%+ unmute"
put xfce4-keyboard-shortcuts /commands/custom/XF86AudioLowerVolume "amixer -q sset Master 5%- unmute"
put xfce4-keyboard-shortcuts /commands/custom/XF86AudioMute "amixer -q sset Master toggle"
# The power key used to run "xfce4-session-logout --fast", which tears the
# session down instantly; that is indistinguishable from a freeze and leaves X
# half dead. Ask first, so a stray press can be cancelled.
put xfce4-keyboard-shortcuts /commands/custom/XF86PowerOff "xfce4-session-logout"

# ------------------------------------------------------------ power manager
# Suspend and DPMS do not work on this kernel: blanking the panel or trying to
# suspend wedges the display and the tablet is dead until it is power cycled.
# A tablet that lives on a desk must simply stay awake.
for p in dpms-enabled blank-on-ac blank-on-battery dpms-on-ac-sleep          dpms-on-ac-off dpms-on-battery-sleep dpms-on-battery-off          inactivity-on-ac inactivity-on-battery; do
    put xfce4-power-manager "/xfce4-power-manager/$p" false
    put xfce4-power-manager "/xfce4-power-manager/$p" 0 int
done
command -v xset >/dev/null 2>&1 && { xset s off; xset s noblank; xset -dpms; }

# A tap on the panel's keyboard button toggles the on-screen keyboard.
put xfce4-keyboard-shortcuts /commands/custom/XF86HomePage "matchbox-keyboard --toggle"

exit 0
