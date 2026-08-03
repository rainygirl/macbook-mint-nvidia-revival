#!/bin/bash
# nvidia-340 fix for Apple MacBook (2010, MacBook7,1 / GeForce 320M) on Linux Mint 20.3 (focal, kernel 5.4)
#
# Two independent problems are handled:
#
# 1) DKMS build failure
#    The kelebek333/nvidia-legacy PPA ships 340.108-4ppafocal6 with 13 DKMS patches
#    (kernel 5.7 ... 6.3). PATCH_MATCH is commented out in dkms.conf, so all of them are
#    applied unconditionally -- including 0006-kernel-5.14.patch, which rewrites
#    nv_drm_load()/__nv_drm_unload() to use `extra->pdev` (struct nv_drm_extra_priv_data).
#    That struct is only defined in the branch taken when drm_legacy_pci_init() is absent.
#    On kernel 5.4 NV_DRM_LEGACY_PCI_INIT_PRESENT *is* defined, so the struct is compiled
#    out while the dereference remains:
#      nv-drm.c:352: error: dereferencing pointer to incomplete type 'struct nv_drm_extra_priv_data'
#    -> nvidia.ko fails, dpkg leaves nvidia-340 in "iF" state.
#    Dropping all patches is not an option: 0001-kernel-5.7.patch is required for the
#    vm_fault_t signature in uvm/nvidia_uvm_lite.c. So an extra patch is appended that
#    falls back to dev->pdev on pre-5.14 kernels.
#
# 2) No display / driver cannot drive the GPU after install
#    Apple EFI leaves the VGA-enable bit clear on the PCIe bridge above the GPU and the
#    Command register of the GPU itself, and without them the panel goes black once
#    nvidia-340 takes over. /etc/grub.d/00_enable_vga emits GRUB `setpci` commands to set
#    them. Bus IDs are derived from lspci/sysfs, not hardcoded. The 00_ prefix matters:
#    the writes have to happen before GRUB switches to gfxterm.
#
# Idempotent: safe to re-run.

set -euo pipefail

SRC=/usr/src/nvidia-340-340.108
PATCH_NAME=0014-kernel-pre-5.14-drm-pdev.patch
PKG=nvidia-340
VER=340.108

log() { printf '\n== %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
[ -d "$SRC" ] || { echo "$SRC not found -- install $PKG first" >&2; exit 1; }

# ---------------------------------------------------------------- 1. DKMS patch
log "Adding $PATCH_NAME"

cat > "$SRC/patches/$PATCH_NAME" <<'PATCH'
--- a/nv-drm.c
+++ b/nv-drm.c
@@ -345,11 +345,16 @@
 )
 {
     nv_linux_state_t *nvl;
+#if defined(NV_DRM_LEGACY_PCI_INIT_PRESENT) || defined(NV_DRM_PCI_INIT_PRESENT) || defined(NV_DRM_GET_PCI_DEV_PRESENT)
+    struct pci_dev *nv_pdev = dev->pdev;
+#else
     struct nv_drm_extra_priv_data *extra = dev->dev_private;
+    struct pci_dev *nv_pdev = extra->pdev;
+#endif

     for (nvl = nv_linux_devices; nvl != NULL; nvl = nvl->next)
     {
-        if (nvl->dev == extra->pdev)
+        if (nvl->dev == nv_pdev)
         {
             nvl->drm = dev;
             return 0;
@@ -370,11 +375,16 @@
 )
 {
     nv_linux_state_t *nvl;
+#if defined(NV_DRM_LEGACY_PCI_INIT_PRESENT) || defined(NV_DRM_PCI_INIT_PRESENT) || defined(NV_DRM_GET_PCI_DEV_PRESENT)
+    struct pci_dev *nv_pdev = dev->pdev;
+#else
     struct nv_drm_extra_priv_data *extra = dev->dev_private;
+    struct pci_dev *nv_pdev = extra->pdev;
+#endif

     for (nvl = nv_linux_devices; nvl != NULL; nvl = nvl->next)
     {
-        if (nvl->dev == extra->pdev)
+        if (nvl->dev == nv_pdev)
         {
             BUG_ON(nvl->drm != dev);
             nvl->drm = NULL;
PATCH

# Blank context lines in a unified diff must carry a leading space; the heredoc above
# loses it, so restore it.
sed -i 's/^$/ /' "$SRC/patches/$PATCH_NAME"

# Register it in dkms.conf right after the last existing PATCH[] entry.
if grep -q "$PATCH_NAME" "$SRC/dkms.conf"; then
    log "dkms.conf already references $PATCH_NAME"
else
    cp -n "$SRC/dkms.conf" "$SRC/dkms.conf.orig" || true
    last_idx=$(grep -oP '^PATCH\[\K[0-9]+' "$SRC/dkms.conf" | sort -n | tail -1)
    next_idx=$((last_idx + 1))
    sed -i "/^PATCH\[$last_idx\]=/a PATCH[$next_idx]=\"$PATCH_NAME\"" "$SRC/dkms.conf"
    log "dkms.conf: added PATCH[$next_idx]"
fi

# ------------------------------------------------------------ 2. rebuild module
for k in /lib/modules/*/build; do
    kver=$(basename "$(dirname "$k")")
    log "DKMS build for $kver"
    dkms remove -m "$PKG" -v "$VER" -k "$kver" --all 2>/dev/null || true
    dkms install -m "$PKG" -v "$VER" -k "$kver"
done

# ------------------------------------------------------- 3. finish dpkg configure
log "dpkg --configure -a"
dpkg --configure -a

# --------------------------------------------------------- 4. GRUB VGA enable
# The setpci writes are required: without them the panel goes black once nvidia-340 takes
# the GPU. But they also stop GRUB's own graphics from reaching the display -- reconfiguring
# the GPU's PCI Command register and the bridge's VGA routing leaves whatever framebuffer
# GRUB set up unscanned, so GRUB renders into nothing while a stale EFI console stays on
# screen. /etc/grub.d runs in lexical order, so 09_ puts these writes after 00_header's
# gfxterm setup and any background image, but still at top level -- before the menuentries
# in 10_linux load the kernel. GRUB draws first, then the registers change, then it boots.
VGASCRIPT=/etc/grub.d/09_enable_vga
for stale in /etc/grub.d/00_enable_vga /etc/grub.d/01_enable_vga; do
    if [ -e "$stale" ]; then
        rm -f "$stale"
        log "Removed $stale (wrong position) in favour of $VGASCRIPT"
    fi
done

log "Generating $VGASCRIPT"

# GPU: first VGA-class NVIDIA device.
gpu=$(lspci -Dn | awk '$2 ~ /^0300:/ && $3 ~ /^10de:/ {print $1; exit}')
[ -n "$gpu" ] || { echo "no NVIDIA VGA device found" >&2; exit 1; }

# Upstream bridge: parent of the GPU in the sysfs PCI tree.
gpu_path=$(readlink -f "/sys/bus/pci/devices/$gpu")
bridge=$(basename "$(dirname "$gpu_path")")
case "$bridge" in
    0000:*) ;;
    *) echo "GPU $gpu has no PCI bridge parent (root complex?) -- skipping bridge setpci" >&2
       bridge="" ;;
esac

# GRUB's setpci wants bus:dev.fn without the domain prefix.
gpu_short=${gpu#0000:}
bridge_short=${bridge#0000:}

{
    echo '#!/bin/sh'
    echo 'exec tail -n +4 "$0"'
    echo '# Emitted verbatim into grub.cfg. Apple EFI leaves VGA routing disabled.'
    # 0x3e = PCI Bridge Control; bit 3 (0x08) = VGA Enable.
    [ -n "$bridge_short" ] && echo "setpci -s \"$bridge_short\" 3e.b=8"
    # 0x04 = PCI Command; 0x07 = I/O + Memory space + Bus master enable.
    echo "setpci -s \"$gpu_short\" 04.b=7"
} > "$VGASCRIPT"
chmod 755 "$VGASCRIPT"

log "$VGASCRIPT:"
cat "$VGASCRIPT"

log "update-grub"
update-grub

# ------------------------------------------------------------------- 5. report
log "Result"
dpkg -l | grep -E '^..\s+(nvidia|libcuda)' || true
dkms status
echo
echo "Done. Reboot to unload nouveau and load the nvidia module."
