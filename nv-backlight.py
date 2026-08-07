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
# The whole PDISPLAY aperture, not just the SOR sub-block: the first sweep assumed
# nouveau's 0x61c880 and its +4 divisor, and both were wrong here.
DISPLAY_BLOCK = (0x610000, 0x620000)
PMC_BLOCK = (0x001000, 0x002000)
# nv50 keeps the divisor next to the level; nva3 puts it 0x84 further on. Check both
# rather than committing to one family.
PAIR_OFFSETS = (0x04, 0x84)

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
    """Registers X whose low 16 bits match those of X+off for one of PAIR_OFFSETS.

    The panel is at full brightness, so on a PWM the duty equals the period and the two
    words agree in their low half. Requiring a high control bit as well was too strict --
    it is what made the first sweep miss everything -- so pairs are reported either way
    and the ones carrying a control bit are flagged."""
    lo, hi = block
    out = []
    for reg in range(lo, hi, 4):
        a = bar.rd(reg)
        if not a or not (a & 0xFFFF):
            continue
        for off in PAIR_OFFSETS:
            b = bar.rd(reg + off)
            if not b:
                continue
            if (a & 0xFFFF) != (b & 0xFFFF):
                continue
            out.append((reg, off, a, b, bool((a | b) & 0xF0000000)))
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


def all_candidates(bar):
    out = []
    for block in (DISPLAY_BLOCK, PMC_BLOCK):
        out.extend(find_pairs(bar, block))
    # Registers carrying a control bit first: more likely to be the real PWM, and the
    # sweep should reach them before the reader loses patience.
    out.sort(key=lambda c: (not c[4], c[0]))
    return out


def cmd_pairs(bar):
    require_live(bar)
    cands = all_candidates(bar)
    print("\n%d candidate register pairs "
          "(low 16 bits equal, i.e. duty == period at full brightness)\n" % len(cands))
    if not cands:
        print("    none")
        return
    print("  %-3s %-10s %-10s %-11s %-11s %s"
          % ("#", "duty", "period", "duty val", "period val", "ctrl bit"))
    for i, (reg, off, a, b, ctrl) in enumerate(cands):
        print("  %-3d 0x%06x   0x%06x   0x%08x  0x%08x  %s"
              % (i, reg, reg + off, a, b, "yes" if ctrl else ""))
    print("\n  -> sudo %s --sweep      # tries each in turn, restoring every one"
          % sys.argv[0])


class Restorer:
    """Puts a register back no matter how the process ends. Registered on SIGINT and
    SIGTERM as well as in a finally block, so Ctrl-C mid-hold still restores. These
    registers are volatile in any case -- a reboot clears anything left behind."""

    def __init__(self, bar, reg):
        self.bar, self.reg = bar, reg
        self.orig = bar.rd(reg)
        self.done = False
        self.prev = {}
        for sig in (signal.SIGINT, signal.SIGTERM):
            self.prev[sig] = signal.signal(sig, self._on_signal)

    def _on_signal(self, *_a):
        self.restore()
        sys.exit(1)

    def restore(self):
        if not self.done:
            self.bar.wr(self.reg, self.orig)
            self.done = True
        for sig, handler in self.prev.items():
            signal.signal(sig, handler)


def drive(bar, reg, off, pct, secs):
    """Write one duty value, hold, then restore. Returns False if unusable."""
    period = bar.rd(reg + off) & 0xFFFF
    if not period:
        return False
    r = Restorer(bar, reg)
    try:
        bar.wr(reg, (r.orig & ~0xFFFF) | int(period * pct / 100))
        time.sleep(secs)
    finally:
        r.restore()
    return True


def cmd_test(bar, reg, off, secs):
    require_live(bar)
    print("0x%06x = 0x%08x   period at 0x%06x = 0x%08x"
          % (reg, bar.rd(reg), reg + off, bar.rd(reg + off)))
    print("\nWatch the panel. Each step is held %ds.\n" % secs)
    for pct in (70, 40, 15):
        if not drive(bar, reg, off, pct, secs):
            sys.exit("period at 0x%06x is 0 -- refusing to write" % (reg + off))
        print("  %3d%%" % pct)
    print("\nRestored. If the panel dimmed and came back, this is the register:")
    print("  printf 'duty_reg=0x%06x\\nperiod_off=0x%02x\\n' | sudo tee %s"
          % (reg, off, CONF))


def cmd_sweep(bar, secs, start):
    """Walk the candidates, dimming each one briefly. The reader watches the panel and
    notes which index changed it -- far quicker than running --test by hand N times."""
    require_live(bar)
    cands = all_candidates(bar)
    if not cands:
        sys.exit("no candidates -- run --pairs")
    cands = cands[start:]
    print("Sweeping %d candidates, %ss each, dimming to 20%%." % (len(cands), secs))
    print("Watch the panel and note the # that changes it. Ctrl-C is safe.\n")
    for i, (reg, off, _a, _b, ctrl) in enumerate(cands, start):
        ok = drive(bar, reg, off, 20, secs)
        print("  #%-3d 0x%06x (period +0x%02x)%s%s"
              % (i, reg, off, "  ctrl" if ctrl else "", "" if ok else "  skipped"))
    print("\nAll restored. Confirm the one that worked:")
    print("  sudo %s --test 0xADDR --off 0xNN" % sys.argv[0])


def load_conf():
    reg, off = DEFAULT_DUTY_REG, 0x04
    try:
        with open(CONF) as f:
            for line in f:
                line = line.strip()
                if line.startswith("duty_reg="):
                    reg = int(line.split("=", 1)[1], 0)
                elif line.startswith("period_off="):
                    off = int(line.split("=", 1)[1], 0)
    except OSError:
        pass
    return reg, off


def get_pct(bar, reg, off):
    period = bar.rd(reg + off) & 0xFFFF
    if not period:
        sys.exit("period at 0x%06x is 0 -- run --pairs" % (reg + off))
    return round((bar.rd(reg) & 0xFFFF) * 100 / period)


def set_pct(bar, reg, off, pct):
    # Never 0: a black panel can only be undone by the very key being debugged.
    pct = max(5, min(100, int(pct)))
    period = bar.rd(reg + off) & 0xFFFF
    if not period:
        sys.exit("period at 0x%06x is 0 -- run --pairs" % (reg + off))
    bar.wr(reg, (bar.rd(reg) & ~0xFFFF) | int(period * pct / 100))
    return pct


def main():
    p = argparse.ArgumentParser()
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument("--probe", action="store_true", help="read-only survey")
    g.add_argument("--pairs", action="store_true", help="read-only: PWM-shaped pairs")
    g.add_argument("--test", metavar="REG", help="drive one candidate, then restore it")
    g.add_argument("--sweep", action="store_true", help="try every candidate in turn")
    g.add_argument("--get", action="store_true")
    g.add_argument("--set", type=int, metavar="PCT")
    g.add_argument("--up", action="store_true")
    g.add_argument("--down", action="store_true")
    p.add_argument("--step", type=int, default=10)
    p.add_argument("--secs", type=float, default=3, help="hold per step")
    p.add_argument("--from", dest="start", type=int, default=0,
                   help="resume --sweep at this candidate index")
    p.add_argument("--reg", help="override the duty register (default from %s)" % CONF)
    p.add_argument("--off", help="offset from duty to period register")
    a = p.parse_args()

    bar = Bar0(find_gpu())
    try:
        conf_reg, conf_off = load_conf()
        off = int(a.off, 0) if a.off else conf_off
        if a.probe:
            return cmd_probe(bar)
        if a.pairs:
            return cmd_pairs(bar)
        if a.test:
            return cmd_test(bar, int(a.test, 0), off, a.secs)
        if a.sweep:
            return cmd_sweep(bar, a.secs, a.start)

        require_live(bar)
        reg = int(a.reg, 0) if a.reg else conf_reg
        if a.get:
            print("%d%%" % get_pct(bar, reg, off))
        elif a.set is not None:
            print("%d%%" % set_pct(bar, reg, off, a.set))
        else:
            cur = get_pct(bar, reg, off)
            print("%d%%" % set_pct(bar, reg, off, cur + (a.step if a.up else -a.step)))
    finally:
        bar.close()


if __name__ == "__main__":
    main()
