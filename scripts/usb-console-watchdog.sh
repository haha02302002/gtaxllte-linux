#!/bin/sh
# Keep the USB serial console (ttyGS0 / COM6) alive.
# The gadget wedges after a while: the host still lists the port but opening it
# fails. Re-binding the UDC re-enumerates it, which is what unplugging the cable
# does, without touching the cable. A healthy link sits in state "configured".
# Touch /tmp/usb-rebind to force a re-bind on the next poll.
LOG=/var/log/usb-console.log
mkdir -p /var/log 2>/dev/null
log() { echo "$(date 2>/dev/null) $*" >> "$LOG"; }
find_udc() { for d in /sys/class/udc/*; do [ -e "$d/state" ] || continue; basename "$d"; return 0; done; return 1; }
find_gadget() { for g in /sys/kernel/config/usb_gadget/*; do [ -e "$g/UDC" ] || continue; echo "$g"; return 0; done; return 1; }
rebind() {
    log "rebinding $1 via $2"
    echo "" > "$2/UDC" 2>/dev/null
    sleep 2
    echo "$1" > "$2/UDC" 2>/dev/null
    sleep 4
    log "after rebind: state=$(cat "/sys/class/udc/$1/state" 2>/dev/null)"
}
sleep 20
UDC=$(find_udc); G=$(find_gadget)
log "watchdog start udc=${UDC:-none} gadget=${G:-none}"
bad=0; delay=60
while :; do
    sleep "$delay"
    UDC=$(find_udc); G=$(find_gadget)
    if [ -z "$UDC" ] || [ -z "$G" ]; then log "no udc/gadget"; continue; fi
    if [ -e /tmp/usb-rebind ]; then rm -f /tmp/usb-rebind; rebind "$UDC" "$G"; bad=0; delay=60; continue; fi
    st=$(cat "/sys/class/udc/$UDC/state" 2>/dev/null)
    if [ "$st" = "configured" ]; then [ "$bad" -ne 0 ] && log "healthy again"; bad=0; delay=60; continue; fi
    bad=$((bad + 1)); log "state=${st:-unknown} bad=$bad"
    if [ "$bad" -ge 3 ]; then rebind "$UDC" "$G"; bad=0; delay=300; fi
done
