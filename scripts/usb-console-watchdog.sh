#!/bin/sh
# Keep the USB serial console (ttyGS0 / COM6) usable.
#
# Two failure modes are handled:
#  1. the link drops and the UDC leaves "configured"  -> re-bind immediately
#     after three bad polls;
#  2. the host-side stall: the shell echoes what you type but nothing comes
#     back, while the device still reports "configured", so no state check can
#     see it. Unplugging the cable fixes that, and re-binding the UDC is what
#     unplugging does. To avoid breaking an active session, the port is only
#     refreshed after the console has been idle for ten polls, measured from
#     the tty's rx byte counter.
#
# Touch /tmp/usb-rebind to force a re-bind on the next poll.
LOG=/var/log/usb-console.log
mkdir -p /var/log 2>/dev/null
log() { echo "$(date 2>/dev/null) $*" >> "$LOG"; }
find_udc() { for d in /sys/class/udc/*; do [ -e "$d/state" ] || continue; basename "$d"; return 0; done; return 1; }
find_gadget() { for g in /sys/kernel/config/usb_gadget/*; do [ -e "$g/UDC" ] || continue; echo "$g"; return 0; done; return 1; }
rx_bytes() { cat /sys/class/tty/ttyGS0/statistics/rx_bytes 2>/dev/null; }
vbus_online() {
    for f in /sys/class/power_supply/*/online; do
        [ -e "$f" ] || continue
        [ "$(cat "$f" 2>/dev/null)" = "1" ] && return 0
    done
    return 1
}

# initramfs init defers the gadget when it boots without VBUS, so when power
# appears later this has to create and bind it, otherwise there is no console
# for the rest of the session.
gadget_up() {
    G=/sys/kernel/config/usb_gadget/g1
    UDC=$(find_udc) || return 1
    mount -t configfs none /sys/kernel/config 2>/dev/null
    [ -d /sys/kernel/config/usb_gadget ] || return 1
    if [ ! -d "$G" ]; then
        mkdir -p "$G/strings/0x409" "$G/configs/c.1/strings/0x409" || return 1
        echo 0x1d6b > "$G/idVendor";  echo 0x0104 > "$G/idProduct"
        echo 0x0100 > "$G/bcdDevice"; echo 0x0200 > "$G/bcdUSB"
        echo gtaxllte-linux > "$G/strings/0x409/manufacturer"
        echo "SM-T585 USB serial console" > "$G/strings/0x409/product"
        echo 0001 > "$G/strings/0x409/serialnumber"
        echo ACM > "$G/configs/c.1/strings/0x409/configuration"
        echo 100 > "$G/configs/c.1/MaxPower"
        mkdir -p "$G/functions/acm.gs0" 2>/dev/null
        ln -sf "$G/functions/acm.gs0" "$G/configs/c.1/acm.gs0" 2>/dev/null
    fi
    echo "$UDC" > "$G/UDC" 2>/dev/null || return 1
    return 0
}
rebind() {
    log "rebinding $1 via $2 (reason: $3)"
    echo "" > "$2/UDC" 2>/dev/null
    sleep 2
    echo "$1" > "$2/UDC" 2>/dev/null
    sleep 4
    log "after rebind: state=$(cat "/sys/class/udc/$1/state" 2>/dev/null)"
}
sleep 20
UDC=$(find_udc); G=$(find_gadget)
log "watchdog start udc=${UDC:-none} gadget=${G:-none} rx=$(rx_bytes)"
bad=0; idle=0; delay=15
prev_rx=$(rx_bytes)
while :; do
    sleep "$delay"
    UDC=$(find_udc); G=$(find_gadget)
    if [ -z "$G" ] || [ -z "$(cat "$G/UDC" 2>/dev/null)" ]; then
        if vbus_online; then
            if gadget_up; then log "gadget bound after power appeared"; delay=15; continue; fi
            log "gadget bind failed"
        else
            log "gadget unbound, no VBUS"
        fi
        delay=10
        continue
    fi
    if [ -z "$UDC" ]; then
        # The UDC can vanish from /sys/class/udc entirely - it does when X
        # starts and the USB PHY is re-initialised. A binding left pointing at
        # a UDC that no longer exists can never come back, so drop it, then
        # retry quickly: the old two-minute wait meant no console for minutes.
        if [ -n "$G" ] && [ ! -d "/sys/class/udc/$(cat "$G/UDC" 2>/dev/null)" ]; then
            echo "" > "$G/UDC" 2>/dev/null
            log "stale udc binding cleared"
        fi
        if vbus_online && gadget_up; then log "udc returned, rebound"; delay=15; continue; fi
        log "no udc"
        delay=10
        continue
    fi
    if [ -e /tmp/usb-rebind ]; then rm -f /tmp/usb-rebind; rebind "$UDC" "$G" forced; bad=0; idle=0; delay=15; prev_rx=$(rx_bytes); continue; fi

    rx=$(rx_bytes)
    if [ -n "$rx" ] && [ "$rx" != "$prev_rx" ]; then idle=0; else idle=$((idle + 1)); fi
    [ -n "$rx" ] && prev_rx=$rx

    st=$(cat "/sys/class/udc/$UDC/state" 2>/dev/null)
    if [ "$st" = "configured" ]; then
        [ "$bad" -ne 0 ] && log "healthy again"
        bad=0
        delay=15
        if [ "$idle" -ge 10 ]; then
            rebind "$UDC" "$G" "idle ${idle}p"
            idle=0
            prev_rx=$(rx_bytes)
        fi
        continue
    fi
    bad=$((bad + 1)); log "state=${st:-unknown} bad=$bad"
    if [ "$bad" -ge 3 ]; then rebind "$UDC" "$G" "state=$st"; bad=0; idle=0; delay=15; prev_rx=$(rx_bytes); fi
done
