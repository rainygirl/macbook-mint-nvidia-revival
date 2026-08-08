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
| `install-mcp89-backlight.sh` | Restores the F1/F2 panel-brightness keys after the driver switch |
| `fix-screen-blank.sh` | Makes the panel switch off after an idle period |
| `nv-backlight.py` | Finds and drives the backlight register from userspace (diagnostic) |
| `boot-nouveau-probe.sh` | Boots nouveau once, to compare against |
| `fix-brightness-keys.sh` | Superseded -- kept for its diagnostics and its `--revert` |
| `set-mac-boot-splash.sh` | Mac-style boot screen, and boot-time reductions |
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

## `install-mcp89-backlight.sh`

F1/F2 stop dimming the panel once nvidia-340 replaces nouveau. The keys are fine; what
disappears is the thing they act on. nouveau's KMS driver registers
`/sys/class/backlight/nv_backlight` and xfce4-power-manager writes to it directly.
nvidia-340 blacklists nouveau and registers a KMS-less DRM node instead, so no backlight
device exists at all and the keypress has nowhere to go.

Three obvious routes are all dead ends here, and the script removes each one:

- **nvidia-340's own backlight.** There isn't one. `strings nvidia_drv.so` shows only
  `%s/%s/brightness`, `Unable to find the brightness file path under` and
  `EnableACPIBrightnessHotkeys` -- it *reads* a backlight, it never creates one. There is
  no `EnableBrightnessControl`; `RegistryDwords` silently ignores unknown keys, and
  Xorg.0.log's `(**)` only means the option was specified, not understood.
- **`apple_bl`.** It matches `APP0002`, which this machine has, and its nvidia path is
  right for an MCP89 host bridge. But `apple_bl_add()` ends with a live-hardware check on
  legacy I/O port `0x52f` and returns `-ENODEV` *with no log message* when that port does
  not answer. Its own comment says "this may not work under EFI", which is how this Mac
  boots. `acpi_backlight=vendor` does not help: it never gets that far.
- **`acpi_video`.** Registers nothing on this machine either, with or without
  `acpi_backlight=`.

So the module drives the PWM directly. The registers were not taken from nouveau's
headers -- nouveau's Tesla constant is `0x61c880` with the divisor at `+0x84`, and both
read 0 here. They were found by booting nouveau, changing `nv_backlight`, and diffing the
BAR (`nv-backlight.py --diff`):

    0x61c080   period, read and never written (2966 under nouveau, 24557 under nvidia-340)
    0x61c084   bit 31  write-only latch; a write without it stores the word but never
                       reaches the PWM -- which is why reads already agreed with
                       nv_backlight while writes did nothing
               bit 30  maintained by the hardware
               bits 0. duty

Brightness is a percentage of whatever period the register currently holds, so the same
code works under either driver despite the two different periods.

The result is `/sys/class/backlight/mcp89_backlight`, so xfce4-power-manager handles
F1/F2 itself exactly as it did with `nv_backlight` -- no custom key bindings, no helper,
no sudo. DKMS `AUTOINSTALL` rebuilds it across kernel updates, the same mechanism
nvidia-340 uses. It refuses to load unless `PMC_BOOT_0` reports chipset `0xaf`, and backs
off if nouveau owns the GPU.

Undo with `--uninstall`.

## `fix-screen-blank.sh`

The panel never blanks on idle because `xscreensaver` runs `xset -dpms` whenever its own
`dpmsEnabled` is False -- `xset q` shows populated timeouts next to `DPMS is Disabled`.
Setting xfce4-power-manager's timers alone does nothing; xscreensaver undoes it on its
next apply. So `~/.xscreensaver` is fixed first, then the matching xfconf keys, then
`xset +dpms` to take effect without waiting for either daemon.

`--diagnose` reports without changing anything and needs no root. `--test` forces DPMS
off immediately, which separates "the driver cannot blank this panel" from "the idle
timer never fires" -- no amount of reading settings does that.

## `nv-backlight.py`

The tool that found the register above, kept because it is how to find it again on a
different part. `--probe` surveys BAR0 read-only and proves the mapping is live via
`PMC_BOOT_0`. `--pairs` looks for the *shape* of a PWM pair rather than trusting a
constant. `--sweep` drives each candidate briefly, restoring every one. `--diff` is the
one that settled it: with a working backlight present it changes brightness and reports
which registers moved, discarding those that move on their own.

It reaches BAR0 through `/sys/bus/pci/devices/<addr>/resource0`, which needs no
`/dev/mem` and is not subject to `iomem=strict`, and goes through a ctypes `uint32` array
rather than Python slicing -- slicing copies via `memcpy`, which may use byte-sized loads,
and MMIO wants aligned 32-bit accesses.

## `boot-nouveau-probe.sh`

Adds a GRUB entry that boots the same kernel with `modprobe.blacklist=nvidia,...` so
nouveau can drive the GPU for one boot. It does not show the GRUB menu: `09_enable_vga`'s
setpci writes run while grub.cfg is parsed, and after them GRUB renders into a
framebuffer that is no longer scanned out, so a visible menu is an *invisible* prompt that
any keypress freezes. The entry is selected in advance with `grub-editenv set next_entry`,
which 00_header's preamble consumes and clears as it boots -- one shot, self-cancelling,
and a power-cycle is enough to get back.

## `fix-brightness-keys.sh`

The first attempt, superseded by `install-mcp89-backlight.sh`, which calls its `--revert`
to undo what it set. Its `--diagnose` is still the quickest way to see backlight devices,
driver state, `apple_bl` bind status and `hid_apple`'s `fnmode` in one place.

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
