#!/bin/bash
# install.sh - run this ON THE UNRAID SERVER after build/run.sh: copies the packages built for the running kernel
# and the plugin to the flash drive, then installs the plugin. If nvidia is already loaded (it will be, on a
# running system) the plugin just installs the packages and asks for a reboot: the unlock has to run before
# the nvidia-driver plugin loads nvidia, which happens automatically at the next boot.
set -euo pipefail
cd "$(dirname "$0")"
die() { echo "ERROR: $*" >&2; exit 1; }
[ -d /boot/config/plugins ] && [ -x /usr/local/sbin/plugin ] || die "run this on the Unraid server (as root)"

KR=$(uname -r)
FLASH=/boot/config/plugins/gpu-unlock
mod=$(ls -1 "out/$KR"/gpu-unlock-module-*-"$KR"-1.txz 2>/dev/null | sort -V | tail -1 || true)
fw=$(ls -1 out/firmware/gpu-unlock-firmware-*.txz 2>/dev/null | sort -V | tail -1 || true)
[ -n "$mod" ] || die "no out/$KR/gpu-unlock-module-*-$KR-1.txz - build it first: ./build/run.sh   (this box runs kernel $KR)"
[ -n "$fw" ] || die "no out/firmware/gpu-unlock-firmware-*.txz - build it first: ./build/run.sh"
[ -f "$mod.sha256" ] && [ -f "$fw.sha256" ] || die "missing .sha256 files next to the packages"

mkdir -p "$FLASH/packages/$KR" "$FLASH/packages/firmware"
echo "copying packages to $FLASH/packages"
cp -v "$mod" "$mod.sha256" "$FLASH/packages/$KR/"
[ -f "out/$KR/BUILD-INFO" ] && cp "out/$KR/BUILD-INFO" "$FLASH/packages/$KR/"
cp -v "$fw" "$fw.sha256" "$FLASH/packages/firmware/"
old=$(ls -d "$FLASH"/packages/*-Unraid 2>/dev/null | grep -v "/$KR$" || true)
[ -n "$old" ] && echo "note: packages for other kernels are still on the flash (safe to delete): $old"

# the plugin manager copies this to /boot/config/plugins/gpu-unlock.plg, which is what boot installs
cp plugin/gpu-unlock.plg "$FLASH/gpu-unlock.plg"
echo "installing the plugin"
/usr/local/sbin/plugin install "$FLASH/gpu-unlock.plg" forced
echo
echo "Done. Reboot to unlock (the plugin loads gpu_unlock before the nvidia-driver plugin at every boot)."
echo "Status page: Settings > User Utilities > GPU Unlock"
