#!/bin/bash
# run.sh - build the packages in Docker. Works on the Unraid box itself or on any machine with Docker.
#
#   ./build/run.sh                      on Unraid: builds for the running kernel (reads /usr/src from the host)
#   UNRAID_VERSION=7.3.3 ./build/run.sh elsewhere: downloads that Unraid release to get its kernel config
#   KERNEL_CONFIG=~/6.18.54-Unraid.config ./build/run.sh   with a config copied from /usr/src/linux-*-Unraid/
#
# Output lands in ./out, downloads and the prepared kernel tree are cached in ./cache (keep it: a rebuild for
# the next Unraid kernel then only needs that kernel's tarball). On Unraid run this from a real disk path
# (/mnt/cache/appdata/..., not /mnt/user/...): kernel trees are slow through the FUSE layer.
set -euo pipefail
cd "$(dirname "$0")/.."
IMAGE=${IMAGE:-gpu-unlock-build}
DOCKER=${DOCKER:-docker}

$DOCKER build -q ${BASE_IMAGE:+--build-arg BASE_IMAGE=$BASE_IMAGE} -t "$IMAGE" build/ >/dev/null

mkdir -p out cache
args=(--rm -v "$PWD/out:/out" -v "$PWD/cache:/cache")
# On an Unraid host, hand the container the kernel config of the running kernel.
if [ -z "${UNRAID_VERSION:-}${KERNEL_CONFIG:-}" ] && ls -d /usr/src/linux-*-Unraid >/dev/null 2>&1; then
  args+=(-v /usr/src:/unraid-src:ro)
fi
if [ -n "${KERNEL_CONFIG:-}" ]; then
  args+=(-v "$(readlink -f "$KERNEL_CONFIG"):/kernel.config:ro" -e KERNEL_CONFIG=/kernel.config)
fi
for v in UNRAID_VERSION KERNEL_RELEASE GPU_UNLOCK_REPO GPU_UNLOCK_REF BUILD_FIRMWARE RUN_TESTS JOBS KERNEL_MIRROR UNRAID_ZIP_URL; do
  [ -n "${!v:-}" ] && args+=(-e "$v=${!v}")
done
exec $DOCKER run "${args[@]}" "$IMAGE" "$@"
