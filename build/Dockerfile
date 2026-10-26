# Build container for gpu-unlock on Unraid.
# Debian 13 ships gcc 14.2. Unraid 7.3.x kernels were built with gcc 16.2, but that does not matter for an
# out-of-tree module: Unraid builds without CONFIG_MODVERSIONS and without module signing, and the kernel
# does not check the compiler version at insmod time; only the vermagic (kernel release + SMP/preempt flags)
# has to match, and build.sh verifies it. To match the compiler anyway: --build-arg BASE_IMAGE=gcc:16
ARG BASE_IMAGE=debian:trixie-slim
FROM ${BASE_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential bc bison flex libelf-dev libssl-dev kmod \
      xz-utils zstd cpio unzip squashfs-tools curl ca-certificates git python3 \
    && rm -rf /var/lib/apt/lists/*

COPY build.sh unraid-kernel-config.sh /opt/gpu-unlock-build/
RUN chmod +x /opt/gpu-unlock-build/*.sh

ENV OUT=/out CACHE=/cache
VOLUME ["/out", "/cache"]
WORKDIR /opt/gpu-unlock-build
ENTRYPOINT ["/opt/gpu-unlock-build/build.sh"]
