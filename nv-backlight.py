#!/usr/bin/env python3
"""Panel backlight for a GeForce 320M (MCP89 / NVAF) under nvidia-340.

Neither driver that would normally own this panel does:

  * nvidia-340 has no backlight support. `strings nvidia_drv.so` shows it only ever
    *reads* an existing one ("%s/%s/brightness", "Unable to find the brightness file
    path under", "EnableACPIBrightnessHotkeys"). There is no EnableBrightnessControl.
  * apple_bl probes -- APP0002:00 exists -- but its nvidia path talks to legacy I/O port
    0x52f, and apple_bl_add() ends with a live-hardware check that returns -ENODEV with
    no log message when that port does not answer. Its own comment says "this may not
    work under EFI", which is how this machine boots.

So the GPU register gets driven directly, the way nouveau would. Reaching it does not
need /dev/mem: the kernel exports each PCI BAR as an mmap-able file under
/sys/bus/pci/devices/<addr>/resourceN, which is not subject to iomem=strict.

--probe is read-only and prints a survey rather than one guess, because the backlight
register moved across Tesla revisions and the 320M sits near that boundary:

    PMC_BOOT_0        0x000000            chipset id -- proves the mapping is live
    NV40_PMC_BACKLIGHT 0x0015f0           pre-nv50 location, still used by some parts
    nv50   level      0x61c880 + or*0x800   mask 0x00000fff, divisor is a fixed 1025
    nva3   level      0x61c880 + or*0x800   mask 0x00ffffff, divisor at +0x84

Reads go through a ctypes uint32 array over the mapping, not Python slicing: slicing
copies through memcpy, which is free to use byte-sized loads, and MMIO wants aligned
32-bit accesses.

  sudo ./nv-backlight.py --probe          # read-only survey, changes nothing
  sudo ./nv-backlight.py --get
  sudo ./nv-backlight.py --set 60
  sudo ./nv-backlight.py --up / --down
"""

import argparse
import ctypes
import glob
import mmap
import os
import sys

PMC_BOOT_0 = 0x000000
NV40_PMC_BACKLIGHT = 0x0015F0
SOR_BACKLIGHT = 0x61C880
SOR_STRIDE = 0x800
NUM_OR = 4
ENABLE = 0x80000000
USE_DIVISOR = 0x40000000
NV50_LEVEL_MASK = 0x00000FFF
NVA3_LEVEL_MASK = 0x00FFFFFF
NV50_FIXED_DIV = 1025
NVA3_DIV_OFFSET = 0x84
STATE = "/var/lib/nv-backlight.level"


def find_gpu():
    """First NVIDIA VGA-class device, as a bus address -- the same way
    fix-nvidia-340.sh derives it for setpci, rather than hardcoding."""
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


def bar0_size(gpu):
    with open("/sys/bus/pci/devices/%s/resource" % gpu) as f:
        start, end, _flags = f.readline().split()
    return int(end, 16) - int(start, 16) + 1


class Bar0:
    """The whole of BAR0, as a uint32 array. Mapped PROT_WRITE so ctypes can build a
    real array over it (from_buffer needs a writable buffer); --probe and --get never
    assign to it."""

    def __init__(self, gpu):
        self.path = "/sys/bus/pci/devices/%s/resource0" % gpu
        if not os.path.exists(self.path):
            sys.exit("%s does not exist" % self.path)
        size = bar0_size(gpu)
        try:
            self.fd = os.open(self.path, os.O_RDWR | os.O_SYNC)
        except PermissionError:
            sys.exit("permission denied on %s -- run as root" % self.path)
        except OSError as e:
            sys.exit("cannot open %s: %s" % (self.path, e))
        try:
            self.m = mmap.mmap(self.fd, size, mmap.MAP_SHARED,
                               mmap.PROT_READ | mmap.PROT_WRITE)
        except OSError as e:
            sys.exit("mmap of %s failed: %s\n"
                     "The BAR may be claimed exclusively; boot with iomem=relaxed."
                     % (self.path, e))
        self.u32 = (ctypes.c_uint32 * (size // 4)).from_buffer(self.m)
        self.size = size

    def rd(self, reg):
        return self.u32[reg >> 2]

    def wr(self, reg, val):
        self.u32[reg >> 2] = val & 0xFFFFFFFF

    def close(self):
        del self.u32
        self.m.close()
        os.close(self.fd)


def check_live(bar):
    """PMC_BOOT_0 is never 0 on a powered GPU. If it reads 0 the mapping is not
    reaching the hardware, and every other 0 in the dump means nothing."""
    boot0 = bar.rd(PMC_BOOT_0)
    chipset = (boot0 & 0x1FF00000) >> 20
    return boot0, chipset


def cmd_probe(bar):
    boot0, chipset = check_live(bar)
    print("BAR0 %s, %d MB" % (bar.path, bar.size >> 20))
    print("PMC_BOOT_0 (0x000000) = 0x%08x   chipset = 0x%02x" % (boot0, chipset))
    if boot0 == 0:
        print("\n  PMC_BOOT_0 reads 0. The mapping is NOT reaching the GPU, so the")
        print("  zeros below are meaningless. Nothing here is safe to write.")
        return
    print("  (0xaf = MCP89/NVAF, the 320M. Non-zero means the mapping is live.)")

    print("\nNV40_PMC_BACKLIGHT 0x0015f0 = 0x%08x" % bar.rd(NV40_PMC_BACKLIGHT))

    print("\nSOR backlight registers")
    print("  %-4s %-12s %-12s %-12s" % ("OR", "0x61c880+", "+0x04", "+0x84 (nva3 div)"))
    for or_ in range(NUM_OR):
        base = SOR_BACKLIGHT + or_ * SOR_STRIDE
        print("  %-4d 0x%08x   0x%08x   0x%08x"
              % (or_, bar.rd(base), bar.rd(base + 4), bar.rd(base + NVA3_DIV_OFFSET)))

    print("\nNon-zero words in 0x61c000-0x61e000 (the PDISPLAY SOR block)")
    hits = 0
    for reg in range(0x61C000, 0x61E000, 4):
        val = bar.rd(reg)
        if val:
            print("    0x%06x = 0x%08x" % (reg, val))
            hits += 1
            if hits >= 40:
                print("    ... (truncated at 40)")
                break
    if not hits:
        print("    none -- the display engine block is entirely zero")

    print("\nNon-zero words in 0x001500-0x001700 (the PMC backlight block)")
    hits = 0
    for reg in range(0x1500, 0x1700, 4):
        val = bar.rd(reg)
        if val:
            print("    0x%06x = 0x%08x" % (reg, val))
            hits += 1
    if not hits:
        print("    none")


def read_level(bar, or_):
    """Try the nva3 layout first (divisor at +0x84); fall back to nv50's fixed 1025."""
    base = SOR_BACKLIGHT + or_ * SOR_STRIDE
    ctrl = bar.rd(base)
    div = bar.rd(base + NVA3_DIV_OFFSET)
    if div:
        val = ctrl & NVA3_LEVEL_MASK
        return round(val * 100 / div), div, NVA3_LEVEL_MASK
    val = ctrl & NV50_LEVEL_MASK
    return round(val * 100 / NV50_FIXED_DIV), NV50_FIXED_DIV, NV50_LEVEL_MASK


def find_or(bar):
    out = []
    for or_ in range(NUM_OR):
        base = SOR_BACKLIGHT + or_ * SOR_STRIDE
        ctrl = bar.rd(base)
        if ctrl & ENABLE:
            out.append(or_)
    return out


def set_level(bar, or_, pct):
    # Never 0: a black panel can only be undone by the very key being debugged.
    pct = max(1, min(100, int(pct)))
    base = SOR_BACKLIGHT + or_ * SOR_STRIDE
    _cur, div, mask = read_level(bar, or_)
    val = round(pct * div / 100)
    bar.wr(base, ENABLE | USE_DIVISOR | (val & mask))
    try:
        with open(STATE, "w") as f:
            f.write(str(pct))
    except OSError:
        pass
    return pct


def main():
    p = argparse.ArgumentParser()
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument("--probe", action="store_true", help="read-only survey")
    g.add_argument("--get", action="store_true")
    g.add_argument("--set", type=int, metavar="PCT")
    g.add_argument("--up", action="store_true")
    g.add_argument("--down", action="store_true")
    p.add_argument("--step", type=int, default=10)
    p.add_argument("--or", dest="or_", type=int, default=None)
    a = p.parse_args()

    bar = Bar0(find_gpu())
    try:
        if a.probe:
            cmd_probe(bar)
            return
        boot0, _ = check_live(bar)
        if boot0 == 0:
            sys.exit("PMC_BOOT_0 reads 0 -- the mapping is dead, refusing to write")
        if a.or_ is not None:
            or_ = a.or_
        else:
            live = find_or(bar)
            if not live:
                sys.exit("no SOR has the backlight enable bit set -- run --probe first")
            or_ = live[0]
        cur, _div, _mask = read_level(bar, or_)
        if a.get:
            print("%d%%" % cur)
        elif a.set is not None:
            print("%d%%" % set_level(bar, or_, a.set))
        else:
            print("%d%%" % set_level(bar, or_, cur + (a.step if a.up else -a.step)))
    finally:
        bar.close()


if __name__ == "__main__":
    main()
