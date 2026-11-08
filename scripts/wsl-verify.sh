#!/usr/bin/env bash
# Проверки CI внутри WSL (native x86_64 Linux).
set -uo pipefail
# shellcheck disable=SC1091
. "$HOME/.cargo/env"
cd /mnt/e/AI/zapret2wizard

echo "=== cargo fmt --check ==="
cargo fmt --check && echo "FMT_OK" || echo "FMT_FAIL"

echo "=== cargo clippy -- -D warnings ==="
cargo clippy -- -D warnings 2>&1 | tail -n 15
echo "CLIPPY_EXIT=${PIPESTATUS[0]}"

echo "=== cargo test --lib --features otel ==="
cargo test --lib --features otel 2>&1 | tail -n 25
echo "TEST_EXIT=${PIPESTATUS[0]}"
