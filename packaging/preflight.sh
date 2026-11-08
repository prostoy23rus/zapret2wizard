#!/bin/sh
# Предустановочная проверка совместимости Zapret2Wizard.
# Запускается до распаковки файлов: лучше остановиться здесь, чем получить
# неработающую службу. Код возврата: 0 — можно ставить, 1 — нельзя.

FAIL=0
WARN=0

ok()   { printf '  \033[32mOK\033[0m   %s\n' "$1"; }
warn() { printf '  \033[33mWARN\033[0m %s\n' "$1"; WARN=$((WARN + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

echo "=== Проверка совместимости ==="

# 1. OpenWrt / совместимая прошивка
if [ -f /etc/openwrt_release ]; then
    . /etc/openwrt_release 2>/dev/null
    ok "прошивка: ${DISTRIB_DESCRIPTION:-OpenWrt}"
else
    warn "нет /etc/openwrt_release — прошивка не OpenWrt, возможны отличия"
fi

# 2. Архитектура
ARCH=$(uname -m 2>/dev/null)
case "$ARCH" in
    aarch64) ok "архитектура: $ARCH (поддерживается)" ;;
    armv7l|armv6l) ok "архитектура: $ARCH (нужен сканер под arm)" ;;
    mips|mips64|mipsel) ok "архитектура: $ARCH (нужен сканер под mips)" ;;
    x86_64|riscv64) ok "архитектура: $ARCH (нужен сканер под $ARCH)" ;;
    *) warn "архитектура $ARCH — движок может отсутствовать" ;;
esac

# 3. nftables и ядро
if command -v nft >/dev/null 2>&1; then
    if nft list tables >/dev/null 2>&1; then
        ok "nftables работает"
    else
        bad "nft есть, но не может управлять таблицами: нужен модуль nf_tables"
    fi
else
    bad "нет nft — установите пакет nftables"
fi

if [ -e /proc/net/netfilter ] || [ -e /proc/net/netfilter/nfnetlink_queue ]; then
    ok "nfqueue доступен"
else
    warn "не видно /proc/net/netfilter: модуль nfnetlink_queue может отсутствовать"
fi

# 4. procd/ubus (необходим для службы)
if command -v ubus >/dev/null 2>&1 || [ -x /sbin/procd ]; then
    ok "procd/ubus на месте"
else
    bad "нет procd/ubus — служба не сможет запускаться"
fi

# 5. Память
MEM=$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
if [ "${MEM:-0}" -ge 60000 ]; then
    ok "память: $((MEM / 1024)) МБ"
elif [ "${MEM:-0}" -ge 40000 ]; then
    warn "память: $((MEM / 1024)) МБ — может не хватить для подбора стратегий"
else
    bad "память: $((MEM / 1024)) МБ — служба и сканер не поместятся"
fi

# 6. Свободное место
FREE=$(df -k / 2>/dev/null | awk 'NR==2{print $4}')
if [ "${FREE:-0}" -ge 3000 ]; then
    ok "свободно на /: $((FREE / 1024)) МБ"
else
    bad "свободно на /: $((FREE / 1024)) МБ — нужно минимум 3 МБ"
fi

# 7. Чем скачивать
if command -v curl >/dev/null 2>&1; then
    ok "curl есть"
elif command -v wget >/dev/null 2>&1; then
    ok "wget есть"
else
    bad "нет ни curl, ни wget — не получится скачать движок"
fi

# 8. Пакетный менеджер (не критично, установка идёт файлами)
if command -v apk >/dev/null 2>&1; then
    ok "пакетный менеджер: apk (OpenWrt 25.x)"
elif command -v opkg >/dev/null 2>&1; then
    ok "пакетный менеджер: opkg"
else
    warn "нет apk/opkg — ставим файлами, это допустимо"
fi

# 9. Конфликтующие движки DPI
CONFLICT=0
for c in /proc/[0-9]*/comm; do
    [ -r "$c" ] || continue
    name=$(cat "$c" 2>/dev/null)
    case "$name" in
        nfqws|nfqws2|tpws|winws) ;;
        *) continue ;;
    esac
    # свои движки (запущены этой службой) не считаем чужими
    pid=${c#/proc/}; pid=${pid%/comm}
    case "$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)" in
        *zapret2wizard*) continue ;;
    esac
    CONFLICT=$((CONFLICT + 1))
done
if [ "$CONFLICT" -gt 0 ]; then
    warn "найдено чужих движков DPI: $CONFLICT — служба освободит очереди при старте"
else
    ok "конфликтующих движков нет"
fi

echo
if [ "$FAIL" -gt 0 ]; then
    echo "=== Итог: установка невозможна (ошибок: $FAIL, предупреждений: $WARN) ==="
    exit 1
fi
echo "=== Итог: можно устанавливать (предупреждений: $WARN) ==="
exit 0
