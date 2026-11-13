#!/bin/sh
# Зафиксировать текущую рабочую сборку как baseline для ремонта.
set -eu
VER=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' /usr/share/blockcheckw/version.json 2>/dev/null | head -n1)
[ -n "$VER" ] || { echo "version not found" >&2; exit 1; }
BASE="/etc/zapret2wizard/baseline-$VER"
mkdir -p "$BASE"
cp -f /etc/config/zapret2wizard "$BASE/zapret2wizard.config" 2>/dev/null || true
cp -f /etc/zapret2wizard/.last_good_config "$BASE/.last_good_config" 2>/dev/null || true
cp -f /usr/bin/blockcheckw-helper "$BASE/blockcheckw-helper" 2>/dev/null || true
cp -f /etc/init.d/zapret2wizard "$BASE/zapret2wizard.init" 2>/dev/null || true
cp -f /www/luci-static/resources/view/blockcheckw/main.js "$BASE/main.js" 2>/dev/null || true
cp -f /usr/share/blockcheckw/version.json "$BASE/version.json" 2>/dev/null || true
if [ -d /etc/zapret2wizard/ipset ]; then
    mkdir -p "$BASE/ipset"
    cp -f /etc/zapret2wizard/ipset/*.txt "$BASE/ipset/" 2>/dev/null || true
fi
cat > "$BASE/README.txt" <<EOF
Zapret2Wizard baseline $VER
Created: $(date -u +%Y-%m-%dT%H:%M:%SZ)
Это снимок рабочей конфигурации и файлов службы.
Восстановление: sh /usr/share/zapret2wizard/baseline_restore.sh $BASE
EOF
( cd "$BASE" && sha256sum $(find . -type f ! -name SHA256SUMS | sort) > SHA256SUMS )
echo "baseline: $BASE"
echo "files: $(find "$BASE" -type f | wc -l)"
echo "checksums: $BASE/SHA256SUMS"
