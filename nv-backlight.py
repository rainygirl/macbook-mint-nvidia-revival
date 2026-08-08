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


# Kept deliberately small. Blanket-scanning 0x000000-0x020000 and 0x600000-0x680000 --
# roughly 150k registers -- walks over a great deal of unimplemented MMIO, and nouveau
# logs a bus fault for every such read. Under nvidia-340 those reads are silent, which is
# why the first version looked harmless; under nouveau it floods syslog.
#
# The SOR block is where a panel PWM has to live on Tesla, so that is what gets scanned,
# plus the handful of words around the pre-nv50 backlight register. --wide restores the
# old behaviour if this ever comes up empty.
DIFF_BLOCKS = ((0x61C000, 0x61E000), (0x0015F0, 0x001600))
DIFF_BLOCKS_WIDE = ((0x000000, 0x020000), (0x600000, 0x680000))


def snapshot(bar, blocks):
    snap = {}
    for lo, hi in blocks:
        for reg in range(lo, hi, 4):
            snap[reg] = bar.rd(reg)
    return snap


def find_backlight():
    for d in sorted(glob.glob("/sys/class/backlight/*")):
        if os.path.exists(os.path.join(d, "brightness")):
            return d
    return None


def mod_loaded(name):
    try:
        with open("/proc/modules") as f:
            return any(line.split(" ", 1)[0] == name for line in f)
    except OSError:
        return False


def boot_context():
    """Say which boot this is. Without it, 'no backlight device' is ambiguous between
    'the probe entry did not boot' and 'nouveau really provides no backlight', and those
    lead in completely different directions."""
    try:
        with open("/proc/cmdline") as f:
            cmdline = f.read().strip()
    except OSError:
        cmdline = ""
    probe = "modprobe.blacklist=" in cmdline and "nvidia" in cmdline
    return cmdline, probe, mod_loaded("nouveau"), mod_loaded("nvidia")


def cmd_diff(bar, blocks=DIFF_BLOCKS):
    """Identify the backlight register by differencing, with a driver that already
    works, instead of guessing at nouveau's constants.

    A control pass first: snapshot twice with nothing changed and discard every
    register that moved on its own. PTIMER and the performance counters tick
    constantly and would otherwise swamp the real hit."""
    require_live(bar)
    cmdline, probe, nouveau, nvidia = boot_context()
    dev = find_backlight()
    if not dev:
        print("no /sys/class/backlight device.\n")
        print("  /proc/cmdline: %s\n" % cmdline)
        print("  probe entry booted: %s" % ("yes" if probe else "NO"))
        print("  nouveau loaded:     %s" % ("yes" if nouveau else "no"))
        print("  nvidia loaded:      %s" % ("yes" if nvidia else "no"))
        if not probe:
            sys.exit("\nThis is the normal boot, not the probe one. Run\n"
                     "  sudo ./boot-nouveau-probe.sh --arm && sudo reboot\n"
                     "and do not touch any keys during boot -- it selects itself.")
        if not nouveau:
            sys.exit("\nThe probe entry booted but nouveau did not load. Check\n"
                     "  dmesg | grep -i nouveau")
        sys.exit("\nnouveau is driving the GPU and still registers no backlight.\n"
                 "That is a real answer: the panel is not driven through the GPU on\n"
                 "this machine, and the register hunt is over. Report this.")
    print("watching %s   (nouveau=%s nvidia=%s probe-boot=%s)"
          % (dev, nouveau, nvidia, probe))
    with open(os.path.join(dev, "max_brightness")) as f:
        maxb = int(f.read().strip())
    with open(os.path.join(dev, "brightness")) as f:
        orig = int(f.read().strip())
    print("max_brightness = %d, current = %d" % (maxb, orig))

    def set_b(v):
        with open(os.path.join(dev, "brightness"), "w") as f:
            f.write(str(v))

    nregs = sum((hi - lo) // 4 for lo, hi in blocks)
    print("scanning %d registers in %s"
          % (nregs, ", ".join("0x%06x-0x%06x" % b for b in blocks)))
    print("\ncontrol pass (nothing changed) ...")
    s0 = snapshot(bar, blocks)
    time.sleep(0.5)
    s1 = snapshot(bar, blocks)
    noisy = {r for r in s0 if s0[r] != s1[r]}
    print("  %d registers move on their own; ignoring them" % len(noisy))

    low = max(1, maxb // 5)
    print("\nsetting brightness %d -> %d ..." % (orig, low))
    try:
        set_b(low)
        time.sleep(0.5)
        s2 = snapshot(bar, blocks)
    finally:
        set_b(orig)
        print("restored brightness to %d" % orig)

    hits = [(r, s1[r], s2[r]) for r in sorted(s1)
            if r not in noisy and s1[r] != s2[r]]
    print("\n%d register(s) changed with brightness:\n" % len(hits))
    for r, before, after in hits:
        print("  0x%06x  0x%08x -> 0x%08x   (low16 %5d -> %5d)"
              % (r, before, after, before & 0xFFFF, after & 0xFFFF))
    if not hits:
        print("  none in this range -- retry with --wide (slow, and it makes nouveau")
        print("  log an MMIO fault for every unimplemented address it touches)")
        return
    print("\nNeighbours of each hit, to spot the period register:")
    for r, _b, _a in hits:
        for off in (0x00, 0x04, 0x84):
            print("    0x%06x+0x%02x = 0x%08x" % (r, off, bar.rd(r + off)))


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
    g.add_argument("--diff", action="store_true",
                   help="find the register by changing a working backlight and "
                        "differencing (run this under nouveau)")
    p.add_argument("--wide", action="store_true",
                   help="--diff over the full aperture; floods syslog with MMIO faults")
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
        if a.diff:
            return cmd_diff(bar, DIFF_BLOCKS_WIDE if a.wide else DIFF_BLOCKS)

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
