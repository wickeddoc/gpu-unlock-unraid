#!/bin/bash
# unraid-kernel-config.sh  <unraid-version | release.zip | image-dir | unraid-/usr/src-dir>  <outdir>
#
# Writes OUTDIR/<kernel-release>.config (e.g. 6.18.54-Unraid.config) and prints the kernel release.
#
# Where the config comes from:
#   7.3.3                 download that release from releases.unraid.net and read the config out of it
#   /path/unRAIDServer.zip  a release zip you already have
#   /path/to/dir            a directory with bzmodules / bzfirmware / bzroot (a copy of the Unraid USB root)
#   /usr/src (of the box)   the running Unraid's /usr/src: contains linux-<ver>-Unraid/{config,.config}
#                           (bind-mounted into the build container as /unraid-src)
#
# Layout facts: on a running Unraid box the config is /usr/src/linux-<ver>-Unraid/config (7.3+) or
# .config (older). In the release zip it lives in bzmodules (7.3+, that image is /usr) or bzfirmware (older).
# Needs: curl, unzip, python3, unsquashfs (squashfs-tools), xz, cpio.
set -euo pipefail

usage() { sed -n '2,13p' "$0"; exit 1; }
[ $# -eq 2 ] || usage
SRC=$1
OUT=$2
mkdir -p "$OUT"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

CFG=""
KR=""

# A directory full of linux-*-Unraid/ (the box's /usr/src): pick KERNEL_RELEASE, else the only/newest one.
if [ -d "$SRC" ] && ls -d "$SRC"/linux-*-Unraid >/dev/null 2>&1; then
  if [ -n "${KERNEL_RELEASE:-}" ]; then
    d="$SRC/linux-$KERNEL_RELEASE"
  else
    d=$(ls -d "$SRC"/linux-*-Unraid | sort -V | tail -1)
  fi
  for f in "$d/config" "$d/.config"; do
    [ -f "$f" ] && CFG=$f && break
  done
  [ -n "$CFG" ] || { echo "no config in $d" >&2; exit 1; }
  KR=${d##*/linux-}
fi

# A release zip or a version number: get bzmodules/bzfirmware/bzroot into $IMG.
IMG=""
if [ -z "$CFG" ]; then
  if [ -d "$SRC" ]; then
    IMG=$SRC
  else
    if [ -f "$SRC" ]; then
      ZIP=$SRC
    else
      VER=$SRC
      URL=${UNRAID_ZIP_URL:-}
      if [ -z "$URL" ]; then
        URL=$(curl -fsSL --retry 3 https://releases.unraid.net/json | python3 -I -c '
import json, sys
want = sys.argv[1]
data = json.load(sys.stdin)
items = data if isinstance(data, list) else [x for v in data.values() if isinstance(v, list) for x in v]
for r in items:
    if isinstance(r, dict) and r.get("version") == want and r.get("url"):
        print(r["url"]); break
' "$VER")
      fi
      [ -n "$URL" ] || { echo "Unraid $VER not found at releases.unraid.net/json (set UNRAID_ZIP_URL=... to override)" >&2; exit 1; }
      echo "downloading $URL" >&2
      curl -fL --retry 3 -o "$TMP/unraid.zip" "$URL"
      ZIP=$TMP/unraid.zip
    fi
    mkdir -p "$TMP/img"
    unzip -q -o "$ZIP" bzmodules bzfirmware bzroot -d "$TMP/img" 2>/dev/null || true
    IMG=$TMP/img
  fi
  for f in bzmodules bzfirmware; do
    [ -f "$IMG/$f" ] || continue
    path=$(unsquashfs -l "$IMG/$f" 2>/dev/null | sed -n 's#^squashfs-root/##p' \
           | grep -E '(^|/)linux-[^/]+-Unraid/\.?config$' | head -1 || true)
    if [ -n "$path" ]; then
      unsquashfs -q -n -d "$TMP/x" "$IMG/$f" "$path" >/dev/null
      CFG="$TMP/x/$path"
      echo "found $path in $f" >&2
      break
    fi
  done
  if [ -z "$CFG" ] && [ -f "$IMG/bzroot" ]; then
    # bzroot = microcode cpio + xz-compressed cpio; look for the config in the second part
    OFF=$(python3 -I -c '
import sys
d = open(sys.argv[1], "rb").read()
t = d.find(b"TRAILER!!!")
i = d.find(b"\xfd7zXZ\x00", t if t >= 0 else 0)
print(i if i >= 0 else "")' "$IMG/bzroot")
    if [ -n "$OFF" ]; then
      mkdir -p "$TMP/r"
      ( cd "$TMP/r" && tail -c +$((OFF + 1)) "$IMG/bzroot" | xz -dc 2>/dev/null \
        | cpio -idm --quiet '*linux-*-Unraid/.config' '*linux-*-Unraid/config' 2>/dev/null ) || true
      CFG=$(find "$TMP/r" \( -path '*linux-*-Unraid/.config' -o -path '*linux-*-Unraid/config' \) | head -1 || true)
      [ -n "$CFG" ] && echo "found ${CFG#"$TMP"/r/} in bzroot" >&2
    fi
  fi
  [ -n "$CFG" ] && [ -f "$CFG" ] || { echo "no Unraid kernel config found in bzmodules/bzfirmware/bzroot" >&2; exit 1; }
  KR=$(echo "$CFG" | grep -oE 'linux-[0-9][^/]*-Unraid' | head -1 | sed 's/^linux-//' || true)
fi

# Fall back to the config header + CONFIG_LOCALVERSION for the release name.
if [ -z "$KR" ]; then
  KR=$(sed -n 's/^# Linux\/x86 \([0-9.]*\).*Kernel Configuration/\1/p' "$CFG")$(sed -n 's/^CONFIG_LOCALVERSION="\(.*\)"/\1/p' "$CFG")
fi
[ -n "$KR" ] || { echo "cannot determine the kernel release from $CFG" >&2; exit 1; }
cp "$CFG" "$OUT/$KR.config"
echo "$KR"
