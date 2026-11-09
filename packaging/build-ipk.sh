#!/bin/bash
# Сборка .ipk штатными средствами (ar + tar) внутри Linux.
# Запуск: bash packaging/build-ipk.sh <arch> <engine-file> [scanner-file] [out-dir]
set -euo pipefail

ARCH="${1:?архитектура, например aarch64_cortex-a53}"
ENGINE="${2:?путь к nfqws2 под эту архитектуру}"
SCANNER="${3:-}"
OUT="${4:-dist}"

REPO="$(cd "$(dirname "$0")/.." && pwd)"
VERSION=$(grep -o '"version": *"[^"]*"' "$REPO/openwrt/version.json" | head -1 | cut -d'"' -f4)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

DATA="$WORK/data"
CTRL="$WORK/control"
mkdir -p "$DATA" "$CTRL"

cp -a "$REPO/openwrt/luci-app-blockcheckw/root/." "$DATA/"
cp -f "$ENGINE" "$DATA/usr/bin/nfqws2"
[ -n "$SCANNER" ] && cp -f "$SCANNER" "$DATA/usr/bin/blockcheckw"

chmod 755 "$DATA/usr/bin/blockcheckw-helper" "$DATA/usr/bin/circular-builder.lua" \
          "$DATA/etc/init.d/zapret2wizard" "$DATA/usr/share/zapret2wizard/uci2config" \
          "$DATA/usr/bin/nfqws2"
[ -f "$DATA/usr/bin/blockcheckw" ] && chmod 755 "$DATA/usr/bin/blockcheckw"
chmod 644 "$DATA/www/luci-static/resources/view/blockcheckw/main.js"

mkdir -p "$DATA/opt/zapret2/nfq2"
ln -sf /usr/bin/nfqws2 "$DATA/opt/zapret2/nfq2/nfqws2"
ln -sf /usr/bin/blockcheckw-helper "$DATA/usr/bin/zapret2wizard"

SIZE=$(du -sk "$DATA" | cut -f1)

cat > "$CTRL/control" <<EOF
Package: luci-app-blockcheckw
Version: ${VERSION}-1
Depends: libc, luci-base, nftables, curl, ca-bundle
Section: luci
Priority: optional
Architecture: ${ARCH}
Installed-Size: ${SIZE}
Maintainer: prostoy23rus <https://github.com/prostoy23rus/zapret2wizard>
Description: Zapret2Wizard ${VERSION} — автономный обход DPI (Zapret2)
 Включает LuCI-интерфейс, helper, сканер blockcheckw и движок nfqws2.
EOF

cat > "$CTRL/postinst" <<'EOF'
#!/bin/sh
[ -n "$IPKG_INSTROOT" ] && exit 0
rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache* 2>/dev/null || true
# busybox без timeout: перезапуск в фоне, но с закрытыми унаследованными fd —
# иначе ребёнок держит блокировку opkg и следующая установка не возьмёт lock.
/etc/init.d/zapret2wizard enable >/dev/null 2>&1 || true
( exec 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&-; /etc/init.d/rpcd restart >/dev/null 2>&1; /etc/init.d/uhttpd restart >/dev/null 2>&1; /etc/init.d/zapret2wizard restart >/dev/null 2>&1 ) </dev/null >/dev/null 2>&1 &
exit 0
EOF

cat > "$CTRL/prerm" <<'EOF'
#!/bin/sh
[ -n "$IPKG_INSTROOT" ] && exit 0
/etc/init.d/zapret2wizard stop >/dev/null 2>&1 || true
exit 0
EOF

chmod 755 "$CTRL/postinst" "$CTRL/prerm"

# conffiles — конфиг не перетирается при обновлении
echo "/etc/config/zapret2wizard" > "$CTRL/conffiles"
chmod 644 "$CTRL/conffiles"

mkdir -p "$REPO/$OUT"
PKG="$REPO/$OUT/luci-app-blockcheckw_${VERSION}-1_${ARCH}.ipk"

(cd "$CTRL" && tar --owner=0 --group=0 --numeric-owner -czf "$WORK/control.tar.gz" ./control ./postinst ./prerm ./conffiles)
(cd "$DATA" && tar --owner=0 --group=0 --numeric-owner -czf "$WORK/data.tar.gz" .)
echo "2.0" > "$WORK/debian-binary"

rm -f "$PKG"
# Формат пакета OpenWrt 24.10: gzip(tar) с ./debian-binary, ./control.tar.gz,
# ./data.tar.gz. Классический ar (GNU ar) opkg 24.10 не читает:
# "pkg_init_from_file: Malformed package file".
( cd "$WORK" && tar --owner=0 --group=0 --numeric-owner -czf "$PKG" ./debian-binary ./control.tar.gz ./data.tar.gz )

ls -la "$PKG"
echo "IPK_OK $PKG"
