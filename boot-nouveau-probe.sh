#!/usr/bin/env bash
# Boot this same kernel once with nouveau instead of nvidia-340, so
# `nv-backlight.py --diff` can watch a working /sys/class/backlight and identify the
# panel's backlight register by differencing.
#
# It does NOT show the GRUB menu. On this machine the menu cannot be seen: /etc/grub.d/
# 09_enable_vga's setpci writes run while grub.cfg is parsed, and after them GRUB renders
# into a framebuffer that is no longer scanned out. Making the menu visible here means
# stopping at an *invisible* prompt, and any keypress cancels the countdown and waits
# forever. So the entry is selected in advance instead:
#
#   grub-editenv sets next_entry, which 00_header's generated preamble consumes
#     if [ "${next_entry}" ] ; then set default="${next_entry}" ; set next_entry= ...
#   and clears as it boots.
#
# That makes the selection self-cancelling: the probe entry boots exactly once, and the
# boot after it is the normal one again. If the probe boot fails for any reason, just
# power-cycle -- there is nothing to undo to get back.
#
# Nothing about the nvidia install is touched. The nvidia modules are kept off the PCI
# device for that one boot with modprobe.blacklist= on its kernel line.
#
# The entry boots to runlevel 3 and leaves out quiet/splash: /etc/X11/xorg.conf pins
# Driver "nvidia", so X under nouveau would only fail, and --diff needs a console.
#
#   sudo ./boot-nouveau-probe.sh --arm      # then: sudo reboot
#   sudo ./boot-nouveau-probe.sh --disarm   # remove the entry (and undo any older arm)
#
# Idempotent: safe to re-run.

set -euo pipefail

ENTRY=/etc/grub.d/46_nouveau_probe
GRUB_BAK=/etc/default/grub.nouveau-probe.bak
GRUBENV=/boot/grub/grubenv

log()  { printf '\n== %s\n' "$*"; }
info() { printf '   %s\n' "$*"; }
warn() { printf '   !! %s\n' "$*" >&2; }

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }

MODE=${1:---arm}
KVER=$(uname -r)
TITLE="Linux Mint $KVER (nouveau, backlight probe)"

clear_next_entry() {
    if [ -f "$GRUBENV" ]; then
        grub-editenv "$GRUBENV" unset next_entry 2>/dev/null || true
    fi
}

if [ "$MODE" = --disarm ]; then
    log "Removing the nouveau probe entry"
    rm -f "$ENTRY"
    clear_next_entry
    info "cleared next_entry from $GRUBENV"
    # An earlier version of this script made the menu visible. If that backup is still
    # around, put /etc/default/grub back the way it was.
    if [ -f "$GRUB_BAK" ]; then
        mv "$GRUB_BAK" /etc/default/grub
        info "restored /etc/default/grub from $GRUB_BAK (menu hidden again)"
    fi
    update-grub
    log "Done."
    exit 0
fi

[ "$MODE" = --arm ] || { echo "usage: $0 --arm | --disarm" >&2; exit 1; }

# Reuse what is booted right now rather than guessing: /proc/cmdline carries the root
# spec GRUB itself passed in.
KERNEL=/boot/vmlinuz-$KVER
INITRD=/boot/initrd.img-$KVER
[ -f "$KERNEL" ] || { echo "$KERNEL not found" >&2; exit 1; }
[ -f "$INITRD" ] || { echo "$INITRD not found" >&2; exit 1; }

ROOTSPEC=$(tr ' ' '\n' < /proc/cmdline | grep '^root=' || true)
[ -n "$ROOTSPEC" ] || { echo "no root= in /proc/cmdline" >&2; exit 1; }

# If /boot is its own filesystem, GRUB's paths are relative to it and the UUID to search
# is /boot's, not /'s.
BOOTDEV_UUID=$(findmnt -no UUID --target /boot)
if [ "$(findmnt -no TARGET --target /boot)" = "/boot" ]; then
    PREFIX=""
else
    PREFIX="/boot"
fi

log "Writing $ENTRY"
cat > "$ENTRY" <<EOF
#!/bin/sh
exec tail -n +4 "\$0"
# Written by boot-nouveau-probe.sh -- remove with: $0 --disarm
menuentry '$TITLE' {
    search --no-floppy --fs-uuid --set=root $BOOTDEV_UUID
    linux $PREFIX/vmlinuz-$KVER $ROOTSPEC ro modprobe.blacklist=nvidia,nvidia_uvm,nvidia_drm,nvidia_modeset nouveau.modeset=1 3
    initrd $PREFIX/initrd.img-$KVER
}
EOF
chmod 755 "$ENTRY"
sed 's/^/     /' "$ENTRY"

# Deliberately NOT touching GRUB_TIMEOUT or GRUB_TIMEOUT_STYLE. See the header.
log "update-grub"
update-grub

# Verify the entry really landed before arming next_entry: pointing next_entry at a
# title GRUB does not have would leave it falling back to the default -- harmless, but
# the probe would silently never run.
if ! grep -qF "menuentry '$TITLE'" /boot/grub/grub.cfg; then
    warn "the entry is not in /boot/grub/grub.cfg -- not arming"
    exit 1
fi
info "entry present in /boot/grub/grub.cfg"

log "Selecting it for the next boot only"
grub-editenv "$GRUBENV" set next_entry="$TITLE"
info "next_entry=$TITLE"
grub-editenv "$GRUBENV" list | sed 's/^/     /'

cat <<EOF

Next:
  1. sudo reboot
     No menu, no keys to press. It boots the probe entry by itself, to a text console.
  2. Log in there, then:
       ls /sys/class/backlight/            # expect nv_backlight
       sudo $(cd "$(dirname "$0")" && pwd)/nv-backlight.py --diff
  3. Note the register it reports, then: sudo reboot
     That boot is the normal one again -- next_entry cleared itself.
  4. sudo ./boot-nouveau-probe.sh --disarm

If the probe boot goes wrong, just hold the power button and switch on again. The
selection is one-shot, so the next boot is the normal entry with or without step 4.
EOF
