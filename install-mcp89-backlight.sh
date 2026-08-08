#!/usr/bin/env bash
# Install the mcp89-backlight DKMS module and undo the approaches that turned out not to
# work on this machine.
#
# End state: /sys/class/backlight/mcp89_backlight exists, so xfce4-power-manager drives
# F1/F2 itself, exactly as it did with nouveau's nv_backlight. No custom key bindings and
# no userspace helper are involved.
#
# What it removes, and why (all of it was tried and disproved on this machine):
#
#   xorg.conf RegistryDwords EnableBrightnessControl=1
#       340.108 has no such key. nvidia_drv.so carries "Unable to find the brightness
#       file path under" and "EnableACPIBrightnessHotkeys" -- it *reads* a backlight, it
#       never creates one. Xorg.0.log's "(**)" only means the option was specified.
#   acpi_backlight=vendor on the kernel command line
#       Added to let apple_bl win over ACPI video. apple_bl never got that far: it binds
#       APP0002 but bails out of apple_bl_add() at its live-hardware check on I/O port
#       0x52f, silently, which its own comment attributes to EFI booting.
#   apple_bl in /etc/modules-load.d
#       Loads and registers nothing, for the reason above.
#   /usr/local/bin/mac-brightness and the xfce XF86MonBrightness bindings
#       A stand-in for a missing backlight device. With a real one, xfce4-power-manager
#       handles the keys and a custom binding would only fight it.
#
#   sudo ./install-mcp89-backlight.sh
#   sudo ./install-mcp89-backlight.sh --uninstall
#
# Idempotent: safe to re-run.

set -euo pipefail

NAME=mcp89-backlight
VER=1.0
MOD=mcp89_backlight
SRC=/usr/src/$NAME-$VER
HERE=$(cd "$(dirname "$0")" && pwd)
UDEV_RULE=/etc/udev/rules.d/90-mac-backlight.rules
MODLOAD=/etc/modules-load.d/mac-backlight.conf

log()  { printf '\n== %s\n' "$*"; }
info() { printf '   %s\n' "$*"; }
warn() { printf '   !! %s\n' "$*" >&2; }

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }

if [ "${1:-}" = --uninstall ]; then
    log "Removing the module"
    modprobe -r "$MOD" 2>/dev/null || true
    dkms remove -m "$NAME" -v "$VER" --all 2>/dev/null || true
    rm -rf "$SRC" "$UDEV_RULE" "$MODLOAD"
    update-initramfs -u
    log "Done."
    exit 0
fi

# ------------------------------------------------------- 1. undo the dead ends
log "Undoing the earlier attempts"
if [ -x "$HERE/fix-brightness-keys.sh" ]; then
    # --revert restores xorg.conf, drops acpi_backlight=vendor from GRUB, removes the
    # apple_bl autoload, the helper and the xfce bindings. Run it before installing, so
    # it cannot remove anything added below.
    "$HERE/fix-brightness-keys.sh" --revert
else
    warn "fix-brightness-keys.sh not found next to this script; skipping the revert"
fi

# ------------------------------------------------------------ 2. prerequisites
log "Prerequisites"
missing=""
command -v dkms >/dev/null 2>&1 || missing="$missing dkms"
[ -d "/lib/modules/$(uname -r)/build" ] || missing="$missing linux-headers-$(uname -r)"
if [ -n "$missing" ]; then
    info "installing:$missing"
    apt-get update
    # shellcheck disable=SC2086
    apt-get install -y $missing
fi
info "dkms $(dkms --version 2>/dev/null | head -1)"
info "headers: /lib/modules/$(uname -r)/build"

# --------------------------------------------------------------- 3. dkms build
log "Installing the source at $SRC"
rm -rf "$SRC"
mkdir -p "$SRC"
cp "$HERE/$NAME/mcp89_backlight.c" "$HERE/$NAME/Makefile" "$HERE/$NAME/dkms.conf" "$SRC/"
info "$(ls "$SRC" | tr '\n' ' ')"

log "dkms add / build / install"
dkms remove -m "$NAME" -v "$VER" --all 2>/dev/null || true
dkms add -m "$NAME" -v "$VER"
dkms build -m "$NAME" -v "$VER"
dkms install -m "$NAME" -v "$VER"
dkms status -m "$NAME"

# ------------------------------------------------------------------- 4. load it
log "Loading $MOD"
modprobe -r "$MOD" 2>/dev/null || true
if ! modprobe "$MOD"; then
    warn "modprobe failed"
    dmesg | grep -i mcp89 | tail -5 || true
    exit 1
fi
dmesg | grep -i mcp89_backlight | tail -5 | sed 's/^/     /' || true

mkdir -p "$(dirname "$MODLOAD")"
printf '%s\n' "$MOD" > "$MODLOAD"
info "$MODLOAD written (loads on every boot)"

# ------------------------------------------------- 5. permissions for the desktop
# Kept from the earlier script: the class device comes up 0644 root:root, and a write
# that fails with EACCES is indistinguishable from a dead key.
log "udev rule for backlight write permission"
cat > "$UDEV_RULE" <<'EOF'
# Written by install-mcp89-backlight.sh
ACTION=="add", SUBSYSTEM=="backlight", RUN+="/bin/chgrp video /sys/class/backlight/%k/brightness"
ACTION=="add", SUBSYSTEM=="backlight", RUN+="/bin/chmod g+w /sys/class/backlight/%k/brightness"
EOF
udevadm control --reload-rules
udevadm trigger --subsystem-match=backlight
for d in /sys/class/backlight/*/; do
    [ -e "$d/brightness" ] || continue
    chgrp video "$d/brightness" 2>/dev/null || true
    chmod g+w "$d/brightness" 2>/dev/null || true
done
info "$UDEV_RULE"

# --------------------------------------------------------------------- 6. report
log "Result"
if [ -e /sys/class/backlight/$MOD/brightness ]; then
    b=$(cat /sys/class/backlight/$MOD/brightness)
    m=$(cat /sys/class/backlight/$MOD/max_brightness)
    info "/sys/class/backlight/$MOD  brightness=$b/$m"
    info "$(stat -c '%A %U:%G' /sys/class/backlight/$MOD/brightness)"
else
    warn "no /sys/class/backlight/$MOD -- check: dmesg | grep mcp89"
    exit 1
fi

cat <<EOF

Test it without touching the keys:
  echo 40 | sudo tee /sys/class/backlight/$MOD/brightness
  echo 90 | sudo tee /sys/class/backlight/$MOD/brightness

Then log out and back in (xfce4-power-manager looks for backlight devices when it
starts) and press F1 / F2.

The module rebuilds itself on kernel updates -- AUTOINSTALL is set in dkms.conf, the
same mechanism nvidia-340 uses.

Undo: sudo ./install-mcp89-backlight.sh --uninstall
EOF
