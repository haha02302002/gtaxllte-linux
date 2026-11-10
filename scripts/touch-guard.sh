#!/bin/sh
# touch-guard - keep the sec_touchscreen input device alive.
#
# On this tablet the touch controller can fall off the i2c bus when the panel
# is touched while the driver is still probing: the input node vanishes a few
# seconds after boot and the screen stays dead until the driver is rebound.
# Nothing in userspace can stop the early touch from arriving, but the driver
# can be put back, which is what this guard does.
#
# It runs from driver-check, before X starts, so it is already watching during
# the window where the device disappears.

TSP_NAME=sec_touchscreen
LOG=/tmp/touch-guard.log
CLIENT=""
DRIVER=""

log() { echo "$*" >> "$LOG"; }

# event node -> i2c client name (e.g. 3-0020) and its driver name
resolve() {
    for d in /sys/class/input/event*/device; do
        [ -e "$d" ] || continue
        real=$(readlink -f "$d" 2>/dev/null) || continue
        name=$(cat "$d/name" 2>/dev/null)
        [ "$name" = "$TSP_NAME" ] || continue
        # .../i2c-3/3-0020/input/input5 -> strip input/input5
        cl=$(dirname "$(dirname "$real")")
        CLIENT=$(basename "$cl")
        dr=$(readlink -f "$cl/driver" 2>/dev/null)
        DRIVER=$(basename "${dr:-unknown}")
        return 0
    done
    return 1
}

present() {
    for f in /sys/class/input/event*/device/name; do
        [ -r "$f" ] || continue
        [ "$(cat "$f" 2>/dev/null)" = "$TSP_NAME" ] && return 0
    done
    return 1
}

rebind() {
    [ -n "$CLIENT" ] || return 1
    [ -n "$DRIVER" ] && [ "$DRIVER" != unknown ] || return 1
    b=/sys/bus/i2c/drivers/$DRIVER
    [ -d "$b" ] || return 1
    echo "$CLIENT" > "$b/unbind" 2>/dev/null
    sleep 1
    echo "$CLIENT" > "$b/bind" 2>/dev/null
    sleep 1
    present
}

i=0
while [ "$i" -lt 100 ]; do          # look for the device for the first 50 s
    resolve && break
    sleep 0.5
    i=$((i + 1))
done
log "guard start client=${CLIENT:-none} driver=${DRIVER:-none}"

miss=0
while :; do
    sleep 2
    if present; then
        miss=0
        continue
    fi
    miss=$((miss + 1))
    # The driver needs a moment after probe to settle; only act once the node
    # has really gone, otherwise a startup blip makes us unbind a good device.
    [ "$miss" -lt 2 ] && continue
    if [ -z "$CLIENT" ]; then resolve || true; fi
    log "touchscreen missing, rebinding ${CLIENT:-?}/${DRIVER:-?}"
    if rebind; then
        log "touchscreen back"
        miss=0
    else
        log "rebind failed"
        miss=0
    fi
done
