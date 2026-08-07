#!/usr/bin/env bash
# Add a GRUB entry that boots this same kernel with nouveau instead of nvidia-340, so
# `nv-backlight.py --diff` can watch a working /sys/class/backlight and identify the
# panel's backlight register by differencing.
#
# Nothing about the nvidia install is touched. The nvidia modules are kept out of the
# way for one boot with modprobe.blacklist= on that entry's kernel line, which leaves
# the PCI device free for nouveau. Booting the normal entry afterwards is unchanged.
#
# The entry also asks for runlevel 3. /etc/X11/xorg.conf pins Driver "nvidia", so
# letting X start under nouveau would just fail; the console is all --diff needs, and
# it keeps a failed X server out of the picture.
#
#   sudo ./boot-nouveau-probe.sh --arm      # add the entry, show the menu, then reboot
#   sudo ./boot-nouveau-probe.sh --disarm   # remove it and restore the hidden menu
#
# Idempotent: safe to re-run.

set -euo pipefail

ENTRY=/etc/grub.d/46_nouveau_probe
GRUB_BAK=/etc/default/grub.nouveau-probe.bak

log()  { printf '\n== %s\n' "$*"; }
info() { printf '   %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }

MODE=${1:---arm}

set_grub() {
    if grep -qE "^[#]?$1=" /etc/default/grub; then
        sed -i "s|^[#]\?$1=.*|$1=$2|" /etc/default/grub
    else
        printf '%s=%s\n' "$1" "$2" >> /etc/default/grub
    fi
}

if [ "$MODE" = --disarm ]; then
    log "Removing the nouveau probe entry"
    rm -f "$ENTRY"
    if [ -f "$GRUB_BAK" ]; then
        mv "$GRUB_BAK" /etc/default/grub
        info "restored /etc/default/grub (hidden menu, timeout 0)"
    fi
    update-grub
    log "Done. The next boot goes straight to the normal entry again."
    exit 0
fi

[ "$MODE" = --arm ] || { echo "usage: $0 --arm | --disarm" >&2; exit 1; }

# Reuse exactly what is booted now rather than guessing paths: /proc/cmdline carries the
# kernel image and the root spec that GRUB itself passed in.
KVER=$(uname -r)
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
menuentry 'Linux Mint $KVER (nouveau, backlight probe)' {
    search --no-floppy --fs-uuid --set=root $BOOTDEV_UUID
    linux $PREFIX/vmlinuz-$KVER $ROOTSPEC ro modprobe.blacklist=nvidia,nvidia_uvm,nvidia_drm,nvidia_modeset nouveau.modeset=1 3
    initrd $PREFIX/initrd.img-$KVER
}
EOF
chmod 755 "$ENTRY"
cat "$ENTRY"

log "Making the menu visible"
[ -f "$GRUB_BAK" ] || cp /etc/default/grub "$GRUB_BAK"
set_grub GRUB_TIMEOUT_STYLE menu
set_grub GRUB_TIMEOUT 10
info "menu shows for 10s (set-mac-boot-splash.sh had it hidden with timeout 0)"

log "update-grub"
update-grub

cat <<EOF

Next:
  1. sudo reboot
  2. At the GRUB menu pick "Linux Mint $KVER (nouveau, backlight probe)".
     It boots to a text console -- log in there.
  3. ls /sys/class/backlight/          # expect nv_backlight
     sudo $(dirname "$0")/nv-backlight.py --diff
  4. Note the register it reports, then: sudo reboot
     Pick the normal entry, and: sudo ./boot-nouveau-probe.sh --disarm

If nv_backlight is absent even under nouveau, the panel is not driven through the GPU
at all and the register hunt is over -- say so and we take a different route.
EOF
