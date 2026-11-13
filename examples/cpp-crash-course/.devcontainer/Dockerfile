# Linux toolbox for C++ Crash Course: the tools most C++ teams use day to day.
# Ubuntu 24.04 on arm64 runs natively on Apple-silicon Macs (no emulation).
FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential gdb valgrind strace ltrace \
        make cmake ninja-build \
        clangd clang-format \
        libboost-dev libboost-program-options-dev libboost-test-dev \
        catch2 libgtest-dev libgmock-dev \
        python3 git vim less man-db file curl netcat-openbsd ca-certificates sudo \
    && rm -rf /var/lib/apt/lists/* \
    && echo "ubuntu ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/ubuntu

# quest builds with $CXX, so inside the container it uses GCC.
ENV LANG=C.UTF-8 \
    CXX=g++

USER ubuntu
WORKDIR /workspaces
