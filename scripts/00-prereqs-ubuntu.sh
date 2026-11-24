#!/usr/bin/env bash
# 00-prereqs-ubuntu.sh - install host prerequisites for the PnC testbed.
# Target: Ubuntu 22.04/24.04 (bare metal, WSL2, or a small cloud VM, 4+ GB RAM).
# Combines the dependency list from the current EVerest "Get started in
# Software" guide with the extras this testbed needs (Java for the EXI codec,
# packet capture, network emulation).
set -euo pipefail

if [[ $EUID -eq 0 ]]; then
  SUDO=""
else
  SUDO="sudo"
fi

$SUDO apt-get update
$SUDO apt-get install -y \
  python3-pip python3-venv git rsync wget curl cmake doxygen \
  graphviz build-essential clang-tidy cppcheck npm docker.io \
  docker-compose libboost-all-dev nodejs libssl-dev libsqlite3-dev \
  openjdk-17-jre-headless \
  iproute2 net-tools tcpdump tshark wireshark-common jq \
  pkg-config libffi-dev \
  libsystemd-dev libpcap-dev libevent-dev libcurl4-openssl-dev libcap-dev
# The last line covers libraries the EVerest build and its dependencies link
# against (missing any of them fails the native build with a confusing
# "package not found" deep in CMake): libsystemd (EVerest error handling),
# libpcap (packet capture), libevent and libcurl (OCPP/libwebsockets stack),
# libcap (everest-framework capability checks).

# Python tooling: poetry (josev's build system) via pipx.
# Ubuntu 24.04 marks the system Python externally managed (PEP 668), so
# `pip install --user` fails; pipx is the supported route.
$SUDO apt-get install -y pipx
pipx install poetry
pipx ensurepath

# Docker without sudo (log out/in afterwards, or run: newgrp docker)
if ! groups "$USER" | grep -q '\bdocker\b'; then
  $SUDO usermod -aG docker "$USER"
  echo "NOTE: added $USER to the docker group - log out and back in for it to take effect."
fi

# Environment variables the EVerest build expects (idempotent append)
if ! grep -q CPM_SOURCE_CACHE ~/.bashrc; then
  {
    echo 'export CPM_SOURCE_CACHE=$HOME/.cache/CPM'
    echo 'export PATH=$PATH:$HOME/.local/bin'
  } >> ~/.bashrc
  echo "NOTE: appended CPM_SOURCE_CACHE and PATH exports to ~/.bashrc - open a new shell or: source ~/.bashrc"
fi

echo "Prerequisites installed. Java: $(java -version 2>&1 | head -1)"
