# gpu-unlock for Unraid

Packages [Zagitta/gpu-unlock](https://github.com/Zagitta/gpu-unlock) (the Ampere FP16/BF16 issue-rate unlock,
a Linux kernel module) so it runs on an Unraid box: a build container that produces Slackware `.txz` packages
for your exact Unraid kernel, and a small Unraid plugin that installs them at boot and loads the module
**before** the nvidia-driver plugin loads `nvidia`.

Supported cards (per the project): GeForce GA102/GA103/GA104/GA106, e.g. RTX 3060 12 GB, 3070, 3080, 3090, 3090 Ti.
Read the project README for the tested-cards table, the gains to expect (dense GEMM / LLM prefill / diffusion up,
LLM decode unchanged) and the hardware caveats. This is unofficial; use at your own risk.

## How it fits Unraid

* Unraid runs from RAM; nothing survives a reboot except `/boot` (the USB stick). Since 6.9.1 `/lib/modules` and
  `/lib/firmware` have an overlayfs, so a package can drop `gpu_unlock.ko` and its firmware in at boot.
* `gpu_unlock` only acts on cards that no driver has claimed, and refuses a card any driver has initialised since
  power-on. So it must load before `modprobe nvidia`. On Unraid that `modprobe` is done by the **nvidia-driver**
  plugin when `rc.local` installs `/boot/config/plugins/*.plg` at boot, in file-name order:
  `gpu-unlock.plg` sorts before `nvidia-driver.plg`, so it runs first every boot (and before the `go` script).
* The module is built for one exact kernel (`uname -r`, e.g. `6.18.54-Unraid` = Unraid 7.3.3). Each Unraid
  update with a new kernel needs a rebuild of the small module package; the firmware package is kernel independent.
* Unraid builds its kernel without `CONFIG_MODVERSIONS` and without module signing, so a module built from the
  matching upstream kernel source plus Unraid's own `.config` loads fine. `build.sh` takes the config straight from
  the box (`/usr/src/linux-<ver>-Unraid/config`) or out of the Unraid release zip, checks that the result's
  vermagic matches, and checks every unresolved symbol against the kernel's exports.

What gets produced:

```
out/<kernel>/gpu-unlock-module-1.0.0-<kernel>-1.txz   gpu_unlock.ko  -> /lib/modules/<kernel>/extra/   (~35 KB)
out/firmware/gpu-unlock-firmware-610.43.03-noarch-1.txz  5 files      -> /lib/firmware/gpu-unlock/610.43.03/ (~85 MB)
```

The firmware is generated locally by the project's own scripts from the NVIDIA inputs it pins (SHA-256 checked),
exactly like its Arch/Debian/RPM packages do. NVIDIA firmware stays under NVIDIA's terms (`NOTICE.md` is in the
package); keep the firmware package on your own flash drive rather than publishing it.

## Quick start (building on the Unraid box itself)

Needs: Unraid 7.x with Docker enabled, the nvidia-driver plugin (or vfio passthrough, see below), internet access
for the build, ~3 GB of disk for the kernel tree. Run everything as root in a terminal (SSH or the web terminal).

```bash
# 1. clone to a real disk path (not /mnt/user/..., the FUSE layer is slow for kernel trees)
mkdir -p /mnt/cache/appdata && cd /mnt/cache/appdata
git clone https://github.com/wickeddoc/gpu-unlock-unraid && cd gpu-unlock-unraid

# 2. build for the running kernel: ~5-10 min; downloads linux-x.y.z.tar.xz (~150 MB) and, once,
#    the NVIDIA inputs for the firmware (a few hundred MB). Output in ./out, cache in ./cache.
./build/run.sh

# 3. copy the packages to the flash and install the plugin
./install.sh

# 4. reboot (the first time, do a full power-off / power-on, see "Cold boot" below)
```

The plugin itself can also be installed the usual Unraid way, from **Plugins > Install Plugin** with

```
https://raw.githubusercontent.com/wickeddoc/gpu-unlock-unraid/master/plugin/gpu-unlock.plg
```

It installs fine before any package exists (it just reports "No module for kernel ..." until you build and copy
them), and the Plugins page then offers updates whenever a new plugin version is pushed. `install.sh` still does
the package copying; with the plugin already installed it simply re-runs its start step.

After the reboot check **Settings > User Utilities > GPU Unlock** (or `dmesg | grep gpu_unlock`): every target card
should show `gpu_unlock: unlocked`, and you get an Unraid notification "Unlocked N card(s)". Then confirm with a
dense BF16 GEMM benchmark, as in the project's issue reports; `nvidia-smi` cannot show the issue rate.

## Building somewhere else

Any Linux machine with Docker works; the only Unraid-specific input is the kernel config:

```bash
UNRAID_VERSION=7.3.3 ./build/run.sh                   # downloads that release zip and reads the config from it
KERNEL_CONFIG=~/6.18.54-Unraid.config ./build/run.sh  # or a copy of /usr/src/linux-*-Unraid/config from the box
```

then copy `out/` to the server (or the repo directory to `/mnt/cache/appdata/gpu-unlock-unraid`) and run
`./install.sh` there, or do by hand what it does:

```
/boot/config/plugins/gpu-unlock/packages/<uname -r>/   <- gpu-unlock-module-*.txz + .sha256 (+ BUILD-INFO)
/boot/config/plugins/gpu-unlock/packages/firmware/     <- gpu-unlock-firmware-*.txz + .sha256
/boot/config/plugins/gpu-unlock/gpu-unlock.plg         <- plugin/gpu-unlock.plg
plugin install /boot/config/plugins/gpu-unlock/gpu-unlock.plg forced
```

Without Docker: `build/build.sh` runs on any Debian/Ubuntu with the packages listed in `build/Dockerfile`
(`OUT=./out CACHE=./cache UNRAID_VERSION=7.3.3 build/build.sh`).

Knobs (environment variables, all optional): `BUILD_FIRMWARE=auto|yes|no`, `RUN_TESTS=yes` (runs the project's
test-suite against the generated firmware), `GPU_UNLOCK_REF=<commit|branch>` (default: the commit this was written
against), `KERNEL_RELEASE=6.18.58-Unraid` (pick a kernel from a mounted `/usr/src` with several), `JOBS`,
`BASE_IMAGE=gcc:16` (`run.sh`: build with the same gcc major as the kernel; not needed, see the Dockerfile note).

## After an Unraid update

The plugin finds no package for the new kernel, leaves the cards at the stock rate and sends a notification.
Rebuild and install again; the firmware package is reused:

```bash
cd /mnt/cache/appdata/gpu-unlock-unraid && ./build/run.sh && ./install.sh   # then reboot
```

Tip: if you keep the Unraid downgrade option open, packages for older kernels can stay in `packages/`.

## Settings (Settings > User Utilities > GPU Unlock)

| Setting | Default | Notes |
|---|---|---|
| Enable at boot | yes | `no` installs nothing and loads nothing |
| Cards to unlock | `all` | or `0000:21:00.0,0000:22:00.0` (addresses as the status list shows them; passed as `targets=`) |
| Release vfio-pci cards | no | experimental: cards bound to vfio-pci for VM passthrough are unbound, unlocked and rebound; the unlock survives the FLR a VM start does. Only with no VM auto-starting the card |
| Re-unlock after resume | yes | module default; servers rarely suspend |

Settings only change what the **next boot** does: the unlock can only run before `nvidia` binds the cards.
The status block on that page shows the packages found, whether the module is loaded, every supported card with
its current driver and its last `gpu_unlock` message, and the recent kernel log lines.

## Cold boot, and other things to know

* **"card already initialised since power on (WPR2 enabled); power off first"** in the log: the GPU's firmware
  state survived a warm reboot. Shut the server down fully, wait a few seconds, power on. (Same advice as the
  project README and the earlier CMP-unlock projects for Unraid.)
* **Display card / GUI mode:** supported by the module (its screen is blank from the unlock until nvidia-drm takes
  over). Untested with Unraid's GUI boot mode here.
* **Docker containers** using the GPU work unchanged: they use the stock `nvidia` driver, which binds the already
  unlocked card.
* **nouveau:** if the status page shows a card bound to `nouveau`, blacklist it
  (`echo 'blacklist nouveau' > /boot/config/modprobe.d/nouveau.conf`) and reboot.
* **Uninstall:** Plugins page or `plugin remove gpu-unlock.plg`. This unloads the module and removes the installed
  packages; the built `.txz` files stay in `/boot/config/plugins/gpu-unlock/packages/` (delete if unwanted).
  Unlocked cards stay unlocked until they lose power.
* **Plugin updates:** the `.plg` carries a `version` (date); the Plugins page shows an update when the file on
  `master` has a newer one. Bump it (e.g. `2026.10.26a`) in any commit that changes `plugin/gpu-unlock.plg`.
  Packages are never downloaded by the plugin; they always come from your own build in `packages/`.
* The kernel in Unraid 7.3.3 was built with gcc 16.2; the container uses Debian 13's gcc 14.2. That is fine for
  an out-of-tree module (no MODVERSIONS, no signature, no compiler check at insmod; only the vermagic has to match,
  and the build verifies it). `BASE_IMAGE=gcc:16 ./build/run.sh` if you want the same compiler anyway.
* Checked here: `gpu_unlock.ko` (commit `990a14e`) compiles cleanly against `6.18.54-Unraid` (Unraid 7.3.3) with
  vermagic `6.18.54-Unraid SMP preempt mod_unload`, and all of its 61 unresolved symbols are kernel exports.
  The hardware path (the unlock itself) was not run here; report results on the project's compatibility-report
  issue template.

## Layout

```
build/Dockerfile               Debian 13 + kernel build deps + squashfs-tools + zstd + python3
build/build.sh                 config -> kernel modules_prepare -> gpu_unlock.ko -> module .txz; firmware -> .txz
build/unraid-kernel-config.sh  gets /usr/src/linux-*-Unraid/config from the box, a release zip, or releases.unraid.net
build/run.sh                   docker build + docker run with the right mounts (works on Unraid or elsewhere)
plugin/gpu-unlock.plg          the Unraid plugin: control script, settings page, install/remove (all inline)
install.sh                     on the box: copies out/ to /boot and installs the plugin
```

Credits: the module and firmware generators are Zagitta's work (GPL-2.0-only for the module and packaging).
The "upstream source + Unraid config" build method and the kernel-config locations in the Unraid images follow
davilaa's [ds-sc5b-uas-arbiter](https://github.com/davilaa/ds-sc5b-uas-arbiter) plugin; the boot-order and overlay
facts come from Unraid's `rc.local` / `rc.S` in the [unraid/webgui](https://github.com/unraid/webgui) repo.
