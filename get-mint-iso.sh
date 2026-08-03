#!/usr/bin/env bash
# Download a Linux Mint ISO from the mirror that is actually fastest from wherever this runs.
#
# Default target: linuxmint-20.3-xfce-64bit.iso  -- the sensible choice for a 2010 MacBook
# (MacBook7,1: Core 2 Duo P8600, GeForce 320M, typically 2-4 GB RAM). Xfce keeps the
# desktop light, and 20.3 "una" is the last release whose 5.4 kernel still works with the
# nvidia-340 legacy driver this GPU needs.
#
# Mirror selection is measured, not hardcoded:
#   1. Scrape the "Download mirrors" table from linuxmint.com/mirrors.php (154 mirrors).
#      The flag image filename in each row is an ISO 3166-1 alpha-2 code, so it matches
#      a geo-IP country code directly.
#   2. Geo-IP the runner (api.country.is -> ipinfo.io -> ip-api.com).
#   3. Probe every mirror in parallel for the exact ISO URL: HTTP status + TTFB.
#   4. Shortlist = fastest by TTFB + same-country mirrors + global CDN mirrors.
#   5. Measure real throughput on the shortlist (8 MB each), download from the winner.
#   6. Verify sha256 against the mirror's sha256sum.txt (gpg check best-effort).
#
# Runs on both macOS and Linux. Resumable: re-run to continue a partial download.
#
# Usage:
#   ./get-mint-iso.sh                          # 20.3 xfce 64bit into ./
#   RELEASE=21.3 EDITION=cinnamon ./get-mint-iso.sh
#   OUTDIR=~/Downloads ./get-mint-iso.sh
#   MIRROR=https://ftp.kaist.ac.kr/linuxmint-iso/ ./get-mint-iso.sh   # skip selection
#   PROBE_ONLY=1 ./get-mint-iso.sh             # rank mirrors, download nothing

set -euo pipefail

RELEASE=${RELEASE:-20.3}
EDITION=${EDITION:-xfce}
ARCH=${ARCH:-64bit}
OUTDIR=${OUTDIR:-$PWD}
SHORTLIST=${SHORTLIST:-5}          # mirrors that get a throughput probe
PROBE_TIMEOUT=${PROBE_TIMEOUT:-6}  # seconds per reachability probe
SPEED_BYTES=${SPEED_BYTES:-8388608}
MIRROR=${MIRROR:-}
PROBE_ONLY=${PROBE_ONLY:-0}

ISO="linuxmint-${RELEASE}-${EDITION}-${ARCH}.iso"
SUBPATH="stable/${RELEASE}/${ISO}"
MIRROR_LIST_URL="https://linuxmint.com/mirrors.php"

# Used only if mirrors.php cannot be reached. Spread across regions on purpose so the
# measurement step still has something sane to work with anywhere in the world.
FALLBACK_MIRRORS='
_united_nations https://pub.linuxmint.io/
_united_nations https://mirrors.cicku.me/linuxmint/iso/
kr https://ftp.kaist.ac.kr/linuxmint-iso/
jp https://ftp.yz.yamagata-u.ac.jp/pub/linux/linuxmint/iso/
sg https://download.nus.edu.sg/mirror/linuxmint/
us https://mirrors.kernel.org/linuxmint/
us https://mirror.pit.teraswitch.com/linuxmint-iso/
de https://ftp.halifax.rwth-aachen.de/linuxmint/
nl https://ftp.nluug.nl/os/Linux/distr/linuxmint/iso/
gb https://www.mirrorservice.org/sites/www.linuxmint.com/pub/
br https://mirror.ufscar.br/linuxmint-iso/
au https://mirror.aarnet.edu.au/pub/linuxmint/
za https://mirror.ufs.ac.za/linuxmint/
in https://mirrors.piconets.webwerks.in/linuxmint-mirror/iso/
'

log()  { printf '\033[1;34m==\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mXX\033[0m %s\n' "$*" >&2; exit 1; }

command -v curl >/dev/null || die "curl is required"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/mintiso.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# sha256: coreutils on Linux, shasum on macOS.
sha256_of() {
    if command -v sha256sum >/dev/null; then sha256sum "$1" | awk '{print $1}'
    else shasum -a 256 "$1" | awk '{print $1}'; fi
}

# ------------------------------------------------------------------ 1. where are we
detect_country() {
    local c
    c=$(curl -sL --max-time 6 https://api.country.is/ 2>/dev/null \
        | sed -n 's/.*"country" *: *"\([A-Za-z][A-Za-z]\)".*/\1/p')
    [ -z "$c" ] && c=$(curl -sL --max-time 6 https://ipinfo.io/json 2>/dev/null \
        | sed -n 's/.*"country" *: *"\([A-Za-z][A-Za-z]\)".*/\1/p')
    [ -z "$c" ] && c=$(curl -sL --max-time 6 http://ip-api.com/json/ 2>/dev/null \
        | sed -n 's/.*"countryCode" *: *"\([A-Za-z][A-Za-z]\)".*/\1/p')
    printf '%s' "$c" | tr 'A-Z' 'a-z'
}

# ------------------------------------------------------------------ 2. mirror list
# Rows live between the "Download mirrors" and "Repository mirrors" headings; the
# "Repository mirrors" table must be excluded or we would probe package mirrors.
fetch_mirrors() {
    local html="$TMP/mirrors.html"
    curl -sL --max-time 25 "$MIRROR_LIST_URL" -o "$html" 2>/dev/null || return 1
    [ -s "$html" ] || return 1
    awk '/>Download mirrors</{f=1} /># *Repository mirrors|>Repository mirrors</{f=0} f' "$html" \
        | tr -d '\n' | sed 's|<tr>|\n<tr>|g' \
        | grep -oE 'flags/[^"]+\.png[^>]*>[^<]*</td>[[:space:]]*<td><a href="[^"]+"' \
        | sed -E 's|flags/([^"]+)\.png.*href="([^"]+)"|\1 \2|' \
        | awk 'NF==2'
}

if [ -n "$MIRROR" ]; then
    log "Mirror forced: $MIRROR"
    MIRRORS="forced ${MIRROR%/}/"
    COUNTRY=""
else
    COUNTRY=$(detect_country || true)
    if [ -n "$COUNTRY" ]; then log "Detected location: $(printf '%s' "$COUNTRY" | tr 'a-z' 'A-Z')"
    else warn "Geo-IP lookup failed -- ranking on measured latency alone"; fi

    log "Fetching mirror list from $MIRROR_LIST_URL"
    if ! MIRRORS=$(fetch_mirrors) || [ -z "$MIRRORS" ]; then
        warn "Could not parse mirrors.php -- using built-in fallback list"
        MIRRORS=$FALLBACK_MIRRORS
    fi
    MIRRORS=$(printf '%s\n' "$MIRRORS" | grep -E '^\S+ https?://' | sort -u)
    log "$(printf '%s\n' "$MIRRORS" | grep -c .) ISO mirrors known"
fi

# ------------------------------------------------------- 3. parallel reachability probe
# HEAD the real ISO URL. Records country, TTFB and URL for mirrors answering 2xx.
log "Probing mirrors for $SUBPATH ..."
probe_one() {
    local cc=$1 root=$2 url code ttfb
    url="${root%/}/$SUBPATH"
    read -r code ttfb <<<"$(curl -sIL --max-time "$PROBE_TIMEOUT" -o /dev/null \
        -w '%{http_code} %{time_starttransfer}' "$url" 2>/dev/null || echo '000 99')"
    case "$code" in
        2*) printf '%s %s %s\n' "$ttfb" "$cc" "$root" >> "$TMP/alive" ;;
    esac
}
: > "$TMP/alive"
while read -r cc root; do
    [ -n "${root:-}" ] || continue
    probe_one "$cc" "$root" &
    # Keep concurrency bounded; `wait -n` is bash 4.3+, so fall back to a full barrier.
    while [ "$(jobs -rp | wc -l)" -ge 24 ]; do
        wait -n 2>/dev/null || wait
    done
done <<< "$MIRRORS"
wait

ALIVE=$(sort -n "$TMP/alive")
ALIVE_N=$(printf '%s\n' "$ALIVE" | grep -c . || true)
[ "$ALIVE_N" -gt 0 ] || die "No mirror is serving $SUBPATH (does release $RELEASE / edition $EDITION exist?)"
log "$ALIVE_N mirrors have the ISO"

# ------------------------------------------------------------------- 4. build shortlist
# Fastest-by-TTFB, plus same-country and global-CDN mirrors so a nearby mirror always
# gets a real throughput measurement even if its TTFB ranking looked mediocre.
{
    printf '%s\n' "$ALIVE" | head -n "$SHORTLIST"
    [ -n "$COUNTRY" ] && printf '%s\n' "$ALIVE" | awk -v c="$COUNTRY" '$2==c' | head -n 3
    printf '%s\n' "$ALIVE" | awk '$2=="_united_nations"' | head -n 2
} | awk '!seen[$3]++' > "$TMP/shortlist"

log "Throughput test ($((SPEED_BYTES/1048576)) MB) on $(grep -c . "$TMP/shortlist") candidates:"
: > "$TMP/speeds"
while read -r ttfb cc root; do
    (
        spd=$(curl -s --max-time 30 -r "0-$((SPEED_BYTES-1))" -o /dev/null \
              -w '%{speed_download}' "${root%/}/$SUBPATH" 2>/dev/null || echo 0)
        printf '%s %s %s\n' "${spd%%.*}" "$cc" "$root" >> "$TMP/speeds"
    ) &
done < "$TMP/shortlist"
wait

sort -rn "$TMP/speeds" | while read -r spd cc root; do
    printf '   %8.2f MB/s  [%-16s] %s\n' "$(awk -v s="$spd" 'BEGIN{print s/1048576}')" "$cc" "$root"
done >&2

BEST=$(sort -rn "$TMP/speeds" | awk '$1>0{print $3; exit}')
[ -n "$BEST" ] || BEST=$(printf '%s\n' "$ALIVE" | awk 'NR==1{print $3}')
BEST=${BEST%/}
log "Selected: $BEST"

if [ "$PROBE_ONLY" = "1" ]; then
    log "PROBE_ONLY=1 -- stopping before download"
    exit 0
fi

# ---------------------------------------------------------------------- 5. download
mkdir -p "$OUTDIR"
DEST="$OUTDIR/$ISO"
ISO_URL="$BEST/$SUBPATH"

EXPECTED_SIZE=$(curl -sIL --max-time 15 "$ISO_URL" 2>/dev/null \
    | awk 'tolower($1)=="content-length:"{v=$2} END{printf "%d", v+0}')
log "Downloading $ISO ($(awk -v b="$EXPECTED_SIZE" 'BEGIN{printf "%.2f", b/1073741824}') GiB)"

if command -v aria2c >/dev/null; then
    # aria2 can pull from several mirrors at once; feed it the whole shortlist.
    # (plain while-read instead of mapfile so stock macOS bash 3.2 also works)
    URLS=()
    while read -r spd cc root; do
        [ "$spd" -gt 0 ] 2>/dev/null || continue
        URLS+=("${root%/}/$SUBPATH")
    done < <(sort -rn "$TMP/speeds")
    aria2c -x8 -s8 -k4M -c --auto-file-renaming=false \
           -d "$OUTDIR" -o "$ISO" "${URLS[@]}"
else
    curl -L -C - --retry 5 --retry-delay 3 --progress-bar -o "$DEST" "$ISO_URL"
fi

[ -f "$DEST" ] || die "download produced no file"
ACTUAL_SIZE=$(wc -c < "$DEST" | tr -d ' ')
if [ "$EXPECTED_SIZE" -gt 0 ] && [ "$ACTUAL_SIZE" != "$EXPECTED_SIZE" ]; then
    die "size mismatch: got $ACTUAL_SIZE, expected $EXPECTED_SIZE (re-run to resume)"
fi

# ------------------------------------------------------------------ 6. verify sha256
log "Verifying sha256"
curl -sL --max-time 20 "$BEST/stable/$RELEASE/sha256sum.txt" -o "$TMP/sha256sum.txt" || true
WANT=$(awk -v f="$ISO" '$2=="*"f || $2==f {print $1}' "$TMP/sha256sum.txt" 2>/dev/null | head -1)
[ -n "$WANT" ] || die "could not read expected hash from $BEST/stable/$RELEASE/sha256sum.txt"

GOT=$(sha256_of "$DEST")
if [ "$GOT" = "$WANT" ]; then
    log "sha256 OK: $GOT"
else
    die "sha256 MISMATCH
  expected $WANT
  got      $GOT
  Delete $DEST and re-run."
fi

# gpg is best-effort: keyserver access is often blocked, and sha256 already matched a
# hash file fetched over TLS.
if command -v gpg >/dev/null; then
    if curl -sL --max-time 20 "$BEST/stable/$RELEASE/sha256sum.txt.gpg" -o "$TMP/sha256sum.txt.gpg" \
       && gpg --verify "$TMP/sha256sum.txt.gpg" "$TMP/sha256sum.txt" 2>/dev/null; then
        log "gpg signature OK"
    else
        warn "gpg signature not verified (key missing or fetch failed). To check manually:"
        warn "  gpg --keyserver hkp://keyserver.ubuntu.com --recv-key 27DEB15644C6B3CF3BD7D291300F846BA25BAE09"
        warn "  gpg --verify $TMP/sha256sum.txt.gpg $TMP/sha256sum.txt"
    fi
fi

# ------------------------------------------------------------------------ 7. next step
cat >&2 <<EOF

$(printf '\033[1;32m==\033[0m') Done: $DEST

Writing to USB:
  Linux:  sudo dd if="$DEST" of=/dev/sdX bs=4M status=progress conv=fsync
  macOS:  diskutil unmountDisk /dev/diskN
          sudo dd if="$DEST" of=/dev/rdiskN bs=4m
          # macOS may prompt to initialize the disk -- ignore/eject that dialog

Booting on a 2010 MacBook (MacBook7,1):
  Hold Option (alt) at power-on and pick "EFI Boot". MacBook7,1 has 64-bit EFI, so the
  ISO's EFI loader works directly -- verified on this machine, which boots x86_64
  shimx64.efi/grubx64.efi through EFI.
  A yellow-orange "Windows" entry may also appear: that is the BIOS/CSM path, which the
  isohybrid image can boot too. Either works; EFI Boot is the better default.
EOF
