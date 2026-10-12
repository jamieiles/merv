# Development environment for merv: simulator, RTL simulation, firmware and
# the OpenSBI/Linux build.  Vivado is not included.
ARG BUILD_BASE=ubuntu:26.04
FROM $BUILD_BASE
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install --no-install-recommends -y \
    bc \
    bison \
    libboost-iostreams-dev \
    build-essential \
    ca-certificates \
    ccache \
    cmake \
    cpio \
    device-tree-compiler \
    flex \
    gcc-riscv64-linux-gnu \
    gcc-riscv64-unknown-elf \
    git \
    libnewlib-dev \
    libssl-dev \
    ninja-build \
    python3 \
    rsync \
    verilator \
    yosys \
    zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*
