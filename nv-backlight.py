#!/usr/bin/env python3
"""Panel backlight for a GeForce 320M (MCP89 / NVAF) under nvidia-340.

Neither of the two drivers that would normally own this panel can:

  * nvidia-340 has no backlight support. `strings nvidia_drv.so` shows it only ever
    *reads* an existing one ("%s/%s/brightness", "Unable to find the brightness file
    path under", "EnableACPIBrightnessHotkeys"). There is no EnableBrightnessControl.
  * apple_bl probes -- APP0002:00 exists -- but its nvidia path talks to legacy I/O port
    0x52f, and apple_bl_add() ends with a live-hardware check that returns -ENODEV with
    no log message when that port does not answer. Its own comment says "this may not
    work under EFI", which is how this machine boots.

So the register gets driven directly. The 320M is Tesla-family (nv50), where nouveau
drives the panel through PDISPLAY at 0x61c880:

    0x61c880 + or*0x800   bit 31 enable, bit 30 "use divisor", bits 0..15 level
    0x61c884 + or*0x800   divisor -- the value 'level' is a fraction of

which is exactly what nouveau's nva3_get_intensity/nva3_set_intensity use. Reaching it
does not need /dev/mem: the kernel exports each PCI BAR as an mmap-able file under
/sys/bus/pci/devices/<addr>/resourceN, which is not subject to iomem=strict.

  sudo ./nv-backlight.py --probe          # read-only dump, changes nothing
  sudo ./nv-backlight.py --get
  sudo ./nv-backlight.py --set 60
  sudo ./nv-backlight.py --up / --down
"""

import argparse
import glob
import mmap
import os
import struct
import sys

PAGE = 4096
SOR_BACKLIGHT = 0x61C880   # NV50_PDISPLAY_SOR_BACKLIGHT
SOR_STRIDE = 0x800         # per-OR stride
NUM_OR = 4
# OR 3's divisor sits at 0x61c880 + 3*0x800 + 4, which is 0x2084 past the page base --
# three pages in. Map four so every OR this script looks at is inside the window.
MAP_LEN = 4 * PAGE
ENABLE = 0x80000000        # NV50_PDISPLAY_SOR_BACKLIGHT_ENABLE
USE_DIVISOR = 0x40000000
LEVEL_MASK = 0x0000FFFF
STATE = "/var/lib/nv-backlight.level"


def find_gpu():
    """First NVIDIA VGA-class device, as bus address. Not hardcoded -- same approach
    fix-nvidia-340.sh uses for its setpci lines."""
    for path in sorted(glob.glob("/sys/bus/pci/devices/*")):
        try:
            with open(os.path.join(path, "class")) as f:
                cls = int(f.read().strip(), 16)
            with open(os.path.join(path, "vendor")) as f:
                vendor = int(f.read().strip(), 16)
        except OSError:
            continue
        if cls >> 8 == 0x0300 and vendor == 0x10DE:
            return os.path.basename(path)
    sys.exit("no NVIDIA VGA device found")


class Bar0:
    """mmap of one page of BAR0 around the backlight registers."""

    def __init__(self, gpu, writable):
        self.path = "/sys/bus/pci/devices/%s/resource0" % gpu
        if not os.path.exists(self.path):
            sys.exit("%s does not exist" % self.path)
        self.base = SOR_BACKLIGHT & ~(PAGE - 1)
        self.off = SOR_BACKLIGHT & (PAGE - 1)
        flags = os.O_RDWR if writable else os.O_RDONLY
        try:
            self.fd = os.open(self.path, flags | os.O_SYNC)
        except PermissionError:
            sys.exit("permission denied opening %s -- run as root" % self.path)
        prot = mmap.PROT_READ | (mmap.PROT_WRITE if writable else 0)
        try:
            self.m = mmap.mmap(self.fd, MAP_LEN, mmap.MAP_SHARED, prot,
                               offset=self.base)
        except OSError as e:
            sys.exit("mmap of %s failed: %s\n"
                     "The BAR may be claimed exclusively; try booting with "
                     "iomem=relaxed." % (self.path, e))

    def rd(self, reg):
        i = self.off + (reg - SOR_BACKLIGHT)
        return struct.unpack("<I", self.m[i:i + 4])[0]

    def wr(self, reg, val):
        i = self.off + (reg - SOR_BACKLIGHT)
        self.m[i:i + 4] = struct.pack("<I", val & 0xFFFFFFFF)

    def close(self):
        self.m.close()
        os.close(self.fd)


def find_or(bar):
    """Which SOR drives the panel. The one whose divisor is non-zero and whose control
    word has the enable bit is the live one; checking rather than assuming OR 0 keeps
    this honest on a machine where the panel might be on a different output."""
    candidates = []
    for or_ in range(NUM_OR):
        ctrl = SOR_BACKLIGHT + or_ * SOR_STRIDE
        div = bar.rd(ctrl + 4)
        val = bar.rd(ctrl)
        if div and (val & ENABLE):
            candidates.append((or_, val, div))
    return candidates


def cmd_probe(bar):
    print("register dump (read-only)\n")
    print("  %-10s %-12s %-12s" % ("OR", "0x61c880+", "divisor 0x61c884+"))
    for or_ in range(NUM_OR):
        ctrl = SOR_BACKLIGHT + or_ * SOR_STRIDE
        val = bar.rd(ctrl)
        div = bar.rd(ctrl + 4)
        note = ""
        if div and (val & ENABLE):
            lvl = val & LEVEL_MASK
            note = "  <== live, level %d/%d = %d%%" % (
                lvl, div, round(lvl * 100 / div) if div else 0)
        print("  OR %-7d 0x%08x   0x%08x%s" % (or_, val, div, note))
    print()
    live = find_or(bar)
    if live:
        print("Panel is on OR %d. Safe to drive." % live[0][0])
    else:
        print("No OR has both a divisor and the enable bit set.")
        print("Either the panel is driven some other way, or nvidia-340 has left")
        print("these registers alone. Do not write blind -- report this dump.")


def get_level(bar, or_):
    ctrl = SOR_BACKLIGHT + or_ * SOR_STRIDE
    div = bar.rd(ctrl + 4)
    val = bar.rd(ctrl) & LEVEL_MASK
    if not div:
        return None
    return round(val * 100 / div)


def set_level(bar, or_, pct):
    # Never go to 0: a black panel can only be undone by the same key that is being
    # debugged. nouveau clamps the same way.
    pct = max(1, min(100, int(pct)))
    ctrl = SOR_BACKLIGHT + or_ * SOR_STRIDE
    div = bar.rd(ctrl + 4)
    if not div:
        sys.exit("divisor is 0 on OR %d -- refusing to write" % or_)
    val = round(pct * div / 100)
    bar.wr(ctrl, ENABLE | USE_DIVISOR | (val & LEVEL_MASK))
    try:
        with open(STATE, "w") as f:
            f.write(str(pct))
    except OSError:
        pass
    return pct


def main():
    p = argparse.ArgumentParser(add_help=True)
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument("--probe", action="store_true", help="read-only register dump")
    g.add_argument("--get", action="store_true")
    g.add_argument("--set", type=int, metavar="PCT")
    g.add_argument("--up", action="store_true")
    g.add_argument("--down", action="store_true")
    p.add_argument("--step", type=int, default=10)
    p.add_argument("--or", dest="or_", type=int, default=None,
                   help="force a SOR index instead of detecting it")
    a = p.parse_args()

    writable = not (a.probe or a.get)
    bar = Bar0(find_gpu(), writable)
    try:
        if a.probe:
            cmd_probe(bar)
            return
        if a.or_ is not None:
            or_ = a.or_
        else:
            live = find_or(bar)
            if not live:
                sys.exit("no live backlight OR found -- run --probe first")
            or_ = live[0][0]

        cur = get_level(bar, or_)
        if a.get:
            print("%s%%" % cur)
        elif a.set is not None:
            print("%d%%" % set_level(bar, or_, a.set))
        else:
            delta = a.step if a.up else -a.step
            print("%d%%" % set_level(bar, or_, (cur or 50) + delta))
    finally:
        bar.close()


if __name__ == "__main__":
    main()
