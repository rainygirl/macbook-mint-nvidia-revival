#!/usr/bin/env bash
# Make the panel switch off after an idle period on Linux Mint Xfce.
#
# Diagnoses before it changes anything, because "the screen never turns off" has several
# independent causes and they need different fixes:
#
#   * X has no DPMS extension, or DPMS is disabled -- nothing can blank the output.
#   * DPMS is on but every timeout is 0, which means "never".
#   * xfce4-power-manager owns these timeouts and rewrites whatever `xset` sets, so
#     configuring xset alone looks like it works and then silently reverts.
#   * Presentation mode, or an application inhibitor, suppresses blanking entirely.
#
# --test forces DPMS off right now. That separates "the driver cannot blank this panel"
# from "the idle timer never fires", which no amount of reading settings can.
#
#   ./fix-screen-blank.sh --diagnose            # no root, changes nothing
#   ./fix-screen-blank.sh --test                # blank now; move the mouse to come back
#   sudo ./fix-screen-blank.sh --minutes 10
#
# Idempotent: safe to re-run.

set -euo pipefail

MINUTES=10
MODE=apply

while [ $# -gt 0 ]; do
    case "$1" in
        --diagnose|-n) MODE=diagnose ;;
        --test)        MODE=test ;;
        --minutes)     MINUTES=${2:?--minutes needs a value}; shift ;;
        -h|--help)     sed -n '2,22p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done

log()  { printf '\n== %s\n' "$*"; }
info() { printf '   %s\n' "$*"; }
warn() { printf '   !! %s\n' "$*" >&2; }

# xset and xfconf-query only mean anything inside the desktop session. When this runs
# under sudo, root has neither DISPLAY nor the session bus, so both are borrowed from
# the logged-in user rather than assumed to be :0/1000.
target_user=""
target_uid=""
find_session_user() {
    local u
    u=$(loginctl list-sessions --no-legend 2>/dev/null \
        | awk '{print $3}' | grep -v '^root$' | head -1 || true)
    if [ -z "$u" ]; then u=${SUDO_USER:-}; fi
    if [ -z "$u" ]; then u=$(id -un); fi
    if [ -z "$u" ]; then return 1; fi
    target_user=$u
    target_uid=$(id -u "$u")
}
find_session_user || { echo "cannot determine the desktop user" >&2; exit 1; }

as_user() {
    if [ "$(id -un)" = "$target_user" ]; then
        DISPLAY="${DISPLAY:-:0}" "$@"
    else
        sudo -u "$target_user" \
            DISPLAY="${DISPLAY:-:0}" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$target_uid/bus" \
            "$@"
    fi
}

xfconf() { as_user xfconf-query -c xfce4-power-manager "$@"; }

xfconf_set() {   # property type value
    if xfconf -p "$1" >/dev/null 2>&1; then
        xfconf -p "$1" -s "$3"
    else
        xfconf -p "$1" -n -t "$2" -s "$3"
    fi
    info "$1 = $3"
}

# ------------------------------------------------------------------- diagnose
log "Session"
info "user $target_user (uid $target_uid), DISPLAY=${DISPLAY:-:0}"

log "X DPMS state (xset q)"
if xq=$(as_user xset q 2>&1); then
    printf '%s\n' "$xq" | sed -n '/Screen Saver/,/^$/p' | sed 's/^/     /'
    printf '%s\n' "$xq" | sed -n '/DPMS/,$p' | sed 's/^/     /'
    # No `printf | grep -q`: grep -q exits on its first match, SIGPIPEs the writer, and
    # `set -o pipefail` then reports the whole pipeline as failed even though it matched.
    case "$xq" in
        *"DPMS is Disabled"*)
            warn "DPMS is Disabled -- the output can never be powered down" ;;
    esac
else
    warn "xset failed: $xq"
    warn "run this from inside the desktop session"
fi

log "xfce4-power-manager settings"
if as_user xfconf-query -c xfce4-power-manager -l >/dev/null 2>&1; then
    as_user xfconf-query -c xfce4-power-manager -lv 2>/dev/null \
        | grep -E 'dpms|blank|presentation' | sed 's/^/     /' \
        || info "(no dpms/blank properties set yet -- defaults are in use)"
else
    warn "cannot reach $target_user's xfconf; is the Xfce session running?"
fi

log "Idle/blanking daemons"
running_xscreensaver=0
for p in xfce4-power-manager xfce4-screensaver light-locker xscreensaver; do
    # The kernel truncates comm to 15 characters, so "xfce4-power-manager" appears as
    # "xfce4-power-man" and a pgrep -x on the full name misses a process that is running.
    if pgrep -u "$target_user" -x "$(printf '%.15s' "$p")" >/dev/null 2>&1; then
        info "$p: running"
        [ "$p" = xscreensaver ] && running_xscreensaver=1
    elif command -v "$p" >/dev/null 2>&1; then
        info "$p: installed, not running"
    fi
done
if [ "$running_xscreensaver" = 1 ]; then
    xsconf=$(getent passwd "$target_user" | cut -d: -f6)/.xscreensaver
    info ""
    info "xscreensaver manages blanking itself and turns the X DPMS extension off"
    info "whenever its own dpmsEnabled is False -- that is what disables DPMS here."
    if [ -f "$xsconf" ]; then
        grep -E '^(timeout|lock|mode|dpms)' "$xsconf" | sed 's/^/     /' || true
    else
        info "$xsconf does not exist yet (built-in defaults, dpmsEnabled off)"
    fi
fi

log "Inhibitors"
if command -v systemd-inhibit >/dev/null 2>&1; then
    systemd-inhibit --list 2>/dev/null | sed 's/^/     /' | head -20 \
        || info "none"
fi

if [ "$MODE" = diagnose ]; then
    log "Diagnose only -- nothing changed."
    info "Next: ./fix-screen-blank.sh --test   (blanks immediately, proves DPMS works)"
    exit 0
fi

# ----------------------------------------------------------------------- test
if [ "$MODE" = test ]; then
    log "Forcing DPMS off in 3 seconds"
    info "the panel should go dark; move the mouse or press a key to bring it back"
    sleep 3
    as_user xset dpms force off
    sleep 5
    as_user xset dpms force on || true
    log "If the panel went dark, DPMS works and only the idle timeout was wrong."
    info "If it stayed lit, the driver is not blanking this output -- report that."
    exit 0
fi

# ---------------------------------------------------------------------- apply
SLEEP_MIN=$MINUTES
OFF_MIN=$((MINUTES + 1))

hms() {   # minutes -> H:MM:SS, the format xscreensaver's config uses
    printf '%d:%02d:00' $(($1 / 60)) $(($1 % 60))
}

# xscreensaver first: it is the one that ran `xset -dpms`, and anything set below would
# be undone the next time it reapplies its own preferences.
if [ "$running_xscreensaver" = 1 ]; then
    log "xscreensaver: enabling DPMS in its own config"
    xshome=$(getent passwd "$target_user" | cut -d: -f6)
    xsconf=$xshome/.xscreensaver
    [ -f "$xsconf" ] || { : > "$xsconf"; chown "$target_user": "$xsconf"; }
    cp -n "$xsconf" "$xsconf.bak" 2>/dev/null || true

    xs_set() {   # key value
        if grep -qE "^$1:" "$xsconf"; then
            sed -i "s|^$1:.*|$1:\t$2|" "$xsconf"
        else
            printf '%s:\t%s\n' "$1" "$2" >> "$xsconf"
        fi
        info "$1 = $2"
    }
    xs_set timeout      "$(hms "$SLEEP_MIN")"
    xs_set dpmsEnabled  True
    xs_set dpmsStandby  "$(hms "$SLEEP_MIN")"
    xs_set dpmsSuspend  "$(hms "$SLEEP_MIN")"
    xs_set dpmsOff      "$(hms "$OFF_MIN")"
    chown "$target_user": "$xsconf"

    # It only re-reads preferences on restart.
    as_user xscreensaver-command -restart >/dev/null 2>&1 \
        || info "could not restart xscreensaver; log out and back in to apply"
fi

log "Setting the idle timeouts to $MINUTES minutes"
xfconf_set /xfce4-power-manager/dpms-enabled           bool  true
xfconf_set /xfce4-power-manager/dpms-on-ac-sleep       uint  "$SLEEP_MIN"
xfconf_set /xfce4-power-manager/dpms-on-ac-off         uint  "$OFF_MIN"
xfconf_set /xfce4-power-manager/dpms-on-battery-sleep  uint  "$SLEEP_MIN"
xfconf_set /xfce4-power-manager/dpms-on-battery-off    uint  "$OFF_MIN"
# blank-* is the screensaver's own blank, ahead of DPMS. 0 means never.
xfconf_set /xfce4-power-manager/blank-on-ac            uint  "$SLEEP_MIN"
xfconf_set /xfce4-power-manager/blank-on-battery       uint  "$SLEEP_MIN"
# Presentation mode suppresses all of the above and is easy to leave on by accident.
xfconf_set /xfce4-power-manager/presentation-mode      bool  false

# Turn the extension back on and seed the timers now, so this takes effect without
# waiting for either daemon to reapply its settings.
log "Re-enabling DPMS on the running server"
as_user xset +dpms
as_user xset dpms $((SLEEP_MIN * 60)) $((SLEEP_MIN * 60)) $((OFF_MIN * 60))
as_user xset s $((SLEEP_MIN * 60)) $((SLEEP_MIN * 60))

log "Result (xset q)"
as_user xset q 2>/dev/null | sed -n '/DPMS/,$p' | sed 's/^/     /' || true

cat <<EOF

Set to: standby/suspend at $SLEEP_MIN min, off at $OFF_MIN min, on AC and on battery.

Verify without waiting:
  ./fix-screen-blank.sh --test

xfce4-power-manager applies these live; no logout needed. If the panel still never
blanks on its own, the timer is being reset by an inhibitor -- check the "Inhibitors"
section above, and Settings > Power Manager > "Presentation mode".
EOF
