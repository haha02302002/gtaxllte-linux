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
bad=0; idle=0; delay=60
prev_rx=$(rx_bytes)
while :; do
    sleep "$delay"
    UDC=$(find_udc); G=$(find_gadget)
    if [ -z "$UDC" ] || [ -z "$G" ]; then log "no udc/gadget"; continue; fi
    if [ -e /tmp/usb-rebind ]; then rm -f /tmp/usb-rebind; rebind "$UDC" "$G" forced; bad=0; idle=0; delay=60; prev_rx=$(rx_bytes); continue; fi

    rx=$(rx_bytes)
    if [ -n "$rx" ] && [ "$rx" != "$prev_rx" ]; then idle=0; else idle=$((idle + 1)); fi
    [ -n "$rx" ] && prev_rx=$rx

    st=$(cat "/sys/class/udc/$UDC/state" 2>/dev/null)
    if [ "$st" = "configured" ]; then
        [ "$bad" -ne 0 ] && log "healthy again"
        bad=0
        delay=60
        if [ "$idle" -ge 10 ]; then
            rebind "$UDC" "$G" "idle ${idle}p"
            idle=0
            prev_rx=$(rx_bytes)
        fi
        continue
    fi
    bad=$((bad + 1)); log "state=${st:-unknown} bad=$bad"
    if [ "$bad" -ge 3 ]; then rebind "$UDC" "$G" "state=$st"; bad=0; idle=0; delay=300; prev_rx=$(rx_bytes); fi
done
