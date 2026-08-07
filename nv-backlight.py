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

So the GPU register is driven directly, the way nouveau would. Reaching it needs no
/dev/mem: the kernel exports each PCI BAR as an mmap-able file under
/sys/bus/pci/devices/<addr>/resourceN, outside iomem=strict.

Reads and writes go through a ctypes uint32 array over the mapping rather than Python
slicing -- slicing copies via memcpy, which may use byte-sized loads, and MMIO wants
aligned 32-bit accesses.

The register is found, not assumed. nouveau's constant for Tesla is 0x61c880 + or*0x800
with the divisor at +0x84, but that reads 0 on this part while an identically shaped pair
sits 0x800 lower:

    0x61c080 = 0x00005fed      duty
    0x61c084 = 0x40005fed      enable | period

so --pairs looks for that shape across the display block instead, and --test proves a
candidate by driving it and putting it back.

  sudo ./nv-backlight.py --probe             # read-only survey
  sudo ./nv-backlight.py --pairs             # read-only: find PWM-shaped register pairs
  sudo ./nv-backlight.py --test 0x61c080     # dim, hold, restore -- always restores
  sudo ./nv-backlight.py --get / --set 60 / --up / --down
"""

import argparse
import ctypes
import glob
import mmap
import os
import signal
import sys
import time

PMC_BOOT_0 = 0x000000
NV40_PMC_BACKLIGHT = 0x0015F0
NOUVEAU_SOR_BACKLIGHT = 0x61C880   # what nouveau uses on Tesla; 0 on this part
SOR_STRIDE = 0x800
NUM_OR = 4
NVA3_DIV_OFFSET = 0x84
ENABLE = 0x80000000
USE_DIVISOR = 0x40000000
DISPLAY_BLOCK = (0x61C000, 0x61E000)
PMC_BLOCK = (0x001500, 0x001700)

# Filled in by --test / set from a config file once confirmed.
CONF = "/etc/nv-backlight.conf"
DEFAULT_DUTY_REG = 0x61C080


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
    def __init__(self, gpu):
        self.path = "/sys/bus/pci/devices/%s/resource0" % gpu
        if not os.path.exists(self.path):
            sys.exit("%s does not exist" % self.path)
        self.size = bar0_size(gpu)
        try:
            self.fd = os.open(self.path, os.O_RDWR | os.O_SYNC)
        except PermissionError:
            sys.exit("permission denied on %s -- run as root" % self.path)
        except OSError as e:
            sys.exit("cannot open %s: %s" % (self.path, e))
        try:
            self.m = mmap.mmap(self.fd, self.size, mmap.MAP_SHARED,
                               mmap.PROT_READ | mmap.PROT_WRITE)
        except OSError as e:
            sys.exit("mmap of %s failed: %s\n"
                     "The BAR may be claimed exclusively; boot with iomem=relaxed."
                     % (self.path, e))
        self.u32 = (ctypes.c_uint32 * (self.size // 4)).from_buffer(self.m)

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
    reaching the hardware and every other 0 means nothing."""
    boot0 = bar.rd(PMC_BOOT_0)
    return boot0, (boot0 & 0x1FF00000) >> 20


def require_live(bar):
    boot0, chipset = check_live(bar)
    if boot0 == 0:
        sys.exit("PMC_BOOT_0 reads 0 -- the mapping is not reaching the GPU")
    return chipset


def find_pairs(bar, block):
    """Registers X where X and X+4 share their low 16 bits and X+4 carries a high
    control bit. That is the shape of a PWM (duty, enable|period) pair, and it is how
    the working register was identified on this machine."""
    lo, hi = block
    out = []
    for reg in range(lo, hi, 4):
        a = bar.rd(reg)
        b = bar.rd(reg + 4)
        if not a or not b:
            continue
        if (a & 0xFFFF) != (b & 0xFFFF):
            continue
        if not (b & 0xF0000000):
            continue
        out.append((reg, a, b))
    return out


def cmd_probe(bar):
    boot0, chipset = check_live(bar)
    print("BAR0 %s, %d MB" % (bar.path, bar.size >> 20))
    print("PMC_BOOT_0 (0x000000) = 0x%08x   chipset = 0x%02x" % (boot0, chipset))
    if boot0 == 0:
        print("\n  Mapping is NOT reaching the GPU. Every zero below is meaningless.")
        return
    print("  (0xaf = MCP89/NVAF, the 320M)")
    print("\nNV40_PMC_BACKLIGHT 0x0015f0 = 0x%08x" % bar.rd(NV40_PMC_BACKLIGHT))

    print("\nnouveau's Tesla location, for reference")
    print("  %-4s %-12s %-12s" % ("OR", "0x61c880+", "+0x84 (div)"))
    for or_ in range(NUM_OR):
        base = NOUVEAU_SOR_BACKLIGHT + or_ * SOR_STRIDE
        print("  %-4d 0x%08x   0x%08x" % (or_, bar.rd(base),
                                          bar.rd(base + NVA3_DIV_OFFSET)))
    cmd_pairs(bar)


def cmd_pairs(bar):
    require_live(bar)
    for name, block in (("display 0x61c000-0x61e000", DISPLAY_BLOCK),
                        ("PMC 0x001500-0x001700", PMC_BLOCK)):
        print("\nPWM-shaped register pairs in %s" % name)
        pairs = find_pairs(bar, block)
        if not pairs:
            print("    none")
            continue
        for reg, a, b in pairs:
            duty, period = a & 0xFFFF, b & 0xFFFF
            pct = round(duty * 100 / period) if period else 0
            print("    0x%06x = 0x%08x   0x%06x = 0x%08x   duty/period = %d/%d = %d%%"
                  % (reg, a, reg + 4, b, duty, period, pct))
        print("    -> confirm one with: sudo %s --test 0x%06x"
              % (sys.argv[0], pairs[0][0]))


def cmd_test(bar, reg, secs):
    """Drive a candidate and put it back. The original value is restored from a finally
    block and from SIGINT/SIGTERM handlers, so Ctrl-C during the hold still restores.
    These registers are volatile -- a reboot clears any mess regardless."""
    require_live(bar)
    orig = bar.rd(reg)
    period = bar.rd(reg + 4) & 0xFFFF
    print("0x%06x = 0x%08x   0x%06x = 0x%08x  (period %d)"
          % (reg, orig, reg + 4, bar.rd(reg + 4), period))
    if not period:
        sys.exit("period at 0x%06x is 0 -- refusing to write" % (reg + 4))

    restored = [False]

    def restore(*_a):
        if not restored[0]:
            bar.wr(reg, orig)
            restored[0] = True
            print("\nrestored 0x%06x = 0x%08x" % (reg, orig))

    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda *_a: (restore(), sys.exit(1)))

    try:
        print("\nWatch the panel. Each step is held %ds.\n" % secs)
        for pct in (70, 40, 15):
            val = (orig & ~0xFFFF) | int(period * pct / 100)
            bar.wr(reg, val)
            print("  %3d%%  wrote 0x%08x" % (pct, val))
            time.sleep(secs)
    finally:
        restore()

    print("\nIf the panel dimmed and came back, this is the register.")
    print("Record it with:  echo 'duty_reg=0x%06x' | sudo tee %s" % (reg, CONF))
    print("If nothing changed, nothing was left altered -- try the next candidate.")


def duty_reg():
    try:
        with open(CONF) as f:
            for line in f:
                if line.strip().startswith("duty_reg="):
                    return int(line.split("=", 1)[1].strip(), 0)
    except OSError:
        pass
    return DEFAULT_DUTY_REG


def get_pct(bar, reg):
    period = bar.rd(reg + 4) & 0xFFFF
    if not period:
        sys.exit("period at 0x%06x is 0 -- run --pairs" % (reg + 4))
    return round((bar.rd(reg) & 0xFFFF) * 100 / period)


def set_pct(bar, reg, pct):
    # Never 0: a black panel can only be undone by the very key being debugged.
    pct = max(5, min(100, int(pct)))
    period = bar.rd(reg + 4) & 0xFFFF
    if not period:
        sys.exit("period at 0x%06x is 0 -- run --pairs" % (reg + 4))
    cur = bar.rd(reg)
    bar.wr(reg, (cur & ~0xFFFF) | int(period * pct / 100))
    return pct


def main():
    p = argparse.ArgumentParser()
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument("--probe", action="store_true", help="read-only survey")
    g.add_argument("--pairs", action="store_true", help="read-only: PWM-shaped pairs")
    g.add_argument("--test", metavar="REG", help="drive a candidate, then restore it")
    g.add_argument("--get", action="store_true")
    g.add_argument("--set", type=int, metavar="PCT")
    g.add_argument("--up", action="store_true")
    g.add_argument("--down", action="store_true")
    p.add_argument("--step", type=int, default=10)
    p.add_argument("--secs", type=int, default=3, help="hold per step for --test")
    p.add_argument("--reg", help="override the duty register (default from %s)" % CONF)
    a = p.parse_args()

    bar = Bar0(find_gpu())
    try:
        if a.probe:
            return cmd_probe(bar)
        if a.pairs:
            return cmd_pairs(bar)
        if a.test:
            return cmd_test(bar, int(a.test, 0), a.secs)

        require_live(bar)
        reg = int(a.reg, 0) if a.reg else duty_reg()
        if a.get:
            print("%d%%" % get_pct(bar, reg))
        elif a.set is not None:
            print("%d%%" % set_pct(bar, reg, a.set))
        else:
            cur = get_pct(bar, reg)
            print("%d%%" % set_pct(bar, reg, cur + (a.step if a.up else -a.step)))
    finally:
        bar.close()


if __name__ == "__main__":
    main()
