#!/bin/sh
# Восстановить зафиксированный baseline (только служба, без сети/DNS).
set -eu
BASE="${1:-}"
[ -n "$BASE" ] && [ -d "$BASE" ] || { echo "usage: $0 /etc/zapret2wizard/baseline-0.36.0" >&2; exit 1; }
cd "$BASE"
[ -f SHA256SUMS ] || { echo "SHA256SUMS not found" >&2; exit 1; }
sha256sum -c SHA256SUMS >/dev/null || { echo "baseline checksum mismatch" >&2; exit 1; }
cp -f "$BASE/zapret2wizard.config" /etc/config/zapret2wizard
[ -f "$BASE/.last_good_config" ] && cp -f "$BASE/.last_good_config" /etc/zapret2wizard/.last_good_config
[ -f "$BASE/blockcheckw-helper" ] && cp -f "$BASE/blockcheckw-helper" /usr/bin/blockcheckw-helper
[ -f "$BASE/zapret2wizard.init" ] && cp -f "$BASE/zapret2wizard.init" /etc/init.d/zapret2wizard
[ -f "$BASE/main.js" ] && cp -f "$BASE/main.js" /www/luci-static/resources/view/blockcheckw/main.js
[ -f "$BASE/version.json" ] && cp -f "$BASE/version.json" /usr/share/blockcheckw/version.json
[ -d "$BASE/ipset" ] && mkdir -p /etc/zapret2wizard/ipset && cp -f "$BASE"/ipset/*.txt /etc/zapret2wizard/ipset/ 2>/dev/null || true
chmod +x /usr/bin/blockcheckw-helper /etc/init.d/zapret2wizard
uci -q commit zapret2wizard
rm -f /tmp/luci-indexcache*
/etc/init.d/zapret2wizard restart >/dev/null 2>&1 || true
echo "baseline restored: $BASE"
