#!/bin/bash
# build.sh - build Zagitta/gpu-unlock for one Unraid kernel and pack it as Slackware packages.
#
# Produces, under $OUT:
#   <kernel>/gpu-unlock-module-<ver>-<kernel>-1.txz   gpu_unlock.ko built for exactly that kernel (per Unraid release)
#   firmware/gpu-unlock-firmware-<nv>-noarch-1.txz   the five pinned 610.43.03 firmware files (kernel independent,
#                                                    generated once from the NVIDIA inputs the project pins)
# plus a .sha256 next to each. The Unraid plugin installs both at boot and loads the module before nvidia.
#
# Which Unraid kernel to build for (first one that applies):
#   KERNEL_CONFIG=/path/to/.config          a copy of /usr/src/linux-<ver>-Unraid/config from the box
#   /unraid-src (or UNRAID_SRC=...) exists  the box's /usr/src bind-mounted in (run.sh does this on Unraid);
#                                            KERNEL_RELEASE=6.18.54-Unraid picks the kernel, default: uname -r
#   UNRAID_VERSION=7.3.3                     downloads that release and reads the config out of it
#
# Other knobs: GPU_UNLOCK_REPO / GPU_UNLOCK_REF (pinned commit by default), BUILD_FIRMWARE=auto|yes|no,
#              RUN_TESTS=no|yes, JOBS, OUT, CACHE, KERNEL_MIRROR, KERNEL_TARBALL (a local linux-x.y.z.tar.xz)
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-/out}
CACHE=${CACHE:-/cache}
JOBS=${JOBS:-$(nproc)}
GPU_UNLOCK_REPO=${GPU_UNLOCK_REPO:-https://github.com/Zagitta/gpu-unlock}
GPU_UNLOCK_REF=${GPU_UNLOCK_REF:-990a14e9b7dc8eaad8e6925133aa0e8382efe6cf}   # main as of 2026-10-26 (v1.0.0)
BUILD_FIRMWARE=${BUILD_FIRMWARE:-auto}
RUN_TESTS=${RUN_TESTS:-no}
KERNEL_MIRROR=${KERNEL_MIRROR:-https://cdn.kernel.org/pub/linux/kernel}
UNRAID_SRC=${UNRAID_SRC:-/unraid-src}
PKGBUILD=1

log() { echo; echo "==> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
# modinfo -F <field> <ko>, with a fallback for hosts without kmod (.modinfo holds NUL-separated key=value strings)
modinfo_field() {
  if command -v modinfo >/dev/null 2>&1; then modinfo -F "$1" "$2"; else strings -n 4 "$2" | sed -n "s/^$1=//p"; fi
}

mkdir -p "$OUT" "$CACHE"/{configs,kernel,inputs}

# ---------------------------------------------------------------------------------------------
log "Kernel config"
if [ -n "${KERNEL_CONFIG:-}" ]; then
  [ -f "$KERNEL_CONFIG" ] || die "KERNEL_CONFIG=$KERNEL_CONFIG not found"
  d=$(basename "$(cd "$(dirname "$KERNEL_CONFIG")" && pwd)")
  case "$d" in
    linux-*-Unraid) KR=${d#linux-} ;;   # copied with its /usr/src/linux-<ver>-Unraid/ directory
    *) KR=$(sed -n 's/^# Linux\/x86 \([0-9.]*\).*Kernel Configuration/\1/p' "$KERNEL_CONFIG")$(sed -n 's/^CONFIG_LOCALVERSION="\(.*\)"/\1/p' "$KERNEL_CONFIG") ;;
  esac
  [ -n "${KERNEL_RELEASE:-}" ] && KR=$KERNEL_RELEASE
  [ -n "$KR" ] || die "cannot name the kernel from $KERNEL_CONFIG; set KERNEL_RELEASE=6.18.54-Unraid"
  cp "$KERNEL_CONFIG" "$CACHE/configs/$KR.config"
elif [ -d "$UNRAID_SRC" ] && ls -d "$UNRAID_SRC"/linux-*-Unraid >/dev/null 2>&1; then
  # inside a container on the Unraid box, uname -r is the host kernel
  KR=$(KERNEL_RELEASE="${KERNEL_RELEASE:-$(uname -r)}" "$HERE/unraid-kernel-config.sh" "$UNRAID_SRC" "$CACHE/configs")
elif [ -n "${UNRAID_VERSION:-}" ]; then
  KR=$("$HERE/unraid-kernel-config.sh" "$UNRAID_VERSION" "$CACHE/configs")
else
  die "tell me which kernel: UNRAID_VERSION=7.3.3, KERNEL_CONFIG=/path/config, or mount the box's /usr/src at /unraid-src"
fi
CFG="$CACHE/configs/$KR.config"
[ -f "$CFG" ] || die "config $CFG missing"
KVER=$(sed -n 's/^# Linux\/x86 \([0-9.]*\).*Kernel Configuration/\1/p' "$CFG")
[ -n "$KVER" ] || die "cannot read the upstream kernel version from $CFG"
echo "kernel release: $KR   upstream: $KVER   config: $CFG"
grep -q '^CONFIG_MODVERSIONS=y' "$CFG" && die "this kernel uses CONFIG_MODVERSIONS; a full kernel build would be needed (Unraid normally does not)"
grep -q '^CONFIG_MODULE_SIG_FORCE=y' "$CFG" && die "this kernel enforces module signatures"
echo "compiler the kernel was built with: $(sed -n 's/^CONFIG_CC_VERSION_TEXT="\(.*\)"/\1/p' "$CFG")   (here: $(gcc --version | head -1))"

# ---------------------------------------------------------------------------------------------
log "Kernel source $KVER"
KDIR="$CACHE/kernel/$KR/linux-$KVER"
TARBALL=${KERNEL_TARBALL:-$CACHE/kernel/linux-$KVER.tar.xz}
if [ ! -f "$TARBALL" ]; then
  major=${KVER%%.*}
  url="$KERNEL_MIRROR/v$major.x/linux-$KVER.tar.xz"
  echo "downloading $url"
  curl -fL --retry 3 -o "$TARBALL.part" "$url" && mv "$TARBALL.part" "$TARBALL"
  # best-effort checksum against kernel.org's signed list
  if sums=$(curl -fsSL --retry 2 "$KERNEL_MIRROR/v$major.x/sha256sums.asc" 2>/dev/null); then
    want=$(echo "$sums" | grep " linux-$KVER.tar.xz$" | cut -d' ' -f1 || true)
    have=$(sha256sum "$TARBALL" | cut -d' ' -f1)
    if [ -n "$want" ] && [ "$want" != "$have" ]; then rm -f "$TARBALL"; die "linux-$KVER.tar.xz checksum mismatch"; fi
    [ -n "$want" ] && echo "sha256 ok"
  fi
fi
if [ ! -f "$KDIR/.prepared" ]; then
  rm -rf "$KDIR"; mkdir -p "$(dirname "$KDIR")"
  tar -xf "$TARBALL" -C "$(dirname "$KDIR")"
  [ -d "$KDIR" ] || die "tarball did not unpack to $KDIR"
  cp "$CFG" "$KDIR/.config"
  make -C "$KDIR" olddefconfig >/dev/null
  make -C "$KDIR" -j"$JOBS" modules_prepare >/dev/null
  got=$(make -C "$KDIR" -s kernelrelease)
  [ "$got" = "$KR" ] || die "prepared tree reports kernelrelease '$got', expected '$KR'"
  touch "$KDIR/.prepared"
fi
echo "prepared: $KDIR ($(make -C "$KDIR" -s kernelrelease))"

# ---------------------------------------------------------------------------------------------
log "gpu-unlock source @ $GPU_UNLOCK_REF"
SRC="$CACHE/gpu-unlock"
if [ ! -d "$SRC/.git" ]; then
  git clone -q "$GPU_UNLOCK_REPO" "$SRC"
fi
git -C "$SRC" fetch -q origin "$GPU_UNLOCK_REF" 2>/dev/null || git -C "$SRC" fetch -q origin
git -C "$SRC" -c advice.detachedHead=false checkout -q --detach "$GPU_UNLOCK_REF" 2>/dev/null \
  || git -C "$SRC" -c advice.detachedHead=false checkout -q --detach "origin/$GPU_UNLOCK_REF"
COMMIT=$(git -C "$SRC" rev-parse HEAD)
VERSION=$(cat "$SRC/VERSION")
NV=$(sed -n 's/^NV *:= *//p' "$SRC/Makefile")
[ -n "$NV" ] || die "cannot read the pinned NVIDIA version from the Makefile"
echo "gpu-unlock $VERSION (commit ${COMMIT:0:12}), pinned NVIDIA inputs $NV"

# ---------------------------------------------------------------------------------------------
log "Building gpu_unlock.ko for $KR"
WORK="$CACHE/work/$KR"
rm -rf "$WORK"; mkdir -p "$WORK"
cp -r "$SRC/kernel/gpu_unlock" "$WORK/mod"
# No Module.symvers without a full kernel build: modpost cannot check exports, so it only warns;
# the symbols resolve at insmod time. The check below greps the kernel source for each one instead.
make -C "$WORK/mod" KDIR="$KDIR" KBUILD_MODPOST_WARN=1 -j"$JOBS" 2>&1 | grep -vE "undefined!|Module.symvers is missing|Modules may not have|unresolved symbol|KBUILD_MODPOST_WARN|at your own risk|suppressed .* unresolved" || true
KO="$WORK/mod/gpu_unlock.ko"
[ -f "$KO" ] || die "build failed: no gpu_unlock.ko"
VERMAGIC=$(modinfo_field vermagic "$KO")
[ "${VERMAGIC%% *}" = "$KR" ] || die "vermagic '$VERMAGIC' does not match $KR"
echo "vermagic: $VERMAGIC"

missing=0
for s in $(nm -u "$KO" | awk '{print $2}' | sed 's/^__pfx_//' | sort -u); do
  case "$s" in
    __fentry__|__stack_chk_fail|_printk|__x86_return_thunk|__x86_indirect_thunk*|__SCT__*|__ubsan*|__kcfi*|__cfi_*|__fortify_panic|__this_module|__start_*|__stop_*|__sanitizer*|__tsan*|__asan*|__kasan*|__gcov*|__ref*|__kcsan*|__init*|init_module|cleanup_module) continue ;;
  esac
  if ! grep -rqE "EXPORT_SYMBOL(_GPL|_NS|_NS_GPL)?\($s(\)|,)|define_dev_printk_level\($s," \
       "$KDIR/kernel" "$KDIR/drivers/pci" "$KDIR/drivers/base" "$KDIR/lib" "$KDIR/arch/x86" "$KDIR/mm" "$KDIR/drivers/firmware" "$KDIR/drivers/video" 2>/dev/null; then
    echo "WARNING: symbol $s not found as an export in the kernel source"; missing=$((missing + 1))
  fi
done
[ "$missing" -eq 0 ] && echo "all unresolved symbols are kernel exports" || echo "WARNING: $missing symbol(s) could not be verified; the module may fail to load"

# ---------------------------------------------------------------------------------------------
pack() { # pack <root> <file.txz>  - Slackware package: a tar.xz of the tree, install/ first
  local root=$1 out=$2
  ( cd "$root" && tar --sort=name --owner=0 --group=0 --numeric-owner --mtime="@${SOURCE_DATE_EPOCH:-$(date +%s)}" \
      -cJf "$out" install $(ls -d -- * | grep -vx install) )
  ( cd "$(dirname "$out")" && sha256sum "$(basename "$out")" > "$out.sha256" )
  ls -l "$out"
}
slack_desc() { # slack_desc <name> <line...>  (Slackware wants exactly 11 "name:" lines after the ruler)
  local n=$1; shift
  printf '%*s|-----handy-ruler------------------------------------------------------|\n' ${#n} ''
  local i=0
  for l in "$@"; do printf '%s: %s\n' "$n" "$l"; i=$((i + 1)); done
  while [ $i -lt 11 ]; do printf '%s:\n' "$n"; i=$((i + 1)); done
}

log "Packing gpu-unlock-module-$VERSION-$KR-1.txz"
P="$WORK/pkg-module"
rm -rf "$P"; mkdir -p "$P/install" "$P/lib/modules/$KR/extra" "$P/usr/share/doc/gpu-unlock-$VERSION" "$P/usr/share/licenses/gpu-unlock"
install -m644 "$KO" "$P/lib/modules/$KR/extra/gpu_unlock.ko"
install -m644 "$SRC/README.md" "$P/usr/share/doc/gpu-unlock-$VERSION/README.md"
install -m644 "$SRC/licenses/GPL-2.0.txt" "$P/usr/share/licenses/gpu-unlock/GPL-2.0.txt"
cat > "$P/usr/share/doc/gpu-unlock-$VERSION/BUILD-INFO" <<EOF
gpu-unlock $VERSION
source    $GPU_UNLOCK_REPO @ $COMMIT
kernel    $KR (linux-$KVER + Unraid config)
vermagic  $VERMAGIC
built     $(date -u +%Y-%m-%dT%H:%M:%SZ) with $(gcc --version | head -1)
firmware  gpu-unlock/$NV/ (separate package gpu-unlock-firmware-$NV)
EOF
slack_desc gpu-unlock-module "gpu-unlock-module (Ampere BF16 unlock kernel module)" "" \
  "gpu_unlock.ko by Zagitta, built for Unraid kernel $KR." \
  "Unlocks the FP16/BF16 issue rate of GA102/GA103/GA104/GA106 cards" \
  "before the nvidia driver binds them. Needs gpu-unlock-firmware-$NV." \
  "" "Source: $GPU_UNLOCK_REPO" "Commit: ${COMMIT:0:12}" > "$P/install/slack-desc"
mkdir -p "$OUT/$KR"
pack "$P" "$OUT/$KR/gpu-unlock-module-$VERSION-$KR-1.txz"
cp "$P/usr/share/doc/gpu-unlock-$VERSION/BUILD-INFO" "$OUT/$KR/BUILD-INFO"

# ---------------------------------------------------------------------------------------------
FWPKG="$OUT/firmware/gpu-unlock-firmware-$NV-noarch-1.txz"
if [ "$BUILD_FIRMWARE" = yes ] || { [ "$BUILD_FIRMWARE" = auto ] && [ ! -f "$FWPKG" ]; }; then
  log "Generating the pinned $NV firmware (downloads the NVIDIA inputs the project pins, SHA-256 checked)"
  python3 -I "$SRC/firmware/fetch_artifacts.py" "$CACHE/inputs"
  ASSETS="$WORK/assets"
  rm -rf "$ASSETS" "$ASSETS.src"
  make -C "$SRC" firmware INPUTS="$CACHE/inputs" ASSETS="$ASSETS" PYTHON="python3 -I"
  if [ "$RUN_TESTS" = yes ]; then
    log "Running the project's tests against the generated firmware"
    make -C "$SRC" test ASSETS="$ASSETS" PYTHON="python3 -I"
  fi
  log "Packing gpu-unlock-firmware-$NV-noarch-1.txz"
  P="$WORK/pkg-firmware"
  rm -rf "$P"; mkdir -p "$P/install" "$P/lib/firmware/gpu-unlock/$NV" "$P/usr/share/licenses/gpu-unlock-firmware"
  for f in $(modinfo_field firmware "$KO"); do   # the exact files the module asks for
    install -m644 "$ASSETS/$(basename "$f")" "$P/lib/firmware/$f"
  done
  install -m644 "$ASSETS/NVIDIA-LICENSE" "$P/usr/share/licenses/gpu-unlock-firmware/NVIDIA-LICENSE"
  install -m644 "$SRC/firmware/NOTICE.md" "$P/usr/share/licenses/gpu-unlock-firmware/NOTICE.md"
  slack_desc gpu-unlock-firmware "gpu-unlock-firmware (pinned NVIDIA $NV firmware for gpu_unlock)" "" \
    "Generated locally by gpu-unlock's firmware scripts from the pinned" \
    "NVIDIA $NV inputs. Installed to /lib/firmware/gpu-unlock/$NV/." \
    "NVIDIA firmware stays under NVIDIA's terms; see NOTICE.md." \
    "" "Source: $GPU_UNLOCK_REPO" > "$P/install/slack-desc"
  mkdir -p "$OUT/firmware"
  pack "$P" "$FWPKG"
  rm -rf "$ASSETS.src"
elif [ -f "$FWPKG" ]; then
  log "Firmware package: keeping existing $FWPKG (kernel independent)"
else
  log "Firmware package: skipped (BUILD_FIRMWARE=$BUILD_FIRMWARE); the plugin needs one, run with BUILD_FIRMWARE=yes"
fi

# ---------------------------------------------------------------------------------------------
log "Done"
cat <<EOF
  module  : $OUT/$KR/gpu-unlock-module-$VERSION-$KR-1.txz
  firmware: $FWPKG$([ -f "$FWPKG" ] || echo '   (MISSING)')
Copy them to the Unraid flash (install.sh does this):
  /boot/config/plugins/gpu-unlock/packages/$KR/        <- module .txz + .sha256
  /boot/config/plugins/gpu-unlock/packages/firmware/   <- firmware .txz + .sha256
EOF
