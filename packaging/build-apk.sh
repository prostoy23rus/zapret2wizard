#!/bin/sh
# Сборка .apk для OpenWrt 25.x из готового бандла.
#
# Почему так: формат apk v3 (ADB) нельзя собрать вручную — его создаёт только
# applet `apk mkpkg`. В прошивке этого applet-а нет, поэтому берём apk-tools 3
# с хоста (APK_BIN) или собранный в CI.
#
# Использование:
#   APK_BIN=/path/to/apk ./packaging/build-apk.sh \
#       --bundle dist/zapret2wizard-X-ARCH-bundle.tar.gz \
#       --out dist
#
# В CI apk-tools 3 собирается из исходников (см. .github/workflows/build.yml).

set -e
BUNDLE=""
OUT="dist"
PKGNAME="zapret2wizard"

while [ $# -gt 0 ]; do
    case "$1" in
        --bundle) BUNDLE="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --apk-bin) APK_BIN="$2"; shift 2 ;;
        *) echo "неизвестный аргумент: $1" >&2; exit 1 ;;
    esac
done

[ -n "$BUNDLE" ] || { echo "укажите --bundle <файл>" >&2; exit 1; }
[ -f "$BUNDLE" ] || { echo "нет файла $BUNDLE" >&2; exit 1; }
APK_BIN="${APK_BIN:-apk}"
command -v "$APK_BIN" >/dev/null 2>&1 || { echo "не найден apk (APK_BIN=$APK_BIN)" >&2; exit 1; }

BASE=$(basename "$BUNDLE")
VERSION=$(echo "$BASE" | sed -n 's/^zapret2wizard-\([0-9.]*\)-.*/\1/p')
ARCH=$(echo "$BASE" | sed -n 's/^zapret2wizard-[0-9.]*-\(.*\)-bundle\.tar\.gz$/\1/p')
[ -n "$VERSION" ] && [ -n "$ARCH" ] || { echo "не разобрал имя бандла: $BASE" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/unpack" "$WORK/root"
tar -xzf "$BUNDLE" -C "$WORK/unpack"
INNER=$(find "$WORK/unpack" -name payload.tar | head -n 1)
[ -n "$INNER" ] || { echo "в бандле нет payload.tar" >&2; exit 1; }
tar -xf "$INNER" -C "$WORK/root"
PAYLOAD="$WORK/root/payload"
[ -d "$PAYLOAD" ] || { echo "нет каталога payload после распаковки" >&2; exit 1; }

# conffiles: конфиг со стратегиями не должен затираться при обновлении
mkdir -p "$PAYLOAD/lib/apk/packages"
echo "/etc/config/zapret2wizard" > "$PAYLOAD/lib/apk/packages/$PKGNAME.conffiles"

cat > "$WORK/post-install" <<'EOF'
#!/bin/sh
rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache* 2>/dev/null || true
( /etc/init.d/rpcd restart >/dev/null 2>&1 </dev/null & )
( /etc/init.d/uhttpd restart >/dev/null 2>&1 </dev/null & )
/usr/bin/blockcheckw-helper kmods_modprobe >/dev/null 2>&1 || true
/etc/init.d/zapret2wizard enable >/dev/null 2>&1 || true
/usr/bin/blockcheckw-helper cron_install >/dev/null 2>&1 || true
( /etc/init.d/zapret2wizard restart >/dev/null 2>&1 </dev/null & )
if [ "$(uci show zapret2wizard 2>/dev/null | grep -c '=strategy')" -eq 0 ]; then
    (/usr/bin/blockcheckw-helper autosetup >/tmp/bcw_autosetup.log 2>&1 &) || true
fi
exit 0
EOF

cat > "$WORK/pre-deinstall" <<'EOF'
#!/bin/sh
/etc/init.d/zapret2wizard stop >/dev/null 2>&1 || true
/etc/init.d/zapret2wizard disable >/dev/null 2>&1 || true
exit 0
EOF
chmod 755 "$WORK/post-install" "$WORK/pre-deinstall"

mkdir -p "$OUT"
OUTFILE="$OUT/${PKGNAME}_${VERSION}-r1_${ARCH}.apk"

"$APK_BIN" mkpkg \
    --info "name:$PKGNAME" \
    --info "version:${VERSION}-r1" \
    --info "description:Zapret2Wizard ${VERSION} - autonomous DPI bypass (Zapret2) with LuCI, scanner and engine" \
    --info "arch:$ARCH" \
    --info "license:MIT" \
    --info "origin:$PKGNAME" \
    --info "maintainer:prostoy23rus" \
    --info "url:https://github.com/prostoy23rus/zapret2wizard" \
    --info "depends:nftables curl ca-bundle" \
    --script "post-install:$WORK/post-install" \
    --script "pre-deinstall:$WORK/pre-deinstall" \
    --files "$PAYLOAD" \
    --output "$OUTFILE"

echo "apk: $OUTFILE ($(wc -c < "$OUTFILE") bytes)"
echo "установка: scp -O $OUTFILE root@РОУТЕР:/tmp/ && ssh root@РОУТЕР 'apk add --allow-untrusted /tmp/$(basename "$OUTFILE")'"
