#!/usr/bin/env bash
# Replace the Linux Mint boot splash with a Mac-style one: black screen, centred
# Apple logo, thin progress bar underneath.
#
# It also replaces the logo the proprietary nvidia driver draws at X server startup,
# so no NVIDIA splash appears after the plymouth one (nvidia's LogoPath option).
#
# The logo is fetched from an external source rather than shipped here:
#   1. $LOGO                                    -- any local PNG you point at
#   2. Wikimedia Commons  Apple_logo_black.svg  -- canonical, rendered to PNG server-side
#   3. github.com/ABATBeliever/Plymouth-theme-mac (MIT) -- apple-logo.png fallback
# The Apple logo is Apple Inc.'s trademark; this is a local cosmetic change.
#
# The plymouth theme itself is written here from scratch. The external theme above
# cannot be used as-is: its .script calls ProgressBar() and Plymouth.Sleep(), neither
# of which exists in plymouth's script module, so it renders nothing on 0.9.x.
#
# No ImageMagick / rsvg-convert needed -- an embedded stdlib-only Python helper decodes,
# trims, recolours, resizes and re-encodes the PNG, and generates the bar images.
#
# Usage:
#   sudo ./set-mac-boot-splash.sh                 # white bg, black logo (pre-Yosemite Mac)
#   sudo ./set-mac-boot-splash.sh --variant black # black bg, white logo (newer Macs)
#   sudo ./set-mac-boot-splash.sh --fb-only --early-splash   # what this machine needs
#   sudo ./set-mac-boot-splash.sh --test-plymouth # diagnose a blank splash
#   sudo LOGO=~/my-logo.png ./set-mac-boot-splash.sh
#   sudo LOGO_HEIGHT=160 ./set-mac-boot-splash.sh
#   sudo GFXMODE= ./set-mac-boot-splash.sh        # leave GRUB_GFXMODE alone
#   sudo ./set-mac-boot-splash.sh --revert

set -euo pipefail

THEME=${THEME:-mac-boot}
THEMEDIR=/usr/share/plymouth/themes/$THEME
# Light grey field with a mid-dark grey Apple is the pre-Yosemite Mac boot screen, the
# era this MacBook belongs to. --variant black gives the newer (Yosemite+) look.
VARIANT=${VARIANT:-grey}
LOGO=${LOGO:-}
LOGO_HEIGHT=${LOGO_HEIGHT:-128}
# "auto" lets GRUB pick a mode the GOP actually advertises. Pinning 1280x800 (the
# MacBook7,1 panel) looks right but breaks gfxterm outright if the firmware does not offer
# exactly that mode -- and grub.cfg only insmods gfxterm inside `if loadfont`, so the
# failure is silent: no background image and a text cursor for the whole GRUB phase.
# Plymouth reads whatever geometry it ends up with, so nothing downstream needs it fixed.
GFXMODE=${GFXMODE-auto}
GRUB_BAK=/etc/default/grub.mac-boot.bak
PREV_FILE=/var/lib/plymouth-mac-boot.previous
NVIDIA_XORG_CONF=/etc/X11/xorg.conf.d/10-mac-nvidia-logo.conf   # legacy, removed on sight
XORG_BAK=/etc/X11/xorg.conf.mac-boot.bak
GRUB10=/etc/grub.d/10_linux
# NOT in /etc/grub.d: grub-mkconfig runs every executable file in that directory and
# grub_file_is_not_garbage only filters *.dpkg-*, *.rpmsave/new, README* and *.sig, so a
# ".bak" copy of 10_linux there gets executed and duplicates every menu entry.
GRUB10_BAK=/var/backups/10_linux.mac-boot.bak
GRUB10_BAK_BAD=/etc/grub.d/10_linux.mac-boot.bak
# 00_0_ sorts before 00_header ('0' < 'e' < 'h'), so this is the first thing GRUB runs.
GRUBEARLY=/etc/grub.d/00_0_mac_splash
GRUBQUIET=/etc/grub.d/06_mac_quiet
GRUBPAUSESCRIPT=/etc/grub.d/07_mac_pause
FALLBACKMENU=/etc/grub.d/45_mac_fallback
FWHOOK=/etc/initramfs-tools/hooks/zz-mac-slim-firmware
MDHOOK=/etc/initramfs-tools/hooks/zz-mac-no-md
FSTAB_BAK=/etc/fstab.mac-boot.bak
DISABLED_UNITS=/var/lib/mac-boot-disabled-units
# In /boot/grub so GRUB reads it regardless of how /boot is mounted.
GRUBBG=${GRUBBG:-/boot/grub/mac-boot-bg.png}
GRUBFONT=/boot/grub/fonts/ascii.pf2
REVERT=0
DRYRUN=0
TESTPLY=0
DEBUGBOOT=0
SHOWLOG=0
FBONLY=0
EARLY=0
NVLOGO=0
GRUBPAUSE=0
SLIM=0
LOGOHOLD=${LOGOHOLD:-0}
FASTBOOT=0
TESTTTY=${TESTTTY:-/dev/tty3}
BOOTLOG=/var/log/plymouth-boot.log
FBHOOK=/etc/initramfs-tools/hooks/zz-plymouth-fb-only
EARLYSCRIPT=/etc/initramfs-tools/scripts/init-top/plymouth-early

while [ $# -gt 0 ]; do
    case "$1" in
        --variant) VARIANT=${2:?}; shift 2 ;;
        --revert)  REVERT=1; shift ;;
        --dry-run) DRYRUN=1; shift ;;
        --test-plymouth) TESTPLY=1; shift ;;
        --debug-boot) DEBUGBOOT=1; shift ;;
        --show-boot-log) SHOWLOG=1; shift ;;
        --fb-only) FBONLY=1; shift ;;
        --early-splash) EARLY=1; shift ;;
        --nvidia-logo) NVLOGO=1; shift ;;
        --grub-pause) GRUBPAUSE=${2:?}; shift 2 ;;
        --slim-initrd) SLIM=1; shift ;;
        --logo-hold) LOGOHOLD=${2:?}; shift 2 ;;
        --fast-boot) FASTBOOT=1; shift ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

log()  { printf '\033[1;34m==\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mXX\033[0m %s\n' "$*" >&2; exit 1; }

# --dry-run builds the theme into a temp dir and stops, so the asset pipeline can be
# checked on any machine (including macOS) without root or plymouth.
if [ "$DRYRUN" = 1 ]; then
    THEMEDIR=$(mktemp -d)/$THEME
    GRUBBG=$THEMEDIR/mac-boot-bg.png      # /boot/grub is not writable without root
    warn "dry run: building into $THEMEDIR, nothing will be installed"
else
    [ "$(id -u)" -eq 0 ] || die "run as root"
    command -v update-alternatives >/dev/null || die "update-alternatives not found (Debian/Ubuntu/Mint only)"
    command -v update-initramfs   >/dev/null || die "update-initramfs not found"
    [ -d /usr/share/plymouth/themes ] || die "plymouth is not installed"
fi

# ----------------------------------------------------------------------- revert
if [ "$REVERT" = 1 ]; then
    if [ -s "$PREV_FILE" ]; then
        prev=$(cat "$PREV_FILE")
        log "Restoring plymouth theme: $prev"
        update-alternatives --set default.plymouth "$prev"
    else
        warn "No saved previous theme; falling back to automatic selection"
        update-alternatives --auto default.plymouth
    fi
    update-alternatives --remove default.plymouth "$THEMEDIR/$THEME.plymouth" 2>/dev/null || true
    rm -rf "$THEMEDIR" "$PREV_FILE"
    rm -f "$NVIDIA_XORG_CONF" "$FBHOOK" "$EARLYSCRIPT" "$GRUBQUIET" "$GRUB10_BAK_BAD" \
          "$GRUBBG" "$GRUBFONT" "$GRUBPAUSESCRIPT" "$FALLBACKMENU" "$FWHOOK" "$GRUBEARLY" "$MDHOOK"
    if [ -s "$DISABLED_UNITS" ]; then
        while read -r u; do [ -n "$u" ] && systemctl enable "$u" >/dev/null 2>&1; done < "$DISABLED_UNITS"
        rm -f "$DISABLED_UNITS"
        log "Re-enabled the units --fast-boot had disabled"
    fi
    if [ -f "$FSTAB_BAK" ]; then cp "$FSTAB_BAK" /etc/fstab && rm -f "$FSTAB_BAK"; log "Restored /etc/fstab"; fi
    if grep -q 'set-mac-boot-splash' /etc/X11/xorg.conf 2>/dev/null; then
        log "Removing our /etc/X11/xorg.conf (nvidia goes back to its built-in logo)"
        rm -f /etc/X11/xorg.conf
        [ -f "$XORG_BAK" ] && mv "$XORG_BAK" /etc/X11/xorg.conf && log "Restored $XORG_BAK"
    fi
    if [ -f "$GRUB_BAK" ]; then
        log "Restoring $GRUB_BAK -> /etc/default/grub"
        cp "$GRUB_BAK" /etc/default/grub && rm -f "$GRUB_BAK"
    fi
    if [ -f "$GRUB10_BAK" ]; then
        log "Restoring $GRUB10_BAK -> $GRUB10"
        cp "$GRUB10_BAK" "$GRUB10" && rm -f "$GRUB10_BAK"
    fi
    update-initramfs -u
    command -v update-grub >/dev/null && update-grub
    log "Reverted. Reboot to see the original splash."
    exit 0
fi

# --------------------------------------------- read back a real boot's debug log
# A post-boot --test-plymouth run is polluted: by then nvidia is loaded and
# /dev/dri/card0 exists, which is NOT the situation plymouth faces in the initramfs.
# This reads the log produced by plymouth.debug during an actual boot.
if [ "$SHOWLOG" = 1 ]; then
    [ "$(id -u)" -eq 0 ] || die "run as root"
    [ -s "$BOOTLOG" ] || die "$BOOTLOG is empty or missing -- run --debug-boot and reboot first"
    chmod 644 "$BOOTLOG"
    log "Renderer / device lines:"
    grep -iE "renderer|frame.?buffer|/dev/fb|/dev/dri|drm|head|console|terminal" "$BOOTLOG" | head -40 >&2 || true
    log "Splash / theme lines:"
    grep -iE "splash|theme|script|display" "$BOOTLOG" | head -40 >&2 || true
    log "Errors:"
    grep -inE "error|invalid|unable|failed|no such|cannot|could not" "$BOOTLOG" | head -40 >&2 || true
    log "Full log: $BOOTLOG ($(wc -l < "$BOOTLOG") lines)"
    exit 0
fi

# ------------------------------------------------- diagnose a missing splash
# plymouth silently falls back to a blank screen if the theme script fails to load,
# which is indistinguishable from "no splash" once quiet/loglevel=0 hide the console.
# This drives plymouthd by hand and prints whatever it complained about.
if [ "$TESTPLY" = 1 ]; then
    [ "$(id -u)" -eq 0 ] || die "run as root"
    DBG=/tmp/plymouth-debug.log
    rm -f "$DBG"
    # --kernel-command-line fakes the cmdline, so this exercises exactly the flags the
    # grub section below installs -- no reboot needed to tell whether they work.
    PLYCMD=${PLYCMD:-"splash plymouth.ignore-udev"}
    log "Starting plymouthd on $TESTTTY (cmdline: \"$PLYCMD\"), debug log -> $DBG"
    plymouth quit 2>/dev/null || true
    plymouthd --debug --debug-file="$DBG" --tty="$TESTTTY" \
              --kernel-command-line="$PLYCMD" || true
    plymouth show-splash || true
    for p in 20 40 60 80 100; do plymouth update --status="test $p%" || true; sleep 1; done
    sleep 1
    plymouth quit || true

    chmod 644 "$DBG"   # plymouthd writes it 0600; make it readable for later inspection
    log "Renderer / device lines (which backend actually got the screen):"
    grep -iE "renderer|frame.?buffer|/dev/fb|/dev/dri|drm|head|device" "$DBG" | head -30 >&2 || true
    log "Theme / script plugin lines:"
    grep -iE "theme|script|plugin|splash" "$DBG" | head -30 >&2 || true
    log "Errors:"
    if grep -inE "error|invalid|unable|failed|no such|unexpected|cannot" "$DBG" | head -40 >&2; then :; else
        echo "   (none)" >&2
    fi
    log "Full log: $DBG"
    exit 0
fi

# BG = plymouth background level (0..1); BGB = the same as an 8-bit grey (also the bKGD
# chunk for nvidia's LogoPath); LOGO_COLOUR/FG/TRACK = 8-bit greys for logo and bar.
#
# grey reproduces the pre-Yosemite Mac boot screen this MacBook shipped with: a light
# grey field with a mid-dark grey Apple, not black-on-white. A pure black logo reads as
# obviously wrong on that background.
case "$VARIANT" in
    grey|gray)
           BG=0.847 ; BGB=216 ; LOGO_COLOUR=107 ; FG=107 ; TRACK=190 ; TXT="0.42, 0.42, 0.42" ;;
    black) BG=0.0   ; BGB=0   ; LOGO_COLOUR=white ; FG=255 ; TRACK=56  ; TXT="1, 1, 1" ;;
    white) BG=1.0   ; BGB=255 ; LOGO_COLOUR=black ; FG=0   ; TRACK=204 ; TXT="0, 0, 0" ;;
    *) die "--variant must be grey, black or white" ;;
esac

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# ------------------------------------------------------- embedded PNG helper
cat > "$TMP/pngtool.py" <<'PYTOOL'
"""Normalise a PNG to 8-bit RGBA (optionally recolour + resize). Stdlib only.
   norm IN OUT HEIGHT [white|black|keep]   |   solid OUT W H R G B A"""
import struct, sys, zlib


def read_png(path):
    data = open(path, "rb").read()
    if data[:8] != b"\x89PNG\r\n\x1a\x0a":
        raise SystemExit("not a PNG: " + path)
    pos, idat, plte, trns = 8, [], None, None
    w = h = depth = ctype = None
    while pos < len(data):
        (ln,) = struct.unpack(">I", data[pos:pos + 4])
        tag, body = data[pos + 4:pos + 8], data[pos + 8:pos + 8 + ln]
        if tag == b"IHDR":
            w, h, depth, ctype, _, _, interlace = struct.unpack(">IIBBBBB", body)
            if interlace:
                raise SystemExit("interlaced PNG unsupported")
        elif tag == b"PLTE": plte = body
        elif tag == b"tRNS": trns = body
        elif tag == b"IDAT": idat.append(body)
        elif tag == b"IEND": break
        pos += 12 + ln
    raw = zlib.decompress(b"".join(idat))
    nch = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[ctype]
    if depth not in (8, 16):
        raise SystemExit("bit depth %d unsupported" % depth)
    bpp = nch * depth // 8
    stride = w * bpp
    out, prev, p = [], bytearray(stride), 0
    for _ in range(h):
        ft = raw[p]; p += 1
        line = bytearray(raw[p:p + stride]); p += stride
        if ft == 1:
            for i in range(bpp, stride): line[i] = (line[i] + line[i - bpp]) & 0xFF
        elif ft == 2:
            for i in range(stride): line[i] = (line[i] + prev[i]) & 0xFF
        elif ft == 3:
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 0xFF
        elif ft == 4:
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                c = prev[i - bpp] if i >= bpp else 0
                b = prev[i]
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 0xFF
        elif ft != 0:
            raise SystemExit("bad filter type %d" % ft)
        out.append(line); prev = line
    step, px = depth // 8, []
    for line in out:
        row = []
        for i in range(w):
            s = line[i * bpp:(i + 1) * bpp]
            v = [s[j * step] for j in range(nch)]
            if   ctype == 0: row.append((v[0], v[0], v[0], 255))
            elif ctype == 4: row.append((v[0], v[0], v[0], v[1]))
            elif ctype == 2: row.append((v[0], v[1], v[2], 255))
            elif ctype == 6: row.append((v[0], v[1], v[2], v[3]))
            else:
                idx = v[0]
                r, g, b = plte[idx * 3:idx * 3 + 3]
                row.append((r, g, b, trns[idx] if trns and idx < len(trns) else 255))
        px.append(row)
    return w, h, px


def resize(px, w, h, nw, nh):
    """Box filter over premultiplied alpha, so edges never pick up colour from
    fully transparent pixels."""
    res = []
    for y in range(nh):
        y0, y1 = y * h / nh, (y + 1) * h / nh
        row = []
        for x in range(nw):
            x0, x1 = x * w / nw, (x + 1) * w / nw
            ar = ag = ab = aa = n = 0.0
            for sy in range(int(y0), max(int(y0) + 1, min(h, int(y1) + (y1 > int(y1))))):
                if sy >= h: break
                for sx in range(int(x0), max(int(x0) + 1, min(w, int(x1) + (x1 > int(x1))))):
                    if sx >= w: break
                    r, g, b, a = px[sy][sx]
                    f = a / 255.0
                    ar += r * f; ag += g * f; ab += b * f; aa += a; n += 1
            if n == 0:
                row.append((0, 0, 0, 0)); continue
            aa /= n
            if aa <= 0.5:
                row.append((0, 0, 0, 0))
            else:
                f = aa / 255.0
                row.append((min(255, int(ar / n / f + .5)), min(255, int(ag / n / f + .5)),
                            min(255, int(ab / n / f + .5)), int(aa + .5)))
        res.append(row)
    return res


def write_png(path, w, h, px, bkgd=None):
    raw = bytearray()
    for row in px:
        raw.append(0)
        for r, g, b, a in row: raw += bytes((r, g, b, a))

    def chunk(tag, body):
        c = tag + body
        return struct.pack(">I", len(body)) + c + struct.pack(">I", zlib.crc32(c))
    out = b"\x89PNG\r\n\x1a\x0a" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
    if bkgd is not None:
        # bKGD for truecolour is three 16-bit samples, and must precede IDAT. The
        # nvidia X driver clears the whole screen to this colour before drawing the
        # logo, which is what turns a small tile into a full Mac-style boot screen.
        out += chunk(b"bKGD", struct.pack(">HHH", *(v * 257 for v in bkgd)))
    out += chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b"")
    open(path, "wb").write(out)


def write_png_raw(path, w, h, raw, ctype=6):
    def chunk(tag, body):
        c = tag + body
        return struct.pack(">I", len(body)) + c + struct.pack(">I", zlib.crc32(c))
    open(path, "wb").write(b"\x89PNG\r\n\x1a\x0a"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, ctype, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(bytes(raw), 6)) + chunk(b"IEND", b""))


def trim(px, w, h):
    ys = [y for y in range(h) if any(p[3] > 0 for p in px[y])]
    xs = [x for x in range(w) if any(px[y][x][3] > 0 for y in range(h))]
    if not ys or not xs: return w, h, px
    y0, y1, x0, x1 = ys[0], ys[-1], xs[0], xs[-1]
    return x1 - x0 + 1, y1 - y0 + 1, [r[x0:x1 + 1] for r in px[y0:y1 + 1]]


mode = sys.argv[1]
if mode == "flat":
    # Composite RGBA over an opaque background and tag it with bKGD. The nvidia X
    # driver does not document alpha handling for LogoPath, so it gets a fully opaque
    # image, and bKGD makes it clear the whole screen to the same colour.
    src, dst = sys.argv[2], sys.argv[3]
    br, bg_, bb = map(int, sys.argv[4:7])
    w, h, px = read_png(src)
    out = [[(int(r * a / 255 + br * (1 - a / 255) + .5),
             int(g * a / 255 + bg_ * (1 - a / 255) + .5),
             int(b * a / 255 + bb * (1 - a / 255) + .5), 255)
            for r, g, b, a in row] for row in px]
    write_png(dst, w, h, out, bkgd=(br, bg_, bb))
    print("%s %dx%d (flattened, bKGD=%d,%d,%d)" % (dst, w, h, br, bg_, bb))
elif mode == "bg":
    # Full-screen GRUB background: the logo composited onto a solid field at the same
    # place the plymouth theme puts it, so GRUB's load phase and the splash line up.
    logo, dst = sys.argv[2], sys.argv[3]
    W, H, br, bgc, bb, ypct = map(int, sys.argv[4:10])
    lw, lh, lpx = read_png(logo)
    lx, ly = (W - lw) // 2, int(H * ypct / 100 - lh / 2)
    # 8-bit RGB, no alpha: the most conservative thing to hand GRUB's png reader. The
    # image is fully opaque anyway, so nothing is lost by dropping the alpha channel.
    bgrow = bytes((br, bgc, bb)) * W
    raw = bytearray()
    for y in range(H):
        raw.append(0)                      # filter type 0
        if ly <= y < ly + lh:
            row = bytearray(bgrow)
            src = lpx[y - ly]
            for x in range(lw):
                r, g, b, a = src[x]
                if a == 0:
                    continue
                o = (lx + x) * 3
                if a == 255:
                    row[o:o + 3] = bytes((r, g, b))
                else:
                    f = a / 255.0
                    row[o:o + 3] = bytes((int(r * f + br * (1 - f) + .5),
                                          int(g * f + bgc * (1 - f) + .5),
                                          int(b * f + bb * (1 - f) + .5)))
            raw += row
        else:
            raw += bgrow
    write_png_raw(dst, W, H, raw, ctype=2)
    print("%s %dx%d (grub background, 8-bit RGB)" % (dst, W, H))
elif mode == "solid":
    out = sys.argv[2]; w, h, r, g, b, a = map(int, sys.argv[3:9])
    write_png(out, w, h, [[(r, g, b, a)] * w for _ in range(h)])
    print("%s %dx%d" % (out, w, h))
elif mode == "norm":
    src, dst, th = sys.argv[2], sys.argv[3], int(sys.argv[4])
    colour = sys.argv[5] if len(sys.argv) > 5 else "keep"
    w, h, px = read_png(src)
    w, h, px = trim(px, w, h)
    if colour != "keep":
        # "white"/"black" or any 0-255 grey level; alpha is always preserved.
        v = 255 if colour == "white" else 0 if colour == "black" else max(0, min(255, int(colour)))
        px = [[(v, v, v, p[3]) for p in row] for row in px]
    nw = max(1, int(round(w * th / h)))
    write_png(dst, nw, th, resize(px, w, h, nw, th))
    print("%s %dx%d (from %dx%d, %s)" % (dst, nw, th, w, h, colour))
else:
    raise SystemExit(__doc__)
PYTOOL

command -v python3 >/dev/null || die "python3 is required"

# ----------------------------------------------------------------- get the logo
SRC=$TMP/src.png
if [ -n "$LOGO" ]; then
    [ -f "$LOGO" ] || die "LOGO=$LOGO does not exist"
    cp "$LOGO" "$SRC"
    log "Logo: $LOGO"
else
    command -v curl >/dev/null || die "curl is required to fetch the logo (or pass LOGO=...)"
    WM='https://commons.wikimedia.org/wiki/Special:FilePath/Apple_logo_black.svg?width=512'
    GHURL='https://raw.githubusercontent.com/ABATBeliever/Plymouth-theme-mac/main/plymouth-theme-mac-white/apple-logo.png'
    # Wikimedia answers 200 with an HTML error page for a bad title, so check the magic.
    is_png() { python3 -c 'import sys; sys.exit(0 if open(sys.argv[1],"rb").read(8)==b"\x89PNG\r\n\x1a\n" else 1)' "$1"; }
    if curl -fsL --max-time 30 "$WM" -o "$SRC" && [ -s "$SRC" ] && is_png "$SRC"; then
        log "Logo: Wikimedia Commons Apple_logo_black.svg"
    elif curl -fsL --max-time 30 "$GHURL" -o "$SRC" && [ -s "$SRC" ]; then
        log "Logo: ABATBeliever/Plymouth-theme-mac (MIT)"
    else
        die "could not fetch an Apple logo; pass one with LOGO=/path/to/logo.png"
    fi
fi

# --------------------------------------------------------------- build the theme
log "Building theme in $THEMEDIR (variant: $VARIANT, logo height: ${LOGO_HEIGHT}px)"
rm -rf "$THEMEDIR"; mkdir -p "$THEMEDIR"

python3 "$TMP/pngtool.py" norm "$SRC" "$THEMEDIR/logo.png" "$LOGO_HEIGHT" "$LOGO_COLOUR" >&2

# Bar images are 8x8 solids; the theme scales them at runtime.
python3 "$TMP/pngtool.py" solid "$THEMEDIR/bar_fg.png" 8 8 "$FG"    "$FG"    "$FG"    255 >&2
python3 "$TMP/pngtool.py" solid "$THEMEDIR/bar_bg.png" 8 8 "$TRACK" "$TRACK" "$TRACK" 255 >&2

# Full-screen GRUB background. GRUB spends a few seconds reading the kernel and the
# 88 MB initrd before the kernel even starts, and whatever it left on the framebuffer is
# what you stare at until plymouth draws at ~2s. Handing GRUB this image means that whole
# stretch shows the same grey field and Apple logo the splash then continues.
GBW=${GFXMODE%%x*}; GBH=${GFXMODE##*x}
case "${GBW:-}${GBH:-}" in ''|*[!0-9]*) GBW=1280; GBH=800 ;; esac
python3 "$TMP/pngtool.py" bg "$THEMEDIR/logo.png" "$GRUBBG" "$GBW" "$GBH" \
    "$BGB" "$BGB" "$BGB" 42 >&2

# Opaque copy for the nvidia X splash (see the xorg drop-in further down).
python3 "$TMP/pngtool.py" flat "$THEMEDIR/logo.png" "$THEMEDIR/nvidia-logo.png" \
    "$BGB" "$BGB" "$BGB" >&2

cat > "$THEMEDIR/$THEME.plymouth" <<EOF
[Plymouth Theme]
Name=Mac Boot
Description=Black screen, centred Apple logo, thin progress bar
ModuleName=script

[script]
ImageDir=$THEMEDIR
ScriptFile=$THEMEDIR/$THEME.script
EOF

# Deliberately conservative: every construct below appears in the shipped mint-logo
# theme's live code path. In particular methods are only ever called on a *variable*
# (mint does `spinner.image.Rotate(...)`), never chained onto a call result like
# `Image("x").Scale(...)` -- a script that fails to parse makes plymouth paint nothing
# at all, which is indistinguishable from "no splash" behind quiet/loglevel=0.
# Sprite positions use SetX/SetY/SetZ rather than SetPosition for the same reason.
cat > "$THEMEDIR/$THEME.script" <<EOF
# Mac-style boot splash for plymouth 0.9.x (script module).

Window.SetBackgroundTopColor($BG, $BG, $BG);
Window.SetBackgroundBottomColor($BG, $BG, $BG);

global.sw = Window.GetWidth();
global.sh = Window.GetHeight();
global.ox = Window.GetX();
global.oy = Window.GetY();

logo.image  = Image("logo.png");
logo.width  = logo.image.GetWidth();
logo.height = logo.image.GetHeight();
logo.x = global.ox + (global.sw - logo.width) / 2;
# macOS centres the mark a little above the middle and puts the bar around 2/3 down.
# Anchoring both to screen fractions (rather than stacking the bar under the logo)
# keeps the layout sane on short framebuffers, where 640x480 is a real possibility.
logo.y = global.oy + global.sh * 42 / 100 - logo.height / 2;
logo.sprite = Sprite();
logo.sprite.SetImage(logo.image);
logo.sprite.SetX(logo.x);
logo.sprite.SetY(logo.y);
logo.sprite.SetZ(1);

bar.width  = global.sw / 4;
bar.height = 6;
bar.x = global.ox + (global.sw - bar.width) / 2;
bar.y = global.oy + global.sh * 68 / 100;

bar.track_image = Image("bar_bg.png");
bar.track_scaled = bar.track_image.Scale(bar.width, bar.height);
bar.track = Sprite();
bar.track.SetImage(bar.track_scaled);
bar.track.SetX(bar.x);
bar.track.SetY(bar.y);
bar.track.SetZ(1);

bar.fill_image = Image("bar_fg.png");
bar.fill = Sprite();
bar.fill.SetX(bar.x);
bar.fill.SetY(bar.y);
bar.fill.SetZ(2);
bar.fill.SetOpacity(0);

fun draw_progress (p) {
    local.frac = p;
    if (local.frac > 1) local.frac = 1;
    local.w = bar.width * local.frac;
    if (local.w < 1) local.w = 1;
    local.img = bar.fill_image.Scale(local.w, bar.height);
    bar.fill.SetImage(local.img);
    bar.fill.SetOpacity(1);
}

# Progress must never go backwards: plymouth can report a lower estimate after a
# slow step, which would look like the bar rewinding.
fun on_boot_progress (duration, progress) {
    if (global.progress == NULL) global.progress = 0;
    if (progress > global.progress) global.progress = progress;
    draw_progress(global.progress);
}
Plymouth.SetBootProgressFunction(on_boot_progress);

# Password prompt (LUKS): hide the bar, show the prompt plus one bullet per keystroke.
prompt.sprite = Sprite();
prompt.sprite.SetOpacity(0);

fun on_display_password (prompt_text, bullets) {
    bar.track.SetOpacity(0);
    bar.fill.SetOpacity(0);
    local.dots = "";
    for (i = 0; i < bullets; i++) {
        local.dots += "*";
    }
    local.img = Image.Text(prompt_text + "  " + local.dots, $TXT);
    prompt.sprite.SetImage(local.img);
    prompt.sprite.SetX(global.ox + (global.sw - local.img.GetWidth()) / 2);
    prompt.sprite.SetY(bar.y);
    prompt.sprite.SetZ(3);
    prompt.sprite.SetOpacity(1);
}
Plymouth.SetDisplayPasswordFunction(on_display_password);

fun on_display_normal () {
    prompt.sprite.SetOpacity(0);
    bar.track.SetOpacity(1);
    if (global.progress != NULL) draw_progress(global.progress);
}
Plymouth.SetDisplayNormalFunction(on_display_normal);

fun on_quit () {
    logo.sprite.SetOpacity(0);
    bar.track.SetOpacity(0);
    bar.fill.SetOpacity(0);
    prompt.sprite.SetOpacity(0);
}
Plymouth.SetQuitFunction(on_quit);
EOF

if [ "$DRYRUN" = 1 ]; then
    log "dry run complete -- generated:"
    ls -la "$THEMEDIR" >&2
    printf -- '--- %s.script ---\n' "$THEME" >&2
    cat "$THEMEDIR/$THEME.script" >&2
    exit 0
fi

# --------------------------------------------------------- register + initramfs
if [ ! -f "$PREV_FILE" ]; then
    prev=$(update-alternatives --query default.plymouth 2>/dev/null \
           | awk '/^Value: /{print $2}')
    [ -n "$prev" ] && printf '%s\n' "$prev" > "$PREV_FILE" && log "Saved current theme: $prev"
fi

update-alternatives --install /usr/share/plymouth/themes/default.plymouth \
    default.plymouth "$THEMEDIR/$THEME.plymouth" 300 >/dev/null
update-alternatives --set default.plymouth "$THEMEDIR/$THEME.plymouth" >/dev/null
log "Default plymouth theme: $THEME"

# --------------------------------------------------- nvidia X startup splash
# The proprietary nvidia driver draws its own logo when the X server starts, which
# would appear after the plymouth splash. 340.108 exposes a LogoPath option
# (strings nvidia_drv.so: "Loading logo file", "Logo file \"%s\" is not a PNG file"),
# so the built-in logo can be swapped for the Apple one rather than merely disabled
# with NoLogo. The driver refuses logo files that are not root-owned or that are
# group/world writable.
NVIDIA_DRV=$(ls /usr/lib/nvidia-*/xorg/nvidia_drv.so \
                /usr/lib/x86_64-linux-gnu/nvidia/xorg/nvidia_drv.so 2>/dev/null | head -1 || true)
if [ -n "$NVIDIA_DRV" ]; then
    chown root:root "$THEMEDIR/nvidia-logo.png"
    chmod 644 "$THEMEDIR/nvidia-logo.png"

    # A bare Device section in /etc/X11/xorg.conf.d does NOT win: with no ServerLayout
    # or Screen section Xorg picks the first Device it finds and demotes the rest to
    # GPUDevice, and the package's "Nvidia Card" came first --
    #   (**) |   |-->Device "Nvidia Card"
    #   (**) |   |-->GPUDevice "MacBook NVIDIA"
    # so the option never applied. A full xorg.conf with an explicit Screen->Device
    # link removes the ambiguity. This is the same shape nvidia-xconfig generates.
    rm -f "$NVIDIA_XORG_CONF"
    # Only ever back up a *pre-existing* xorg.conf. Guarding on "no backup yet" alone meant a
    # second run happily saved our own generated file as the original, which would have made
    # --revert restore this config instead of removing it.
    if [ -f "$XORG_BAK" ] && grep -q 'set-mac-boot-splash' "$XORG_BAK" 2>/dev/null; then
        rm -f "$XORG_BAK"
        warn "Discarded $XORG_BAK -- it was a copy of our own config, not the original"
    fi
    if [ -f /etc/X11/xorg.conf ] && [ ! -f "$XORG_BAK" ] \
       && ! grep -q 'set-mac-boot-splash' /etc/X11/xorg.conf; then
        cp /etc/X11/xorg.conf "$XORG_BAK"
        log "Backed up the existing /etc/X11/xorg.conf -> $XORG_BAK"
    fi
    # NoLogo by default: an Apple logo here flashes for a moment between the plymouth
    # splash and the greeter, which reads as busier than showing nothing. --nvidia-logo
    # swaps in LogoPath instead (the file must be root-owned and not group/world
    # writable, is only drawn at depth 24, and its bKGD chunk sets the clear colour).
    if [ "$NVLOGO" = 1 ]; then
        nv_opt="    Option      \"LogoPath\" \"$THEMEDIR/nvidia-logo.png\""
    else
        nv_opt="    Option      \"NoLogo\" \"true\""
    fi
    cat > /etc/X11/xorg.conf <<EOF
# Written by set-mac-boot-splash.sh -- remove with: $0 --revert
Section "ServerLayout"
    Identifier  "MacBook Layout"
    Screen  0   "MacBook Screen" 0 0
EndSection

Section "Device"
    Identifier  "MacBook NVIDIA"
    Driver      "nvidia"
    VendorName  "NVIDIA Corporation"
$nv_opt
EndSection

Section "Screen"
    Identifier   "MacBook Screen"
    Device       "MacBook NVIDIA"
    DefaultDepth 24
EndSection
EOF
    if [ "$NVLOGO" = 1 ]; then
        log "nvidia X splash -> $THEMEDIR/nvidia-logo.png (/etc/X11/xorg.conf)"
    else
        log "nvidia X splash -> disabled via NoLogo (/etc/X11/xorg.conf)"
    fi
else
    warn "no nvidia_drv.so found; skipping the nvidia X splash override"
    warn "re-run this script after nvidia-340 is installed to pick it up"
fi

# ------------------------------------------------------------------ grub tweaks
# As with xorg.conf: never let a re-run overwrite the pristine backup with an edited copy.
if [ -f "$GRUB_BAK" ] && grep -q 'plymouth.ignore-udev' "$GRUB_BAK" 2>/dev/null; then
    rm -f "$GRUB_BAK"
    warn "Discarded $GRUB_BAK -- it already carried our own settings"
fi
[ -f /etc/default/grub ] && [ ! -f "$GRUB_BAK" ] && cp /etc/default/grub "$GRUB_BAK"

set_grub() {   # key value
    if grep -qE "^[#]?$1=" /etc/default/grub; then
        sed -i "s|^[#]\?$1=.*|$1=$2|" /etc/default/grub
    else
        printf '%s=%s\n' "$1" "$2" >> /etc/default/grub
    fi
}

# quiet+splash are what hand control to plymouth; loglevel/cursor suppress the
# kernel text that would otherwise flash over the splash.
#
# plymouth.ignore-udev is the one that actually makes the splash appear here.
# nvidia-340 registers a KMS-less /dev/dri/card0, and plymouth's device manager, on
# seeing a DRM-subsystem device, commits to the drm renderer for it:
#   found DRM device /dev/dri/card0
#   plugin.c:1544:query_device : Could not get card resources
#   ply-renderer.c:287 : could not find suitable rendering plugin
#   main.c:953:on_show_splash : no displays available to show splash on, waiting...
# It never falls back to frame-buffer.so for that device, so nothing is ever drawn.
# ignore-udev skips udev enumeration entirely and builds devices from terminals with
# renderer type AUTO, which lands on frame-buffer.so over efifb. nouveau did not hit
# this because its DRM node is a real KMS device.
#
# Rebuild only the tokens this script owns, so repeated runs stay idempotent and
# --debug-boot can be toggled off again without leaving leftovers behind.
old=$(sed -n 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"$/\1/p' /etc/default/grub | head -1)
keep=""
for tok in $old; do
    case "$tok" in
        quiet|splash|loglevel=*|vt.global_cursor_default=*|plymouth.ignore-udev|plymouth.debug*) ;;
        *) keep="${keep:+$keep }$tok" ;;
    esac
done
if [ "$DEBUGBOOT" = 1 ]; then
    # quiet/loglevel=0 are deliberately left out: with them the console hides exactly
    # the messages worth reading when the splash misbehaves.
    cur="${keep:+$keep }splash plymouth.ignore-udev plymouth.debug=file:$BOOTLOG"
else
    cur="${keep:+$keep }quiet splash loglevel=0 vt.global_cursor_default=0 plymouth.ignore-udev"
fi
set_grub GRUB_CMDLINE_LINUX_DEFAULT "\"$cur\""
set_grub GRUB_TIMEOUT_STYLE hidden
set_grub GRUB_TIMEOUT 0
# Ubuntu's 00_header emits `if [ "$recordfail" = 1 ]; then set timeout=30`, so a single
# unclean shutdown makes every later boot sit on the menu for 30s. 0 keeps it instant.
set_grub GRUB_RECORDFAIL_TIMEOUT 0
set_grub GRUB_GFXPAYLOAD_LINUX keep
# 05_debian_theme wraps this in `if background_image ...; then`, so a load failure
# falls back to the default theme rather than breaking the menu.
set_grub GRUB_BACKGROUND "$GRUBBG"

# grub.cfg runs `loadfont $font` (line ~98) *before* `terminal_output gfxterm` (~106), so
# GRUB reads the font through its ext4 driver while the screen is still the firmware's
# text console -- cursor and all. The default unicode.pf2 is 2.4 MB; ascii.pf2 is 5 KB.
# 00_header emits `if loadfont <GRUB_FONT>` directly when GRUB_FONT is set. Menu text here
# is ASCII, and the menu is hidden anyway, so the coverage loss does not matter.
# The setpci writes are required -- without them the panel goes black once nvidia-340 takes
# the GPU -- but they also keep GRUB's own graphics off the display: after they run, the
# framebuffer GRUB set up is no longer scanned out, so GRUB renders into nothing while a
# stale EFI console (black, with its cursor) stays on screen. Evidence: with --grub-pause,
# `sleep` clearly ran yet not one character appeared. 09_ sorts after 00_header's gfxterm
# setup and the background image, but before 10_linux's menuentries load the kernel.
for stale in /etc/grub.d/00_enable_vga /etc/grub.d/01_enable_vga; do
    if [ -e "$stale" ]; then
        mv "$stale" /etc/grub.d/09_enable_vga
        log "Moved $(basename "$stale") -> 09_enable_vga (setpci now runs after GRUB draws)"
    fi
done
[ -e /etc/grub.d/09_enable_vga ] && chmod 755 /etc/grub.d/09_enable_vga

if [ -f /usr/share/grub/ascii.pf2 ]; then
    install -D -m 644 /usr/share/grub/ascii.pf2 "$GRUBFONT"
    set_grub GRUB_FONT "$GRUBFONT"
    log "GRUB_FONT -> $GRUBFONT (5 KB instead of 2.4 MB unicode.pf2)"
fi
[ -n "$GFXMODE" ] && set_grub GRUB_GFXMODE "$GFXMODE"
log "GRUB_CMDLINE_LINUX_DEFAULT=\"$cur\""

# GRUB echoes "Loading Linux ..." and "Loading initial ramdisk ..." from inside each
# menuentry, so that text lands on screen in the second before the kernel starts. The
# echoes come from /etc/grub.d/10_linux, which is a conffile -- editing it is supported
# and survives upgrades (dpkg prompts if the package changes it too).
#
# The lines sit inside a `cat << EOF` heredoc, so prefixing them with '#' emits a GRUB
# comment instead of a command. ^[^#]* keeps it idempotent: an already-prefixed line no
# longer matches.
mkdir -p "$(dirname "$GRUB10_BAK")"
if [ -f "$GRUB10_BAK_BAD" ]; then
    warn "Found $GRUB10_BAK_BAD -- grub-mkconfig was executing it and duplicating menu entries"
    if [ -f "$GRUB10_BAK" ]; then rm -f "$GRUB10_BAK_BAD"; else mv "$GRUB10_BAK_BAD" "$GRUB10_BAK"; fi
    log "Moved the backup out of /etc/grub.d -> $GRUB10_BAK"
fi
if [ -f "$GRUB10" ]; then
    [ -f "$GRUB10_BAK" ] || cp "$GRUB10" "$GRUB10_BAK"
    before=$(grep -c '^[^#]*\$message" | grub_quote' "$GRUB10" || true)
    sed -i '/^[^#]*\$message" | grub_quote/ s/^/#/' "$GRUB10"
    [ "$before" -gt 0 ] && log "Silenced $before GRUB progress echo(es) in $GRUB10"
fi

# The cursor visible before the splash is GRUB's, not the kernel's: the boot log shows
# "fbcon: Deferring console take-over" and no take-over afterwards, so the kernel never
# draws on the framebuffer, and whatever GRUB left there stays until plymouth starts.
# GRUB has no cursor-off command, so give normal text the same fg and bg -- the cursor is
# drawn in the fg colour and becomes invisible. The menu is unaffected: grub.cfg sets
# menu_color_normal/menu_color_highlight separately (its entries stay readable if you
# hold Shift), though GRUB's own help text and error messages go invisible too.
# light-gray (#aaa) is the closest named colour to the splash background, so the handover
# is a small brightness step rather than white-on-black.
# Paint the splash at the earliest moment GRUB is capable of it. The firmware text cursor
# is on screen from the moment the loader is handed control until GRUB's video is up, so the
# only way to shorten that is to bring the video setup forward. 00_header does it around
# line 100 of grub.cfg; this does the same work as the very first thing, before 00_header's
# variable and function preamble and its `search` calls.
#
# It cannot cover the whole cursor window: Apple's firmware and GRUB's own core load before
# any of grub.cfg runs, and nothing here can draw during that.
#
# Everything is guarded, and 00_header's own block still runs afterwards, so a failure here
# just means the old behaviour rather than a broken boot.
# --logo-hold N deliberately holds the painted splash for N seconds. The screen is painted
# on every boot already, but GRUB's only remaining job afterwards is reading vmlinuz plus a
# 37 MB initrd, so it passes in a fraction of a second -- which reads as "the logo screen is
# gone". A hold trades N seconds of boot time for the Mac-like sequence of logo first, then
# progress bar. It cannot shorten the cursor: that window is over before GRUB can draw.
if [ "$LOGOHOLD" != "0" ]; then
    hold_line="  sleep $LOGOHOLD"
else
    hold_line=""
fi
cat > "$GRUBEARLY" <<GE
#!/bin/sh
# Written by set-mac-boot-splash.sh -- runs before 00_header.
# No part_gpt/ext2/search here. GRUB's core already set \$root to the partition holding
# \$prefix -- which is where this font and PNG live -- so the search was redundant, and
# worse: written without --hint-* it makes GRUB enumerate every device, including the empty
# optical drive, before anything gets painted. That is delay added to the exact window this
# script exists to shorten.
cat <<EOF
insmod all_video
insmod font
if loadfont $GRUBFONT ; then
  set gfxmode=auto
  insmod gfxterm
  terminal_output gfxterm
  insmod png
  background_image -m stretch $GRUBBG
  set color_normal=light-gray/light-gray
$hold_line
fi
EOF
GE
chmod 755 "$GRUBEARLY"
log "Installed $GRUBEARLY (splash painted as GRUB's first action)"

cat > "$GRUBQUIET" <<GQ
#!/bin/sh
# Written by set-mac-boot-splash.sh -- runs after 00_header/05_debian_theme, so this wins.
#
# Getting the background image actually painted took three tries, all observed on screen:
#   clear            -> flat light-gray, no logo (clear fills with the colour, not the image)
#   nothing          -> nothing painted at all; the stale black EFI console and its cursor stay
#   terminal round-trip -> grey field with the Apple logo, which is what we want
# So the image is re-set and then gfxterm is re-activated, which is the only sequence that
# demonstrably triggers a full redraw from the bitmap. No clear: it would overwrite it again.
#
# color_normal also makes the cursor effectively invisible -- gfxterm draws it in the
# foreground colour, and light-gray on this grey field does not read as a cursor.
cat <<EOF
set color_normal=light-gray/light-gray
background_image -m stretch $GRUBBG
terminal_output console
terminal_output gfxterm
EOF
GQ
chmod 755 "$GRUBQUIET"
log "Installed $GRUBQUIET (cursor colour matched to the background)"

# --grub-pause N holds GRUB on screen for N seconds right after the background is set, so
# what GRUB actually renders can be observed instead of inferred. Reasoning has gone back
# and forth here: `clear` produced black, which says gfxterm never engaged, yet shrinking
# the font measurably shortened the cursor, which says grub.cfg is running. Only forcing a
# long, deliberate look at that moment settles it.
if [ "${GRUBPAUSE:-0}" != "0" ]; then
    cat > "$GRUBPAUSESCRIPT" <<GP
#!/bin/sh
# Written by set-mac-boot-splash.sh --grub-pause $GRUBPAUSE -- diagnostic, safe to delete.
cat <<'EOF'
# Force output back to the firmware console before printing anything: that terminal is
# known to work (it is what draws the cursor), so whatever appears here is trustworthy.
# Also undo 06_mac_quiet's foreground==background colours, which made an earlier version of
# this test unreadable by construction.
terminal_output console
set color_normal=white/black
clear
echo "=== mac-boot GRUB diagnostic"
echo "-- videoinfo (does GRUB have a working video driver?)"
videoinfo
echo "-- now switching to gfxterm; a grey screen with an apple logo means it works"
terminal_output gfxterm
echo "gfxterm active"
EOF
echo "sleep $GRUBPAUSE"
GP
    chmod 755 "$GRUBPAUSESCRIPT"
    warn "Installed $GRUBPAUSESCRIPT -- boot will pause ${GRUBPAUSE}s in GRUB"
    warn "Remove it by re-running without --grub-pause"
elif [ -f "$GRUBPAUSESCRIPT" ]; then
    rm -f "$GRUBPAUSESCRIPT"
    log "Removed $GRUBPAUSESCRIPT"
fi

# ------------------------------------------------- framebuffer-only initramfs
# Boot log, initramfs stage, with nvidia-340 (no KMS, and nvidia.ko is not even in the
# initramfs, so /dev/dri/card0 does not exist yet):
#   drm.so          create_backend for device /dev/dri/card0 -> open failed
#   frame-buffer.so create_backend for device /dev/dri/card0 -> could not open
#   -> no pixel displays -> falls back to text.plymouth
# frame-buffer.so's own default is /dev/fb0; it only sees /dev/dri/card0 because the
# preceding drm.so attempt leaves that path in renderer->device_name. Dropping drm.so
# from the initramfs breaks that chain, so the framebuffer renderer gets a NULL device
# and uses /dev/fb0 (efifb, 1280x800x32 here). nouveau never hit this: its card0 is a
# real KMS device, so drm.so succeeded outright.
if [ "$FBONLY" = 1 ]; then
    cat > "$FBHOOK" <<'HOOK'
#!/bin/sh
# Written by set-mac-boot-splash.sh --fb-only
# PREREQ makes this run after the packaged plymouth hook has populated $DESTDIR.
PREREQ="plymouth"
prereqs() { echo "$PREREQ"; }
case $1 in prereqs) prereqs; exit 0 ;; esac
. /usr/share/initramfs-tools/hook-functions

# Force plymouth onto the framebuffer renderer by removing the DRM one. Deleting a file
# from $DESTDIR is fine; *adding* a script would not be (see the note by $EARLYSCRIPT).
rm -f "$DESTDIR"/usr/lib/*/plymouth/renderers/drm.so
HOOK
    if [ "$EARLY" = 1 ]; then
        cat >> "$FBHOOK" <<'HOOK'

# With plymouth-early in init-top, the packaged init-premount/plymouth is a duplicate:
# its `mkdir /run/plymouth` and second `plymouthd` both fail and print to the initramfs
# console, on top of the splash. Removing it from $DESTDIR *does* drop it from ORDER --
# cache_run_scripts skips names missing from $DESTDIR -- which is the reverse of adding.
rm -f "$DESTDIR/scripts/init-premount/plymouth"
HOOK
    fi
    chmod 755 "$FBHOOK"
    log "Installed $FBHOOK (drm.so excluded from the initramfs)"
elif [ -f "$FBHOOK" ]; then
    rm -f "$FBHOOK"
    log "Removed $FBHOOK (drm.so back in the initramfs)"
fi

# ------------------------------------------------------ start plymouth earlier
# The packaged scripts/init-premount/plymouth declares PREREQ="udev", so it waits on the
# `udevadm settle` in scripts/init-top/udev -- ~4.6s here, because MODULES=most puts 1366
# modules in the initrd to coldplug. The screen shows nothing but a console cursor for
# that whole stretch. plymouth does not need udev: it renders on efifb, which the kernel
# registers (0.94s) before /init runs, and plymouth.ignore-udev stops it wanting udev at
# all.
#
# This must live in a *source* scripts dir, not be injected into $DESTDIR by a hook:
# set_initlist enumerates $DESTDIR but then maps each name through get_source to
# ${CONFDIR}/scripts/... or /usr/share/initramfs-tools/scripts/..., and skips anything
# whose source is missing or non-executable. A file only present in $DESTDIR is silently
# dropped from ORDER -- so it gets copied into the initramfs and never runs.
#
# The packaged premount script is deliberately left in place. Once this one holds the
# socket its plymouthd is a harmless no-op, and if anything here fails the splash still
# comes up the old way instead of not at all.
if [ "$EARLY" = 1 ]; then
    mkdir -p "$(dirname "$EARLYSCRIPT")"
    cat > "$EARLYSCRIPT" <<'EARLYEOF'
#!/bin/sh
# Written by set-mac-boot-splash.sh --early-splash
OPTION=FRAMEBUFFER
PREREQ=""

prereqs()
{
	echo "${PREREQ}"
}

case ${1} in
	prereqs)
		prereqs
		exit 0
		;;
esac

SPLASH="false"

for ARGUMENT in $(cat /proc/cmdline)
do
	case "${ARGUMENT}" in
		splash*)
			SPLASH="true"
			;;

		nosplash*|plymouth.enable=0)
			SPLASH="false"
			;;
	esac
done

# /run is a tmpfs that survives the switch to the real root, so these stamps are
# readable after boot. This is how the pre-splash gap gets measured without turning on
# plymouth.debug, which would put text back on the console.
stamp() {
	read _up _idle < /proc/uptime
	echo "$1 uptime=$_up" >> /run/plymouth-early.stamp
}

if [ "${SPLASH}" = "true" ]
then
	stamp "init-top/plymouth-early entered"
	mkdir -p -m 0755 /run/plymouth
	/sbin/plymouthd --mode=boot --attach-to-session --pid-file=/run/plymouth/pid
	stamp "plymouthd exited rc=$?"
	/bin/plymouth --show-splash
	stamp "show-splash exited rc=$?"
else
	stamp "no splash on cmdline"
fi
EARLYEOF
    chmod 755 "$EARLYSCRIPT"
    log "Installed $EARLYSCRIPT (runs before init-top/udev)"
elif [ -f "$EARLYSCRIPT" ]; then
    rm -f "$EARLYSCRIPT"
    log "Removed $EARLYSCRIPT"
fi

# ------------------------------------------------------------ shrink the initrd
# GRUB never gets its graphics onto this panel, so the firmware text cursor is on screen
# for the whole GRUB phase -- which includes GRUB reading vmlinuz (9 MB) plus the initrd.
# MODULES=most puts 1366 modules and 88 MB in that initrd; MODULES=dep includes only what
# this hardware actually needs. Less for GRUB to read is directly less cursor.
#
# The previous initrd is kept as <img>.mac-boot.bak and 45_mac_fallback adds a menu entry
# that boots it, so a missing module is recoverable by holding Shift at power-on rather
# than by rescuing the machine from a live USB.
if [ "$SLIM" = 1 ]; then
    for img in /boot/initrd.img-*; do
        case "$img" in *.mac-boot.bak) continue ;; esac
        [ -f "$img.mac-boot.bak" ] || cp "$img" "$img.mac-boot.bak"
    done
    if grep -q '^MODULES=' /etc/initramfs-tools/initramfs.conf; then
        sed -i 's/^MODULES=.*/MODULES=dep/' /etc/initramfs-tools/initramfs.conf
    else
        printf 'MODULES=dep\n' >> /etc/initramfs-tools/initramfs.conf
    fi
    log "initramfs.conf: MODULES=dep"

    # MODULES=dep alone only got the initrd from 88 MB to 68 MB, because the bulk is not
    # modules but firmware: 91 MB of it, for hardware this MacBook does not have --
    # netronome 34 MB, amdgpu 32 MB, radeon 6 MB, liquidio 5 MB, i915 2.4 MB and so on.
    # Firmware in an initramfs only matters for devices needed before the real root is
    # mounted; root here is plain AHCI SATA, which needs none, and the full set stays in
    # /lib/firmware on the root filesystem. Broadcom wifi (brcm, b43) and the rest load from
    # there a moment later, exactly as they do now.
    cat > "$FWHOOK" <<'FWEOF'
#!/bin/sh
# Written by set-mac-boot-splash.sh --slim-initrd
PREREQ=""
prereqs() { echo "$PREREQ"; }
case $1 in prereqs) prereqs; exit 0 ;; esac

FW="$DESTDIR/usr/lib/firmware"
[ -d "$FW" ] || exit 0
before=$(du -sk "$FW" 2>/dev/null | awk '{print $1}')
# GPUs from other vendors, and datacentre NICs. Deliberately conservative: brcm, b43,
# mediatek, intel, rtl_nic and everything else are left alone.
for junk in netronome amdgpu radeon liquidio i915 cxgb3 cxgb4 mellanox qed vxge             bnx2 bnx2x slicoss acenic tehuti 3com qlogic             myri10ge_*.dat phanfw.bin ct2fw-*.bin ctfw-*.bin cbfw-*.bin
do
    rm -rf "$FW"/$junk
done
after=$(du -sk "$FW" 2>/dev/null | awk '{print $1}')
echo "zz-mac-slim-firmware: firmware ${before}K -> ${after}K" >&2
FWEOF
    chmod 755 "$FWHOOK"
    log "Installed $FWHOOK (drops firmware for absent hardware)"

    kver=$(uname -r)
    ruuid=$(findmnt -no UUID /)
    cat > "$FALLBACKMENU" <<EOF
#!/bin/sh
# Written by set-mac-boot-splash.sh --slim-initrd -- boots the pre-slim initrd.
cat <<MENU
menuentry 'Linux Mint -- fallback (full initrd)' --class mint {
    insmod part_gpt
    insmod ext2
    search --no-floppy --fs-uuid --set=root $ruuid
    linux /boot/vmlinuz-$kver root=UUID=$ruuid ro quiet splash
    initrd /boot/initrd.img-$kver.mac-boot.bak
}
MENU
EOF
    chmod 755 "$FALLBACKMENU"
    log "Installed $FALLBACKMENU (hold Shift at power-on to reach it)"
elif [ -f "$FALLBACKMENU" ]; then
    if grep -q '^MODULES=dep' /etc/initramfs-tools/initramfs.conf; then
        sed -i 's/^MODULES=dep/MODULES=most/' /etc/initramfs-tools/initramfs.conf
        log "initramfs.conf: MODULES back to most"
    fi
    rm -f "$FALLBACKMENU" "$FWHOOK"
    log "Removed $FALLBACKMENU and $FWHOOK"
fi

# --------------------------------------------------------------- fast boot
# Three measured delays, all avoidable on this machine:
#
# 1) raid6: sse2x4 gen() ... -- 1.89s (3.73s -> 5.62s in the kernel log). raid6_pq
#    benchmarks every raid6 implementation when it loads. There is no RAID and no LVM here
#    (fstab is plain UUIDs, root is sda2 ext4), so drivers/md has no reason to be in the
#    initramfs at all. Removing it means nothing can pull raid6_pq in that early.
# 2) networkd-dispatcher sits on the critical chain at +1.002s, and
#    NetworkManager-wait-online is enabled too. NetworkManager runs its own dispatcher, so
#    neither is doing anything for this desktop.
# 3) boot-efi.mount gates local-fs.target -> sysinit -> basic -> graphical, and the ESP
#    device only shows up at 4.07s. Mounting it on demand takes it off that chain; anything
#    that touches /boot/efi (grub-install, update-grub, apt) triggers the automount.
if [ "$FASTBOOT" = 1 ]; then
    cat > "$MDHOOK" <<'MDEOF'
#!/bin/sh
# Written by set-mac-boot-splash.sh --fast-boot
PREREQ=""
prereqs() { echo "$PREREQ"; }
case $1 in prereqs) prereqs; exit 0 ;; esac
# No RAID, no LVM, no dm-crypt on this box: drivers/md only costs a 1.9s raid6 benchmark.
rm -rf "$DESTDIR"/usr/lib/modules/*/kernel/drivers/md
rm -f  "$DESTDIR"/scripts/init-premount/lvm2
MDEOF
    chmod 755 "$MDHOOK"
    log "Installed $MDHOOK (drops drivers/md -- kills the 1.9s raid6 benchmark)"

    : > "$DISABLED_UNITS"
    for u in networkd-dispatcher.service NetworkManager-wait-online.service; do
        if [ "$(systemctl is-enabled "$u" 2>/dev/null)" = enabled ]; then
            systemctl disable "$u" >/dev/null 2>&1 && printf '%s\n' "$u" >> "$DISABLED_UNITS"
            log "Disabled $u"
        fi
    done

    if grep -qE '^[^#].*[[:space:]]/boot/efi[[:space:]]' /etc/fstab \
       && ! grep -q 'x-systemd.automount' /etc/fstab; then
        [ -f "$FSTAB_BAK" ] || cp /etc/fstab "$FSTAB_BAK"
        sed -i -E 's|^([^#]*[[:space:]]/boot/efi[[:space:]]+vfat[[:space:]]+)([^[:space:]]+)|\1\2,noauto,x-systemd.automount,x-systemd.idle-timeout=1min|' /etc/fstab
        systemctl daemon-reload
        log "/boot/efi now mounts on demand (backup: $FSTAB_BAK)"
        grep '/boot/efi' /etc/fstab | sed 's/^/   /' >&2
    fi
else
    if [ -f "$MDHOOK" ]; then rm -f "$MDHOOK"; log "Removed $MDHOOK"; fi
    if [ -s "$DISABLED_UNITS" ]; then
        while read -r u; do
            [ -n "$u" ] && systemctl enable "$u" >/dev/null 2>&1 && log "Re-enabled $u"
        done < "$DISABLED_UNITS"
        rm -f "$DISABLED_UNITS"
    fi
    if [ -f "$FSTAB_BAK" ]; then
        cp "$FSTAB_BAK" /etc/fstab && rm -f "$FSTAB_BAK"
        systemctl daemon-reload
        log "Restored /etc/fstab"
    fi
fi

log "update-initramfs -u"
update-initramfs -u
if command -v update-grub >/dev/null; then log "update-grub"; update-grub; fi

cat >&2 <<EOF

$(printf '\033[1;32m==\033[0m') Installed. Reboot to see it.
${DEBUGBOOT:+}$([ "$DEBUGBOOT" = 1 ] && printf '%s' "
Boot debugging is ON: quiet/loglevel=0 are off and plymouth writes $BOOTLOG.
After rebooting, read it with:
  sudo $0 --show-boot-log
Then turn it off by running this script again with no flags.
")

What changed:
  plymouth boot splash   $THEMEDIR
  nvidia X startup logo  ${NVIDIA_DRV:+$NVIDIA_XORG_CONF}${NVIDIA_DRV:-(skipped, nvidia driver not installed yet)}
  kernel cmdline / gfx   /etc/default/grub  (backup: $GRUB_BAK)

Preview the plymouth splash without rebooting (from a text VT, e.g. Ctrl+Alt+F2):
  sudo plymouthd --debug --tty=/dev/tty2 ; sudo plymouth --show-splash
  sudo plymouth update --status=test ; sleep 5 ; sudo plymouth quit

Revert everything:
  sudo $0 --revert

Caveat on this hardware: nvidia-340 provides no KMS, so plymouth cannot use the DRM
renderer and falls back to whatever framebuffer GRUB set up. That is why
GRUB_GFXMODE${GFXMODE:+=$GFXMODE} and GRUB_GFXPAYLOAD_LINUX=keep are set above. If the splash still
comes up as plain text, the framebuffer is missing -- check "sudo plymouth --debug"
output and /sys/class/graphics/fb0.
EOF
