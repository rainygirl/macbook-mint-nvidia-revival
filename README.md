# macbook-mint-nvidia-revival

Bringing a 2010 white MacBook back with Linux Mint 20.3 + nvidia-340.

The machine is a MacBook7,1: Core 2 Duo P8600, GeForce 320M, 64-bit EFI. Getting Mint 20.3
usable on it needs the legacy `nvidia-340` driver, which does not install cleanly, and a boot
path that works around a GPU with no KMS.

[한국어 README](README.ko.md)

Everything they change is backed up and reversible.

| Script | Role |
| --- | --- |
| `fix-nvidia-340.sh` | Makes the `nvidia-340` package finish installing |
| `set-mac-boot-splash.sh` | Mac-style boot screen, and boot-time reductions |
| `prune-efi-entries.sh` | Cleans up EFI boot entries, skips shim |
| `get-mint-iso.sh` | Downloads a Mint ISO from the fastest mirror |

## `fix-nvidia-340.sh`

`nvidia-340` from the `kelebek333/nvidia-legacy` PPA fails to configure on kernel 5.4, so
dpkg leaves it in `iF` state. The PPA ships 13 DKMS patches for kernels 5.7-6.3 with
`PATCH_MATCH` commented out, so all of them apply unconditionally. `0006-kernel-5.14.patch`
rewrites `nv_drm_load()` to use `extra->pdev`, but that struct only exists in the branch
taken when `drm_legacy_pci_init()` is absent — which on 5.4 it is not:

    nv-drm.c:352: error: dereferencing pointer to incomplete type 'struct nv_drm_extra_priv_data'

Dropping all the patches is not an option (`0001-kernel-5.7.patch` is needed for the
`vm_fault_t` signature in `uvm/`), so the script adds `0014-kernel-pre-5.14-drm-pdev.patch`
to fall back to `dev->pdev`, rebuilds the module for every installed kernel, and runs
`dpkg --configure -a`.

It also writes `/etc/grub.d/09_enable_vga`, which emits GRUB `setpci` commands that set the
VGA-enable bit on the bridge above the GPU and the GPU's PCI Command register. Bus IDs come
from `lspci`/sysfs, not hardcoded. Without these the panel goes black once nvidia-340 takes
the GPU. The `09_` prefix matters: emitted before GRUB switches to gfxterm they leave GRUB
rendering into a framebuffer that is no longer scanned out.

Run as root. Takes 5-10 minutes — it builds the module for each kernel.

## `set-mac-boot-splash.sh`

Replaces the boot splash with a pre-Yosemite Mac one: `#d8d8d8` field, `#6b6b6b` Apple
logo, thin progress bar. The logo is fetched at run time (Wikimedia Commons
`Apple_logo_black.svg`, falling back to `ABATBeliever/Plymouth-theme-mac`, or `LOGO=`), then
decoded, trimmed, recoloured and resized by an embedded stdlib-only Python helper — the
target machine has no ImageMagick or rsvg-convert. GRUB gets the same logo on the same
background at the same position, so its screen and plymouth's line up.

It also sets `Option "NoLogo"` so the nvidia driver draws nothing at X startup, and
suppresses GRUB's `Loading Linux ...` messages.

Two flags are needed for the splash to appear at all on this hardware:

- `--fb-only` — nvidia-340 registers a KMS-less `/dev/dri/card0`. plymouth commits to the
  DRM renderer for any DRM device, fails (`Could not get card resources`), and never falls
  back to `/dev/fb0`. Removing `drm.so` from the initramfs breaks that chain.
- `--early-splash` — the packaged plymouth script declares `PREREQ="udev"` and so waits on
  `udevadm settle`. plymouth needs neither, so this runs it from `init-top` instead.

Boot-time flags:

- `--slim-initrd` — `MODULES=dep` plus dropping firmware for hardware this machine does not
  have (netronome 34 MB, amdgpu 32 MB, radeon, liquidio, i915 …). Firmware in an initramfs
  only matters for devices needed before the real root is mounted; root here is plain AHCI
  SATA. 88 MB → 37 MB. The old initrd is kept and `45_mac_fallback` adds a menu entry for it.
- `--fast-boot` — removes `drivers/md` from the initramfs (`raid6_pq` benchmarks every
  implementation on load: 1.9 s, on a machine with no RAID or LVM), disables
  `networkd-dispatcher` and `NetworkManager-wait-online`, and switches `/boot/efi` to
  `x-systemd.automount` so its fsck stops gating `local-fs.target`.

Diagnostics: `--dry-run` (builds the assets anywhere, no root), `--test-plymouth`,
`--debug-boot` / `--show-boot-log`, `--grub-pause N`, `--logo-hold N`. `--revert` undoes
everything.

The firmware text cursor before GRUB's video comes up cannot be removed. It shrank from ~6 s
to ~4 s by giving GRUB less to read and one less stage to load, but Apple's EFI draws it and
nothing can paint over it until GRUB's core is up.

## `prune-efi-entries.sh`

Deletes EFI boot entries by label, refusing to touch `BootCurrent`. Saves the full
`efibootmgr -v` output to `/var/backups/` first, and prints the `efibootmgr --create` line
needed to recreate anything. Deleting an entry does not touch the partition or the loader it
points at.

`--skip-shim` adds an entry that loads `grubx64.efi` directly instead of chaining through
`shimx64.efi`, and puts it first in `BootOrder`. shim exists for Secure Boot, which this Mac
does not have. The old entry is left in place. `--timeout N` sets the firmware boot-manager
timeout (default 0; it was 2 s).

Dry run by default; `--apply` to act.

## `get-mint-iso.sh`

Downloads a Mint ISO from whichever mirror is genuinely fastest where it runs — no
hardcoded region. It scrapes the "Download mirrors" table from `linuxmint.com/mirrors.php`
(the flag filename in each row is an ISO 3166-1 alpha-2 code, so it matches a geo-IP country
code directly), geo-IPs the runner, probes all ~154 mirrors in parallel for the exact ISO
URL, throughput-tests a shortlist, then downloads and verifies sha256 against the mirror's
`sha256sum.txt`. Resumable; uses `aria2c` across several mirrors if present, else `curl -C -`.

Defaults to `linuxmint-20.3-xfce-64bit.iso`: 20.3 is the last release whose 5.4 kernel works
with nvidia-340, and Xfce suits the hardware. Override with `RELEASE`, `EDITION`, `ARCH`,
`OUTDIR`, `MIRROR`, or `PROBE_ONLY=1` to just rank mirrors. Needs no root.

## AI Disclaimer

This application was produced by a human working with Claude.
