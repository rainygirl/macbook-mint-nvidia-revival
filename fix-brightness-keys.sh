#!/usr/bin/env bash
# Restore the F1/F2 panel-brightness keys on a MacBook7,1 running Linux Mint 20.3
# after nvidia-340 has replaced nouveau.
#
# The keys themselves never broke. What broke is the thing they act on:
#
#   * Under nouveau the KMS driver registers /sys/class/backlight/nv_backlight, and
#     xfce4-power-manager drives it directly on XF86MonBrightnessUp/Down.
#   * nvidia-340 blacklists nouveau and registers a KMS-less DRM node instead (the same
#     property that makes plymouth's drm renderer fail -- see set-mac-boot-splash.sh).
#     No KMS, no nv_backlight. Nothing else steps in, so the desktop has zero backlight
#     devices and the keypress has nowhere to go.
#   * nvidia-340 *can* expose /sys/class/backlight/nvidia_backlight, but only when the
#     Device section carries RegistryDwords "EnableBrightnessControl=1". Neither the
#     nvidia-340 package nor the xorg.conf that set-mac-boot-splash.sh writes for the
#     LogoPath/NoLogo option includes it.
#   * The kernel's apple_bl also drives this panel (it is the old nvidia-bl, and the
#     GeForce 320M is one of the chipsets it knows), but it only binds when the ACPI
#     video driver has not already claimed the backlight.
#
# So this script, in order:
#   1. reports what is actually there (this part needs no root, use --diagnose),
#   2. adds EnableBrightnessControl to the existing xorg.conf Device section without
#      disturbing the logo options set-mac-boot-splash.sh put there,
#   3. loads apple_bl and makes it persist, as the path that works without restarting X,
#   4. makes the brightness file group-writable via udev, since xfce4-power-manager runs
#      as the user and both nvidia_backlight and apple_backlight are root-only by default,
#   5. installs /usr/local/bin/mac-brightness and binds XF86MonBrightnessUp/Down to it in
#      xfce, for the case where xfce4-power-manager still refuses the device,
#   6. checks hid_apple's fnmode, which decides whether F1 sends XF86MonBrightnessDown at
#      all or just plain F1.
#
# Usage:
#   ./fix-brightness-keys.sh --diagnose     # report only, no root, changes nothing
#   sudo ./fix-brightness-keys.sh           # diagnose, then apply
#   sudo ./fix-brightness-keys.sh --acpi-vendor   # also add acpi_backlight=vendor to GRUB
#   sudo ./fix-brightness-keys.sh --revert
#
# Idempotent: safe to re-run.

set -euo pipefail

XORG=/etc/X11/xorg.conf
XORG_BAK=/etc/X11/xorg.conf.brightness.bak
UDEV_RULE=/etc/udev/rules.d/90-mac-backlight.rules
MODLOAD=/etc/modules-load.d/mac-backlight.conf
HELPER=/usr/local/bin/mac-brightness
GRUB_BAK=/etc/default/grub.brightness.bak

MODE=apply
ACPI_VENDOR=0

while [ $# -gt 0 ]; do
    case "$1" in
        --diagnose|-n) MODE=diagnose ;;
        --revert)      MODE=revert ;;
        --acpi-vendor) ACPI_VENDOR=1 ;;
        -h|--help)     sed -n '2,45p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done

# Read /proc/modules rather than piping lsmod into grep. `grep -q` exits on its first
# match, which SIGPIPEs lsmod (141), and `set -o pipefail` then promotes that to the
# pipeline's status -- so a *successful* match reports failure. Whether it bites depends
# on how far into lsmod's output the match lands, so it fails for modules loaded late in
# boot (nvidia) and not for early ones (video). grep on a file has no pipe and no race.
mod_loaded() { grep -q "^$1 " /proc/modules 2>/dev/null; }
yesno() { if "$@"; then echo yes; else echo no; fi; }

log()  { printf '\n== %s\n' "$*"; }
info() { printf '   %s\n' "$*"; }
warn() { printf '   !! %s\n' "$*" >&2; }

# The desktop session belongs to a user, not to root. xfconf-query and xbindkeys both
# need that user's DISPLAY and session bus, so find them rather than assuming :0/1000.
target_user=""
target_uid=""
find_session_user() {
    local u
    u=$(loginctl list-sessions --no-legend 2>/dev/null \
        | awk '{print $3}' | grep -v '^root$' | head -1 || true)
    if [ -z "$u" ]; then
        u=$(who 2>/dev/null | awk '$2 ~ /^(:|tty7)/ {print $1; exit}' || true)
    fi
    if [ -z "$u" ]; then u=${SUDO_USER:-}; fi
    if [ -z "$u" ]; then return 1; fi
    target_user=$u
    target_uid=$(id -u "$u")
}
as_user() {
    sudo -u "$target_user" \
        DISPLAY="${DISPLAY:-:0}" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$target_uid/bus" \
        "$@"
}

# ------------------------------------------------------------------- 1. diagnose
log "Backlight devices under /sys/class/backlight"
bl_list=$(ls -1 /sys/class/backlight 2>/dev/null || true)
if [ -z "$bl_list" ]; then
    warn "none -- this is the failure. Nothing in userspace can change the brightness."
else
    for d in $bl_list; do
        cur=$(cat "/sys/class/backlight/$d/brightness" 2>/dev/null || echo '?')
        max=$(cat "/sys/class/backlight/$d/max_brightness" 2>/dev/null || echo '?')
        typ=$(cat "/sys/class/backlight/$d/type" 2>/dev/null || echo '?')
        perm=$(stat -c '%A %U:%G' "/sys/class/backlight/$d/brightness" 2>/dev/null || echo '?')
        info "$d  type=$typ  brightness=$cur/$max  $perm"
    done
fi

log "Graphics driver"
if mod_loaded nvidia; then
    info "nvidia module loaded (nouveau's nv_backlight is therefore gone -- expected)"
elif mod_loaded nouveau; then
    info "nouveau loaded -- nv_backlight should exist; if it does not, the panel keys are"
    info "a desktop-side problem, not a driver one"
else
    warn "neither nvidia nor nouveau is loaded"
fi
info "apple_bl loaded: $(yesno mod_loaded apple_bl)"
info "video loaded:    $(yesno mod_loaded video)"

log "xorg.conf brightness option"
if [ ! -f "$XORG" ]; then
    info "$XORG does not exist"
elif grep -qi 'EnableBrightnessControl' "$XORG"; then
    info "EnableBrightnessControl is already set"
else
    info "EnableBrightnessControl is NOT set -- nvidia_backlight will not appear"
fi

log "apple_bl bind status"
# apple_bl_add() drives the panel through the host bridge at 00:00.0 -- which on a
# MacBook7,1 is an NVIDIA MCP89, one of the two vendors it handles -- but it bails out
# with -ENODEV before that if acpi_video_get_backlight_type() != acpi_backlight_vendor,
# logging "Backlight handled by ACPI video driver". acpi_backlight=vendor is what flips
# that decision, and it is what --acpi-vendor adds.
info "host bridge 00:00.0: $(lspci -nn -s 00:00.0 2>/dev/null | sed 's/^[^ ]* //' || echo '?')"
case " $(cat /proc/cmdline) " in
    *" acpi_backlight="*) info "cmdline already has $(tr ' ' '\n' < /proc/cmdline | grep '^acpi_backlight=')" ;;
    *) info "cmdline has no acpi_backlight= (ACPI video wins by default)" ;;
esac
apple_msg=$(dmesg 2>/dev/null | grep -i 'apple_bl' | tail -3 || true)
if [ -n "$apple_msg" ]; then
    printf '%s\n' "$apple_msg" | sed 's/^/     /'
    case "$apple_msg" in
        *"handled by ACPI video"*)
            warn "this is the blocker -- re-run with --acpi-vendor" ;;
        *"unknown hardware"*)
            warn "apple_bl does not recognise this host bridge; --acpi-vendor will not help" ;;
    esac
else
    info "no apple_bl messages in dmesg (module may not have been loaded yet this boot)"
fi

log "nvidia driver brightness support"
NVDRV=$(ls /usr/lib/nvidia-*/xorg/nvidia_drv.so \
           /usr/lib/x86_64-linux-gnu/nvidia/xorg/nvidia_drv.so 2>/dev/null | head -1 || true)
if [ -n "$NVDRV" ] && command -v strings >/dev/null 2>&1; then
    nv_bl=$(strings "$NVDRV" | grep -iE 'EnableBrightnessControl|backlight' | head -5 || true)
    if [ -n "$nv_bl" ]; then
        printf '%s\n' "$nv_bl" | sed 's/^/     /'
    else
        warn "$(basename "$NVDRV") has no brightness/backlight strings"
        warn "-> 340.108 cannot create nvidia_backlight here; apple_bl is the only path"
    fi
else
    info "skipped (nvidia_drv.so or 'strings' not found)"
fi
if [ -f /var/log/Xorg.0.log ]; then
    xlog=$(grep -iE 'RegistryDwords|BrightnessControl|backlight' /var/log/Xorg.0.log 2>/dev/null | head -5 || true)
    if [ -n "$xlog" ]; then
        printf '%s\n' "$xlog" | sed 's/^/     /'
    else
        info "Xorg.0.log mentions neither RegistryDwords nor backlight"
        info "-> the running X server is not acting on the option"
    fi
fi

log "hid_apple fnmode"
fnmode=$(cat /sys/module/hid_apple/parameters/fnmode 2>/dev/null || echo '?')
case "$fnmode" in
    1) info "fnmode=1 (fkeyslast) -- F1/F2 send the brightness keys directly. Correct." ;;
    3) info "fnmode=3 (auto) -- behaves as 1 for a built-in Apple keyboard. Correct." ;;
    2) warn "fnmode=2 (fkeyfirst) -- F1 sends plain F1; brightness needs Fn+F1" ;;
    0) warn "fnmode=0 (disabled) -- F1..F12 are ONLY function keys, no brightness at all" ;;
    *) warn "hid_apple not loaded or fnmode unreadable" ;;
esac
if [ -f /etc/modprobe.d/hid_apple.conf ]; then
    info "note: /etc/modprobe.d/hid_apple.conf exists:"
    sed 's/^/     /' /etc/modprobe.d/hid_apple.conf
fi

log "Key events"
info "To confirm the keys still emit XF86MonBrightnessDown/Up, run as your user:"
info "  xev -event keyboard   # then press F1 and F2"
info "If nothing is printed, it is the keyboard layer (fnmode); if the XF86 keysyms"
info "do appear, it is the backlight device, which is what this script fixes."

if [ "$MODE" = diagnose ]; then
    log "Diagnose only -- nothing changed. Re-run with sudo to apply."
    exit 0
fi

[ "$(id -u)" -eq 0 ] || { echo "run as root (or use --diagnose)" >&2; exit 1; }

# --------------------------------------------------------------------- revert
if [ "$MODE" = revert ]; then
    log "Reverting"
    if [ -f "$XORG_BAK" ]; then
        mv "$XORG_BAK" "$XORG"
        info "restored $XORG"
    elif [ -f "$XORG" ]; then
        # Remove only the line this script added, leaving the logo options alone.
        sed -i '/EnableBrightnessControl/d' "$XORG"
        info "removed the EnableBrightnessControl line from $XORG"
    fi
    rm -f "$UDEV_RULE" "$MODLOAD" "$HELPER"
    info "removed $UDEV_RULE $MODLOAD $HELPER"
    if [ -f "$GRUB_BAK" ]; then
        mv "$GRUB_BAK" /etc/default/grub
        update-grub
        info "restored /etc/default/grub"
    fi
    if find_session_user; then
        for k in XF86MonBrightnessUp XF86MonBrightnessDown; do
            as_user xfconf-query -c xfce4-keyboard-shortcuts \
                -p "/commands/custom/$k" -r 2>/dev/null || true
        done
        info "removed the xfce shortcut overrides for $target_user"
    fi
    udevadm control --reload-rules 2>/dev/null || true
    log "Reverted. Reboot to drop apple_bl and the xorg.conf change."
    exit 0
fi

# ------------------------------------------------- 2. xorg.conf EnableBrightnessControl
# 340.108 gates the nvidia_backlight sysfs node behind this RegistryDwords bit. It has to
# live in the Device section that the active Screen points at -- a second Device section
# is demoted to GPUDevice and its options are never read, which is the same trap
# set-mac-boot-splash.sh documents for LogoPath.
log "xorg.conf: EnableBrightnessControl"
if [ ! -f "$XORG" ]; then
    warn "$XORG does not exist -- creating a minimal one"
    mkdir -p /etc/X11
    cat > "$XORG" <<'EOF'
# Written by fix-brightness-keys.sh
Section "ServerLayout"
    Identifier  "MacBook Layout"
    Screen  0   "MacBook Screen" 0 0
EndSection

Section "Device"
    Identifier  "MacBook NVIDIA"
    Driver      "nvidia"
    VendorName  "NVIDIA Corporation"
    Option      "RegistryDwords" "EnableBrightnessControl=1"
EndSection

Section "Screen"
    Identifier   "MacBook Screen"
    Device       "MacBook NVIDIA"
    DefaultDepth 24
EndSection
EOF
    info "created $XORG"
elif grep -qi 'EnableBrightnessControl' "$XORG"; then
    info "already present, leaving $XORG alone"
else
    cp -n "$XORG" "$XORG_BAK"
    info "backed up -> $XORG_BAK"
    if grep -qi '"RegistryDwords"' "$XORG"; then
        # An existing RegistryDwords string holds a semicolon-separated list; append to it
        # rather than adding a second Option line, which the driver would ignore.
        sed -i 's/\(Option[[:space:]]*"RegistryDwords"[[:space:]]*"\)\([^"]*\)"/\1\2;EnableBrightnessControl=1"/I' "$XORG"
        info "appended EnableBrightnessControl to the existing RegistryDwords"
    else
        # Insert into the Device section the *Screen* actually uses. Picking the first
        # Device section is not good enough: the nvidia-340 package's own "Nvidia Card"
        # often comes first and is demoted to GPUDevice, so an option placed there is
        # never read -- the same trap set-mac-boot-splash.sh documents for LogoPath.
        dev=$(awk '/^[[:space:]]*Section[[:space:]]+"Screen"/,/^[[:space:]]*EndSection/' "$XORG" \
              | awk '/^[[:space:]]*Device[[:space:]]+"/ {print; exit}' \
              | sed 's/.*"\(.*\)".*/\1/')
        # awk rather than `sed a\`, whose handling of leading whitespace in the appended
        # text differs between implementations.
        if [ -n "$dev" ] && grep -q "Identifier[[:space:]]*\"$dev\"" "$XORG"; then
            awk -v id="$dev" '
                { print }
                !done && $0 ~ ("Identifier[ \t]*\"" id "\"") {
                    print "    Option      \"RegistryDwords\" \"EnableBrightnessControl=1\""
                    done = 1
                }' "$XORG" > "$XORG.tmp" && mv "$XORG.tmp" "$XORG"
            info "added to Device \"$dev\" (the one Screen references)"
        elif grep -q '^[[:space:]]*Section[[:space:]]*"Device"' "$XORG"; then
            awk '
                { print }
                !done && $0 ~ /^[ \t]*Section[ \t]*"Device"/ {
                    print "    Option      \"RegistryDwords\" \"EnableBrightnessControl=1\""
                    done = 1
                }' "$XORG" > "$XORG.tmp" && mv "$XORG.tmp" "$XORG"
            info "added to the first Device section"
        else
            warn "no Device section found in $XORG -- skipping"
        fi
    fi
fi

# ------------------------------------------------------------------- 3. apple_bl
# apple_bl is the in-tree successor to nvidia-bl and pokes the 320M's backlight registers
# over mmio, independently of whatever X driver owns the GPU. It takes effect immediately,
# so it is the path that works before the next X restart.
log "apple_bl"
if modprobe apple_bl 2>/dev/null; then
    if [ -e /sys/class/backlight/apple_backlight ]; then
        info "loaded, /sys/class/backlight/apple_backlight is present"
    else
        info "loaded but registered no device (ACPI video likely holds the backlight)"
        info "if no other device appears, re-run with --acpi-vendor"
    fi
else
    info "not available on this kernel -- relying on nvidia_backlight instead"
fi
mkdir -p "$(dirname "$MODLOAD")"
printf 'apple_bl\n' > "$MODLOAD"
info "$MODLOAD written (loads on every boot)"

# -------------------------------------------------------------- 4. udev permissions
# Both nvidia_backlight and apple_backlight come up 0644 root:root. xfce4-power-manager
# and the helper below run as the user, so without this every write is EACCES and the key
# silently does nothing -- which looks exactly like a dead key.
log "udev rule for backlight write permission"
cat > "$UDEV_RULE" <<'EOF'
# Written by fix-brightness-keys.sh
ACTION=="add", SUBSYSTEM=="backlight", RUN+="/bin/chgrp video /sys/class/backlight/%k/brightness"
ACTION=="add", SUBSYSTEM=="backlight", RUN+="/bin/chmod g+w /sys/class/backlight/%k/brightness"
EOF
info "$UDEV_RULE"
udevadm control --reload-rules
udevadm trigger --subsystem-match=backlight
# The rule only fires on add, so fix whatever is already present in this boot.
for d in /sys/class/backlight/*/; do
    [ -e "$d/brightness" ] || continue
    chgrp video "$d/brightness" 2>/dev/null || true
    chmod g+w "$d/brightness" 2>/dev/null || true
done
if find_session_user; then
    # Same pipefail/SIGPIPE trap as mod_loaded: no pipe, just a substring test.
    case " $(id -nG "$target_user") " in
        *" video "*) info "$target_user is already in the 'video' group" ;;
        *) usermod -aG video "$target_user"
           info "added $target_user to the 'video' group (takes effect at next login)" ;;
    esac
fi

# ------------------------------------------------------------------ 5. helper + keys
log "Brightness helper"
cat > "$HELPER" <<'EOF'
#!/bin/sh
# mac-brightness up|down|get [percent-step]
# Writes /sys/class/backlight/<dev>/brightness directly. Picks the first device that is
# not acpi_video* -- on this machine acpi_video0, when it exists at all, is a stub that
# accepts writes and changes nothing.
set -eu
step_pct=${2:-10}
dev=""
for d in /sys/class/backlight/*; do
    [ -e "$d/brightness" ] || continue
    case "${d##*/}" in acpi_video*) continue ;; esac
    dev=$d; break
done
[ -n "$dev" ] || { for d in /sys/class/backlight/*; do [ -e "$d/brightness" ] && dev=$d && break; done; }
[ -n "$dev" ] || { echo "no backlight device" >&2; exit 1; }

max=$(cat "$dev/max_brightness")
cur=$(cat "$dev/brightness")
step=$(( max * step_pct / 100 ))
[ "$step" -lt 1 ] && step=1

case "${1:-get}" in
    up)   new=$(( cur + step )) ;;
    down) new=$(( cur - step )) ;;
    get)  echo "$(( cur * 100 / max ))%"; exit 0 ;;
    *)    echo "usage: mac-brightness up|down|get [percent-step]" >&2; exit 1 ;;
esac

[ "$new" -gt "$max" ] && new=$max
# Zero is a black panel with no way back except this same key, so stop one step above it.
[ "$new" -lt 1 ] && new=1
echo "$new" > "$dev/brightness"
EOF
chmod 755 "$HELPER"
info "$HELPER"

log "xfce key bindings"
if find_session_user; then
    info "session user: $target_user (uid $target_uid)"
    # xfce4-power-manager handles these keys itself when it finds a usable device, and its
    # own handler wins over a custom shortcut. Bind the helper anyway: if xfpm does take
    # the key these bindings are inert, and if it does not they are the whole fix.
    if as_user xfconf-query -c xfce4-keyboard-shortcuts -l >/dev/null 2>&1; then
        as_user xfconf-query -c xfce4-keyboard-shortcuts \
            -p /commands/custom/XF86MonBrightnessDown -n -t string -s "$HELPER down" 2>/dev/null \
        || as_user xfconf-query -c xfce4-keyboard-shortcuts \
            -p /commands/custom/XF86MonBrightnessDown -s "$HELPER down"
        as_user xfconf-query -c xfce4-keyboard-shortcuts \
            -p /commands/custom/XF86MonBrightnessUp -n -t string -s "$HELPER up" 2>/dev/null \
        || as_user xfconf-query -c xfce4-keyboard-shortcuts \
            -p /commands/custom/XF86MonBrightnessUp -s "$HELPER up"
        info "bound XF86MonBrightnessUp/Down -> $HELPER"
    else
        warn "xfconf-query could not reach $target_user's session bus"
        warn "bind them by hand: Settings > Keyboard > Application Shortcuts"
        warn "  $HELPER down   -> XF86MonBrightnessDown"
        warn "  $HELPER up     -> XF86MonBrightnessUp"
    fi
else
    warn "no graphical session found -- skipping the xfce bindings"
    warn "re-run this script from inside your desktop session to set them"
fi

# ------------------------------------------------------------------- 6. fnmode
log "hid_apple fnmode"
fnmode=$(cat /sys/module/hid_apple/parameters/fnmode 2>/dev/null || echo '?')
if [ "$fnmode" = 0 ] || [ "$fnmode" = 2 ]; then
    warn "fnmode=$fnmode makes F1/F2 plain function keys. Setting fnmode=1."
    printf 'options hid_apple fnmode=1\n' > /etc/modprobe.d/hid_apple.conf
    echo 1 > /sys/module/hid_apple/parameters/fnmode 2>/dev/null || true
    update-initramfs -u
    info "/etc/modprobe.d/hid_apple.conf written and initramfs rebuilt"
else
    info "fnmode=$fnmode is correct, leaving it alone"
fi

# --------------------------------------------------------------- 7. acpi_backlight
if [ "$ACPI_VENDOR" = 1 ]; then
    log "GRUB: acpi_backlight=vendor"
    [ -f "$GRUB_BAK" ] || cp /etc/default/grub "$GRUB_BAK"
    old=$(sed -n 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"$/\1/p' /etc/default/grub | head -1)
    keep=""
    for tok in $old; do
        case "$tok" in acpi_backlight=*) ;; *) keep="${keep:+$keep }$tok" ;; esac
    done
    sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"${keep:+$keep }acpi_backlight=vendor\"|" /etc/default/grub
    info "GRUB_CMDLINE_LINUX_DEFAULT=\"${keep:+$keep }acpi_backlight=vendor\""
    # set-mac-boot-splash.sh rebuilds only its own tokens and keeps the rest, so this
    # survives a later re-run of that script.
    update-grub
fi

# -------------------------------------------------------------------- 8. report
log "Result"
bl_list=$(ls -1 /sys/class/backlight 2>/dev/null || true)
if [ -z "$bl_list" ]; then
    warn "still no backlight device in this boot."
    warn "nvidia_backlight only appears after the X server restarts with the new"
    warn "xorg.conf, so log out and back in (or reboot) and run --diagnose again."
else
    for d in $bl_list; do
        info "$d  $(stat -c '%A %U:%G' "/sys/class/backlight/$d/brightness")"
    done
    info "test now:  $HELPER down   then   $HELPER up"
fi

cat <<EOF

Next:
  1. Reboot (the xorg.conf change needs a new X server; apple_bl and the udev rule are
     already live, so if a device is listed above the keys may work right away).
  2. Press F1 / F2.
  3. Still nothing -> ./fix-brightness-keys.sh --diagnose and read the first section.
     No device listed there and apple_bl loaded -> sudo ./fix-brightness-keys.sh --acpi-vendor
  4. Undo everything: sudo ./fix-brightness-keys.sh --revert
EOF
