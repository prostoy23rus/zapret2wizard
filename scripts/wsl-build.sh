#!/usr/bin/env bash
# Кросс-сборка blockcheckw под aarch64 musl (роутер) внутри WSL.
set -euo pipefail

# shellcheck disable=SC1091
. "$HOME/.cargo/env"

export PATH="/opt/aarch64-linux-musl-cross/bin:$PATH"
export CC_aarch64_unknown_linux_musl=aarch64-linux-musl-gcc
export AR_aarch64_unknown_linux_musl=aarch64-linux-musl-ar
export CXX_aarch64_unknown_linux_musl=aarch64-linux-musl-g++
export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER=aarch64-linux-musl-gcc

cd /mnt/e/AI/zapret2wizard

echo "=== build ==="
cargo build --release --target aarch64-unknown-linux-musl 2>&1 | tail -n 30

BIN=target/aarch64-unknown-linux-musl/release/blockcheckw
ls -la "$BIN"
file "$BIN" || true

mkdir -p /mnt/e/deepseek/build
cp -f "$BIN" /mnt/e/deepseek/build/blockcheckw-aarch64
ls -la /mnt/e/deepseek/build/blockcheckw-aarch64
echo "BUILD_OK"
