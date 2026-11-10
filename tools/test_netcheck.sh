#!/bin/sh
# Проверка netcheck без сети: curl/nslookup-заглушки.
#   sh tools/test_netcheck.sh
set -u

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
HELPER="$ROOT/openwrt/luci-app-blockcheckw/root/usr/bin/blockcheckw-helper"
[ -f "$HELPER" ] || { echo "helper not found"; exit 1; }
BCW_LIB_ONLY=1
. "$HELPER"

curl() {
    case "$*" in
        *"-r 0-65535"*) echo 16384 ;;
        *) echo 200 ;;
    esac
}
nslookup() {
    case "$2" in
        127.0.0.1) printf 'Name: %s\nAddress: 8.6.112.0\n' "$1" ;;
        1.1.1.1) printf 'Name: %s\nAddress: 142.250.1.1\n' "$1" ;;
        *) return 0 ;;
    esac
}

json_ok() {
    command -v python3 >/dev/null 2>&1 || return 0
    printf '%s' "$1" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null \
        || { echo "FAIL: not valid JSON"; exit 1; }
}

out=$(cmd_netcheck)
echo "$out"
json_ok "$out"
echo "$out" | grep -q '"blocking":"throttle_16k"' || { echo "FAIL: throttle"; exit 1; }
echo "$out" | grep -q '"dns":"spoof"' || { echo "FAIL: dns"; exit 1; }

# Все запросы падают: curl отдаёт 000 и ненулевой код возврата. Классификация
# должна быть "нет интернета", а не "whitelist" (регрессия была из-за
# "curl ... || echo 000" — получалось два кода подряд).
curl() { echo 000; }
nslookup() { return 0; }
out=$(cmd_netcheck)
echo "$out"
echo "$out" | grep -q '"blocking":"no_internet"' || { echo "FAIL: no_internet"; exit 1; }
echo "$out" | grep -q '"ok":false' || { echo "FAIL: ok flag"; exit 1; }

echo "OK: netcheck"
