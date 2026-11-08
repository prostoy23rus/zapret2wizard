#!/usr/bin/env bash
# Подготовка окружения WSL для кросс-сборки blockcheckw под роутер (aarch64 musl).
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

echo "=== 1/4 apt packages ==="
apt-get update -qq
apt-get install -y -qq build-essential cmake pkg-config git curl xz-utils ca-certificates perl

echo "=== 2/4 rustup ==="
if [ ! -x "$HOME/.cargo/bin/cargo" ]; then
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
fi
# shellcheck disable=SC1091
. "$HOME/.cargo/env"
rustup target add aarch64-unknown-linux-musl

echo "=== 3/4 musl cross toolchain ==="
if [ ! -x /opt/aarch64-linux-musl-cross/bin/aarch64-linux-musl-gcc ]; then
  mkdir -p /opt
  curl -fsSL https://musl.cc/aarch64-linux-musl-cross.tgz -o /tmp/musl.tgz
  tar xzf /tmp/musl.tgz -C /opt
  rm -f /tmp/musl.tgz
fi
/opt/aarch64-linux-musl-cross/bin/aarch64-linux-musl-gcc --version | head -1

echo "=== 4/4 versions ==="
cargo --version
rustc --version
echo "SETUP_OK"
