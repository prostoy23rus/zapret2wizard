#!/bin/sh
# Проверка quic_mode=fake без роутера: UCI-заглушка, реальный helper.
#   sh tools/test_quic_mode.sh
set -u

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
HELPER="$ROOT/openwrt/luci-app-blockcheckw/root/usr/bin/blockcheckw-helper"
BLOB="$ROOT/openwrt/luci-app-blockcheckw/root/usr/share/zapret2wizard/fake/quic_initial_www_google_com.bin"
[ -f "$HELPER" ] || { echo "helper not found"; exit 1; }
[ -f "$BLOB" ] || { echo "blob not found"; exit 1; }
BCW_QUIC_BLOB="$BLOB"; export BCW_QUIC_BLOB
BCW_QUIC_NO_RESTART=1; export BCW_QUIC_NO_RESTART

BCW_LIB_ONLY=1
. "$HELPER"

T=$(mktemp -d /tmp/bcw-quic-test.XXXXXX)
trap 'rm -rf "$T"' EXIT INT TERM
: > "$T/sets"

uci() {
    case "$*" in
        "-q get zapret2wizard.main.quic_mode") echo fake ;;
        "-q get firewall.reject_quic.enabled") echo 1 ;;
        "-q get firewall.reject_quic") echo rule ;;
        "-q get zapret2wizard.BlockcheckW_QUIC") echo "" ;;
        *" set "*) echo "$*" >> "$T/sets" ;;
        *) echo "" ;;
    esac
}
_svc_running() { return 1; }
sysctl() { return 0; }

out=$(cmd_quic_mode)
echo "$out"
echo "$out" | grep -q '"fake_quic":1' || { echo "FAIL: fake not enabled"; exit 1; }
grep -q 'blob_quic_google' "$T/sets" || { echo "FAIL: blob section"; exit 1; }
grep -q 'BlockcheckW_QUIC.script' "$T/sets" || { echo "FAIL: strategy"; exit 1; }
grep -q 'quic_initial' "$T/sets" || { echo "FAIL: payload"; exit 1; }
echo "OK: quic fake"
