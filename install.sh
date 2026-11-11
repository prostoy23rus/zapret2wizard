#!/bin/sh
# ==============================================================================
# Zapret2Wizard & LuCI Universal Installer for OpenWrt
# Repository: https://github.com/prostoy23rus/zapret2wizard
# Supported OpenWrt: 21.02, 22.03, 23.05, 24.10, 25.x, snapshot (opkg & apk)
# ==============================================================================

set -e

# Terminal colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

REPO_RAW="https://raw.githubusercontent.com/prostoy23rus/zapret2wizard/main"
REPO_OWNER="prostoy23rus"
REPO_NAME="zapret2wizard"
UPSTREAM_OWNER="rcd27"

# Один коммит на всю установку: ветка main в CDN кэшируется до 12 часов,
# из-за чего часть файлов приезжала старой версии (version.json 0.19.1 при
# helper 0.19.2). Пин на SHA убирает и рассинхрон, и устаревший кэш.
BCW_SHA=""
resolve_sha() {
    [ -n "$BCW_SHA" ] && return 0
    BCW_SHA=$(curl -fsSL -k --connect-timeout 4 -m 10 \
        "https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/commits/main" 2>/dev/null \
        | sed -n 's/.*"sha": *"\([0-9a-f]\{40\}\)".*/\1/p' | head -n1)
    [ -n "$BCW_SHA" ] || BCW_SHA="main"
}

# Multi-mirror downloader function (GitHub Raw + jsDelivr Global CDN + Fastly + GHProxy)
fetch_file() {
    local rel_path="$1"
    local dest="$2"
    local timeout="${3:-8}"
    local tmp_file="${dest}.dl.$$"

    rm -f "$tmp_file"
    resolve_sha
    local ref="$BCW_SHA"

    _save_download() {
        if [ -s "$tmp_file" ]; then
            # Verify file does not contain HTML error page
            if head -n 3 "$tmp_file" | grep -qiE 'not found|404|bad gateway|502|<html>|<head>|access denied'; then
                rm -f "$tmp_file"
                return 1
            fi
            mv -f "$tmp_file" "$dest"
            return 0
        fi
        rm -f "$tmp_file"
        return 1
    }

    # 1. Обычный GitHub Raw (DNS провайдера). Пиннинг IP ниже — запасной путь,
    #    потому что у части провайдеров адреса GitHub недоступны.
    curl -fsSL -k --connect-timeout 4 -m "$timeout" "https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${ref}/$rel_path?$(date +%s)" -o "$tmp_file" 2>/dev/null
    _save_download && return 0

    # 1b. GitHub Raw с пиннингом IP
    for gh_ip in 185.199.108.133 185.199.111.133 185.199.109.133 185.199.110.133; do
        curl -fsSL -k --connect-timeout 2 -m "$timeout" --resolve "raw.githubusercontent.com:443:$gh_ip" "https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${ref}/$rel_path" -o "$tmp_file" 2>/dev/null
        _save_download && return 0
    done

    # 2. GHProxy Real-Time Mirror
    curl -fsSL -k --connect-timeout 3 -m "$timeout" "https://ghproxy.net/https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${ref}/$rel_path" -o "$tmp_file" 2>/dev/null
    _save_download && return 0

    # 3. jsDelivr Global CDN Fallback
    curl -fsSL -k --connect-timeout "$timeout" "https://cdn.jsdelivr.net/gh/${REPO_OWNER}/${REPO_NAME}@${ref}/$rel_path" -o "$tmp_file" 2>/dev/null
    _save_download && return 0

    # 4. Fastly jsDelivr CDN Fallback
    curl -fsSL -k --connect-timeout "$timeout" "https://fastly.jsdelivr.net/gh/${REPO_OWNER}/${REPO_NAME}@${ref}/$rel_path" -o "$tmp_file" 2>/dev/null
    _save_download && return 0

    rm -f "$tmp_file"
    return 1
}

echo -e "${CYAN}${BOLD}"
echo "  _____                  _   ___  __          ___                  _ "
echo " |__  / __ _ _ __  _ __ ___| |_|__ \ \ \        / (_)______ _ _ __ __| |"
echo "   / / / _\` | '_ \| '__/ _ \ __| / /  \ \  /\  / /| |_  / _\` | '__/ _\` |"
echo "  / /_| (_| | |_) | | |  __/ |_ / /_   \ \/  \/ / | |/ / (_| | | | (_| |"
echo " /____|\__,_| .__/|_|  \___|\__|____|   \__/\__/  |_/___\__,_|_|  \__,_|"
echo "            |_|                                                         "
echo -e "${NC}"
echo -e "${BOLD}Zapret2Wizard — Универсальный мастер и LuCI интерфейс для OpenWrt${NC}"
echo -e "Репозиторий: ${BLUE}https://github.com/${REPO_OWNER}/${REPO_NAME}${NC}\n"

# Проверка режима деинсталляции
if [ "$1" = "--uninstall" ] || [ "$1" = "-u" ] || [ "$1" = "uninstall" ]; then
    shift
    echo -e "${YELLOW}ℹ${NC} Запуск деинсталлятора Zapret2Wizard..."
    if [ -f "$(dirname "$0")/uninstall.sh" ]; then
        exec sh "$(dirname "$0")/uninstall.sh" "$@"
    else
        exec sh -c "$(curl -sSL -k "$REPO_RAW/uninstall.sh")" -- "$@"
    fi
    exit 0
fi

# 1. Проверка прав суперпользователя (root)
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}[ERROR] Скрипт установки должен быть запущен от имени root!${NC}"
    exit 1
fi

# 1.5. Предустановочная проверка совместимости
if [ "${SKIP_PREFLIGHT:-0}" != "1" ]; then
    if fetch_file "packaging/preflight.sh" /tmp/bcw_preflight.sh 8; then
        if ! sh /tmp/bcw_preflight.sh; then
            rm -f /tmp/bcw_preflight.sh
            echo -e "${RED}[ERROR] Устройство не подходит для установки.${NC}"
            echo -e "${YELLOW}Повторить без проверки:${NC} SKIP_PREFLIGHT=1 sh -c \"\$(curl -sSL <адрес install.sh>)\""
            exit 1
        fi
        rm -f /tmp/bcw_preflight.sh
    else
        echo -e "${YELLOW}[WARN] Не удалось скачать preflight.sh — продолжаю без проверки.${NC}"
    fi
fi

# 2. Определение окружения OpenWrt
if [ ! -f /etc/openwrt_release ] && [ ! -f /etc/os-release ]; then
    echo -e "${YELLOW}[WARN] Файл /etc/openwrt_release не найден. Возможно, это не OpenWrt.${NC}"
fi

OWRT_VER="unknown"
if [ -f /etc/openwrt_release ]; then
    . /etc/openwrt_release
    OWRT_VER="${DISTRIB_DESCRIPTION:-${DISTRIB_RELEASE}}"
    echo -e "${GREEN}✓${NC} Обнаружена система: ${BOLD}${OWRT_VER}${NC}"
fi

# 3. Определение архитектуры процессора
echo -e "${BLUE}ℹ${NC} Определение архитектуры устройства..."
detect_arch() {
    local u_arch=$(uname -m 2>/dev/null || echo "")
    local pkg_arch=""
    if command -v opkg >/dev/null 2>&1; then
        pkg_arch=$(opkg print-architecture 2>/dev/null | awk '{print $2}' | grep -v 'all\|noarch' | head -n1 || echo "")
    elif command -v apk >/dev/null 2>&1; then
        pkg_arch=$(apk --print-arch 2>/dev/null || echo "")
    fi

    case "$u_arch" in
        x86_64|amd64) echo "x86_64"; return ;;
        i*86|x86) echo "x86"; return ;;
        aarch64*|arm64*) echo "arm64"; return ;;
        armv7*|armv6*|arm*) echo "arm"; return ;;
        mips64*) echo "mips64"; return ;;
        mips*)
            if echo -n I | hexdump -o 2>/dev/null | grep -q '0000002 000001'; then
                echo "mipsel"
            elif lscpu 2>/dev/null | grep -qi "little endian"; then
                echo "mipsel"
            elif [ -n "$pkg_arch" ] && echo "$pkg_arch" | grep -q "mipsel"; then
                echo "mipsel"
            else
                echo "mips"
            fi
            return
            ;;
        riscv64*) echo "riscv64"; return ;;
        powerpc*|ppc*) echo "ppc"; return ;;
    esac

    if [ -n "$pkg_arch" ]; then
        case "$pkg_arch" in
            *aarch64*|*arm64*) echo "arm64"; return ;;
            *x86_64*|*amd64*) echo "x86_64"; return ;;
            *i386*|*x86*) echo "x86"; return ;;
            *arm*) echo "arm"; return ;;
            *mipsel*) echo "mipsel"; return ;;
            *mips*) echo "mips"; return ;;
            *riscv64*) echo "riscv64"; return ;;
            *ppc*|*powerpc*) echo "ppc"; return ;;
        esac
    fi

    echo "unknown"
}

ARCH=$(detect_arch)
if [ "$ARCH" = "unknown" ]; then
    echo -e "${RED}[ERROR] Не удалось автоматически определить архитектуру устройства (uname: $(uname -m)).${NC}"
    exit 1
fi
echo -e "${GREEN}✓${NC} Архитектура: ${BOLD}${ARCH}${NC} ($(uname -m))"

# Пакетная архитектура нужна для запасного пути через бандл с релиза
PKG_ARCH=""
if command -v opkg >/dev/null 2>&1; then
    PKG_ARCH=$(opkg print-architecture 2>/dev/null | awk '{print $2}' | grep -v 'all\|noarch' | head -n1)
elif command -v apk >/dev/null 2>&1; then
    PKG_ARCH=$(apk --print-arch 2>/dev/null)
fi

# 4. Проверка и установка зависимостей
echo -e "${BLUE}ℹ${NC} Проверка системных зависимостей (curl, ca-certificates/ca-bundle, tar)..."

if command -v apk >/dev/null 2>&1; then
    # OpenWrt 25.x / Next-Gen с apk-tools
    echo -e "${GREEN}✓${NC} Пакетный менеджер: ${BOLD}apk${NC} (OpenWrt 25.x / Next-Gen)"
    apk update || true
    for pkg in curl ca-certificates tar; do
        if ! apk info -e "$pkg" >/dev/null 2>&1; then
            echo -e "${YELLOW}ℹ${NC} Установка $pkg через apk..."
            apk add "$pkg" || true
        fi
    done
    # luci-compat не обязателен для современных JS-видов, но если доступен — устанавливаем
    if ! apk info -e "luci-compat" >/dev/null 2>&1; then
        apk add luci-compat >/dev/null 2>&1 || true
    fi
elif command -v opkg >/dev/null 2>&1; then
    # OpenWrt 21.02 - 24.10 с opkg
    echo -e "${GREEN}✓${NC} Пакетный менеджер: ${BOLD}opkg${NC}"
    NEED_UPDATE=0
    MISSING_PKGS=""
    for pkg in curl ca-bundle tar; do
        if ! opkg list-installed | grep -q "^${pkg} "; then
            MISSING_PKGS="$MISSING_PKGS $pkg"
            NEED_UPDATE=1
        fi
    done

    if [ "$NEED_UPDATE" -eq 1 ] && [ -n "$MISSING_PKGS" ]; then
        echo -e "${YELLOW}ℹ${NC} Установка недостающих пакетов:${MISSING_PKGS}..."
        opkg update || true
        for p in $MISSING_PKGS; do
            opkg install "$p" || {
                if [ "$p" = "ca-bundle" ]; then
                    opkg install ca-certificates || true
                fi
            }
        done
    else
        echo -e "${GREEN}✓${NC} Все необходимые системные пакеты уже установлены."
    fi

    # Пробуем установить luci-compat, если есть в репозитории (не ломая установку, если отсутствует)
    if ! opkg list-installed | grep -q "^luci-compat "; then
        opkg install luci-compat >/dev/null 2>&1 || true
    fi
else
    echo -e "${YELLOW}[WARN] Ни opkg, ни apk не обнаружены. Пропускаем автоматическую установку пакетов.${NC}"
fi

# 5. Скачивание скомпилированного бинарника blockcheckw
TMP_DIR="/tmp/bcw_install_$$"
mkdir -p "$TMP_DIR"
cd "$TMP_DIR"

BIN_NAME="blockcheckw-linux-${ARCH}.tar.gz"
echo -e "${BLUE}ℹ${NC} Скачивание сканера поиска стратегий для архитектуры ${BOLD}${ARCH}${NC}..."

DOWNLOAD_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/latest/download/${BIN_NAME}"
UPSTREAM_URL="https://github.com/${UPSTREAM_OWNER}/blockcheckw/releases/latest/download/${BIN_NAME}"

if ! curl -sSL -k -f --connect-timeout 8 "$DOWNLOAD_URL" -o "$BIN_NAME" 2>/dev/null; then
    echo -e "${YELLOW}ℹ${NC} Скачивание из репозитория ${REPO_OWNER} не удалось, пробуем зеркала и апстрим..."
    if ! curl -sSL -k -f --connect-timeout 10 "$UPSTREAM_URL" -o "$BIN_NAME" 2>/dev/null; then
        if ! curl -sSL -k -f --connect-timeout 10 "https://ghproxy.net/$UPSTREAM_URL" -o "$BIN_NAME"; then
            echo -e "${RED}[ERROR] Не удалось скачать бинарник blockcheckw для архитектуры ${ARCH}!${NC}"
            rm -rf "$TMP_DIR"
            exit 1
        fi
    fi
fi

tar -xzf "$BIN_NAME"
if [ ! -f "$TMP_DIR/blockcheckw" ]; then
    echo -e "${RED}[ERROR] Архив не содержит исполняемого файла blockcheckw!${NC}"
    rm -rf "$TMP_DIR"
    exit 1
fi

cp -f "$TMP_DIR/blockcheckw" /usr/bin/blockcheckw
chmod +x /usr/bin/blockcheckw
echo -e "${GREEN}✓${NC} Бинарник установлен: ${BOLD}/usr/bin/blockcheckw${NC}"

# 5.1. Установка автономного бинарника nfqws2 (All-in-One DPI Engine)
echo -e "${BLUE}ℹ${NC} Проверка и установка ядра десинхронизации nfqws2..."
if [ ! -x /usr/bin/nfqws2 ]; then
    if [ -x /opt/zapret2/nfq2/nfqws2 ]; then
        cp -f /opt/zapret2/nfq2/nfqws2 /usr/bin/nfqws2
        chmod +x /usr/bin/nfqws2
    fi
fi
if [ ! -x /usr/bin/nfqws2 ]; then
    # Сначала берём движок из нашего репозитория (raw-канал работает там,
    # где github.com с релизами недоступен).
    RAW_ENGINE="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/main/openwrt/engine/nfqws2-linux-${ARCH}?_t=$(date +%s)"
    if curl -fsSL -k --connect-timeout 6 -m 120 "$RAW_ENGINE" -o /tmp/nfqws2.raw 2>/dev/null && [ "$(wc -c < /tmp/nfqws2.raw 2>/dev/null || echo 0)" -gt 50000 ]; then
        cp -f /tmp/nfqws2.raw /usr/bin/nfqws2
        chmod +x /usr/bin/nfqws2
        echo -e "${GREEN}✓${NC} Движок nfqws2 получен из репозитория проекта."
    fi
    rm -f /tmp/nfqws2.raw
fi

if [ ! -x /usr/bin/nfqws2 ]; then
    ZAPRET_DIR="linux-${ARCH}"
    ZAPRET_TAG="v1.0.7"
    ZAPRET_TARBALL="zapret2-${ZAPRET_TAG}.tar.gz"
    ZAPRET_URL="https://github.com/bol-van/zapret2/releases/download/${ZAPRET_TAG}/${ZAPRET_TARBALL}"
    echo -e "${BLUE}ℹ${NC} Загрузка ядра nfqws2 для ${BOLD}${ZAPRET_DIR}${NC}..."

    _install_nfqws2() {
        local url="$1" out="/tmp/zap2.$$.tgz"
        rm -f "$out" /tmp/nfqws2.$$ 2>/dev/null
        curl -fsSL -k --connect-timeout 8 -m 180 "$url" -o "$out" 2>/dev/null || { rm -f "$out"; return 1; }
        [ -s "$out" ] || { rm -f "$out"; return 1; }
        tar -xz -O --wildcards "*/binaries/${ZAPRET_DIR}/nfqws2" < "$out" > /tmp/nfqws2.$$ 2>/dev/null
        local size=$(wc -c < /tmp/nfqws2.$$ 2>/dev/null || echo 0)
        rm -f "$out"
        if [ "${size:-0}" -gt 50000 ]; then
            cp -f /tmp/nfqws2.$$ /usr/bin/nfqws2
            chmod +x /usr/bin/nfqws2
            rm -f /tmp/nfqws2.$$
            return 0
        fi
        rm -f /tmp/nfqws2.$$
        return 1
    }

    # Прямой GitHub, затем зеркала; три попытки, потому что соединение бывает рваным.
    for attempt in 1 2 3; do
        _install_nfqws2 "$ZAPRET_URL" && break
        _install_nfqws2 "https://ghproxy.net/$ZAPRET_URL" && break
        _install_nfqws2 "https://gh-proxy.com/$ZAPRET_URL" && break
        echo -e "${YELLOW}ℹ${NC} Попытка ${attempt} не удалась, повтор..."
        sleep 2
    done
fi
# Бинарник мог скачаться не для этой архитектуры: без запуска движка
# подбор невозможен, поэтому проверяем, а не просто «файл есть».
if [ -x /usr/bin/nfqws2 ] && ! /usr/bin/nfqws2 --version >/dev/null 2>&1; then
    echo -e "${YELLOW}[WARN]${NC} /usr/bin/nfqws2 не запускается (не та архитектура?) — удаляю"
    rm -f /usr/bin/nfqws2
    NFQWS2_MISSING=1
fi
if [ -x /usr/bin/nfqws2 ]; then
    echo -e "${GREEN}✓${NC} Бинарник nfqws2 готов: ${BOLD}/usr/bin/nfqws2${NC}"
else
    NFQWS2_MISSING=1
    echo -e "${RED}[ERROR] nfqws2 не установлен — без него служба не запустится.${NC}"
    echo -e "${YELLOW}Установите вручную:${NC}"
    echo -e "  cd /tmp"
    echo -e "  curl -fsSL -k -m 180 \"https://github.com/bol-van/zapret2/releases/download/v1.0.7/zapret2-v1.0.7.tar.gz\" -o zap2.tgz"
    echo -e "  tar -xz -O --wildcards \"*/binaries/linux-${ARCH}/nfqws2\" < zap2.tgz > /usr/bin/nfqws2"
    echo -e "  chmod +x /usr/bin/nfqws2 && mkdir -p /opt/zapret2/nfq2 && ln -sf /usr/bin/nfqws2 /opt/zapret2/nfq2/nfqws2"
fi

# Rust-сканер blockcheckw ищет движок по <base>/nfq2/nfqws2 (src/config.rs),
# поэтому кладём совместимый симлинк рядом с остальными legacy-путями.
mkdir -p /opt/zapret2/nfq2 2>/dev/null || true
if [ -x /usr/bin/nfqws2 ] && [ ! -e /opt/zapret2/nfq2/nfqws2 ]; then
    ln -sf /usr/bin/nfqws2 /opt/zapret2/nfq2/nfqws2 2>/dev/null || true
fi

# Критичный файл: две попытки, ошибка не роняет скрипт, а копится в FAILED
FAILED=""
fetch_req() {
    local rel="$1" dest="$2" tmo="${3:-8}"
    if fetch_file "$rel" "$dest" "$tmo"; then return 0; fi
    sleep 1
    if fetch_file "$rel" "$dest" "$tmo"; then return 0; fi
    echo -e "${YELLOW}[WARN]${NC} Не удалось скачать $rel"
    FAILED="$FAILED $rel"
    return 1
}

# 6. Скачивание и установка компонентов автономной службы и LuCI
echo -e "${BLUE}ℹ${NC} Установка модулей Zapret2Wizard All-in-One..."

mkdir -p /usr/bin /usr/share/blockcheckw /usr/share/luci/menu.d /usr/share/rpcd/acl.d /www/luci-static/resources/view/blockcheckw
mkdir -p /usr/share/zapret2wizard/lua /usr/share/zapret2wizard/fake /usr/share/zapret2wizard/ipset /etc/zapret2wizard/ipset /etc/config /etc/init.d
chmod 755 /www/luci-static/resources/view/blockcheckw /usr/share/blockcheckw /usr/share/zapret2wizard 2>/dev/null || true

fetch_req "openwrt/luci-app-blockcheckw/root/usr/bin/blockcheckw-helper" /usr/bin/blockcheckw-helper 8
chmod +x /usr/bin/blockcheckw-helper 2>/dev/null || true
fetch_file "openwrt/luci-app-blockcheckw/root/usr/bin/circular-builder.lua" /usr/bin/circular-builder.lua 8 || true
fetch_req "openwrt/luci-app-blockcheckw/root/usr/share/zapret2wizard/uci2config" /usr/share/zapret2wizard/uci2config 8
fetch_file "openwrt/luci-app-blockcheckw/root/usr/share/zapret2wizard/evolve.lua" /usr/share/zapret2wizard/evolve.lua 8 || true
fetch_file "strategies/zapret2_presets.json" /usr/share/blockcheckw/zapret2_presets.json 8 || true
fetch_req "openwrt/version.json" /usr/share/blockcheckw/version.json 8
fetch_file "openwrt/luci-app-blockcheckw/root/usr/share/luci/menu.d/luci-app-blockcheckw.json" /usr/share/luci/menu.d/luci-app-blockcheckw.json 8 || true
fetch_file "openwrt/luci-app-blockcheckw/root/usr/share/rpcd/acl.d/luci-app-blockcheckw.json" /usr/share/rpcd/acl.d/luci-app-blockcheckw.json 8 || true
fetch_req "openwrt/luci-app-blockcheckw/root/www/luci-static/resources/view/blockcheckw/main.js" /www/luci-static/resources/view/blockcheckw/main.js 8
chmod 644 /www/luci-static/resources/view/blockcheckw/main.js 2>/dev/null || true

# Ключевые файлы обязательны: без них интерфейс не запустится.
chmod +x /usr/bin/blockcheckw-helper 2>/dev/null || true
HELPER_SIZE=$(wc -c < /usr/bin/blockcheckw-helper 2>/dev/null || echo 0)
MAINJS_SIZE=$(wc -c < /www/luci-static/resources/view/blockcheckw/main.js 2>/dev/null || echo 0)
if [ "${HELPER_SIZE:-0}" -lt 50000 ] || [ "${MAINJS_SIZE:-0}" -lt 100000 ]; then
    echo -e "${RED}[ERROR] Не удалось скачать helper или main.js с GitHub (получено ${HELPER_SIZE} и ${MAINJS_SIZE} байт).${NC}"
    echo -e "${YELLOW}Установите автономный бандл — в нём все файлы уже внутри:${NC}"
    echo -e "  cd /tmp"
    echo -e "  wget -O bcw.tgz \"https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/main/dist/zapret2wizard-\$(cat /usr/share/blockcheckw/version.json 2>/dev/null | grep -o '[0-9]*\\.[0-9]*\\.[0-9]*' | head -1)-aarch64_cortex-a53-bundle.tar.gz\""
    echo -e "  tar -xzf bcw.tgz && cd zapret2wizard-* && sh install.sh"
    exit 1
fi

# Установка Lua скриптов десинхронизации
for lua_script in zapret-lib.lua zapret-antidpi.lua zapret-auto.lua zapret-obfs.lua zapret-pcap.lua zapret-tests.lua zapret-wgobfs.lua; do
    fetch_file "openwrt/luci-app-blockcheckw/root/usr/share/zapret2wizard/lua/$lua_script" "/usr/share/zapret2wizard/lua/$lua_script" 8 || true
done

# nfqws2 из /opt/zapret2/nfq2 ищет Lua в /opt/zapret2/lua. Раскладка нужна
# сразу после установки: иначе сканер падает на предполётной проверке
# "LUA file '/opt/zapret2/lua/zapret-lib.lua' not accessible".
mkdir -p /opt/zapret2/nfq2 2>/dev/null || true
if [ -L /opt/zapret2/lua ]; then
    ln -sfn /usr/share/zapret2wizard/lua /opt/zapret2/lua 2>/dev/null || true
elif [ -d /opt/zapret2/lua ]; then
    for f in /usr/share/zapret2wizard/lua/*.lua; do
        [ -f "$f" ] && ln -sf "$f" "/opt/zapret2/lua/$(basename "$f")" 2>/dev/null || true
    done
else
    ln -sfn /usr/share/zapret2wizard/lua /opt/zapret2/lua 2>/dev/null || true
fi
chmod 755 /opt /opt/zapret2 /opt/zapret2/nfq2 /usr/share/zapret2wizard /usr/share/zapret2wizard/lua 2>/dev/null || true
chmod 755 /opt/zapret2/lua 2>/dev/null || true
chmod 644 /usr/share/zapret2wizard/lua/*.lua 2>/dev/null || true

# Установка fake-блобов. Существующие файлы не трогаем, общий лимит — 45 секунд:
# если GitHub недоступен, установка продолжается, а не висит.
FAKES_DIR="/usr/share/zapret2wizard/fake"
mkdir -p "$FAKES_DIR"
need_fakes=0
for fb in zero_1024.bin zero_512.bin tls_clienthello_www_google_com.bin; do
    [ -s "$FAKES_DIR/$fb" ] || need_fakes=1
done
if [ "$need_fakes" = "1" ]; then
    echo -e "${BLUE}ℹ${NC} Загрузка fake-блобов (лимит 45 с)..."
    (
        FAKES_LIST="/tmp/bcw_fakes.list"
        if fetch_file "openwrt/fakes.list" "$FAKES_LIST" 6 && [ -s "$FAKES_LIST" ]; then
            while read -r fb; do
                [ -n "$fb" ] || continue
                [ -s "$FAKES_DIR/$fb" ] && continue
                fetch_file "openwrt/luci-app-blockcheckw/root/usr/share/zapret2wizard/fake/$fb" "$FAKES_DIR/$fb" 5 || true
            done < "$FAKES_LIST"
            rm -f "$FAKES_LIST"
        fi
        for fake_blob in stun.bin quic_initial_dbankcloud_ru.bin quic_3.bin quic_4.bin quic_initial_vk_com.bin quic_initial_www_google_com.bin quic_initial_facebook_com.bin tls_clienthello_gosuslugi_ru.bin tls_clienthello_sberbank_ru.bin tls_clienthello_t2_ru.bin tls_clienthello_vk_com.bin tls_clienthello_www_google_com.bin tls_clienthello_www_4pda_to.bin tls_clienthello_max_ru.bin tls_clienthello_iana_org.bin tls_alert.bin discord-ip-discovery-with-port.bin discord-ip-discovery-without-port.bin ACTIVE_GAME_UDP.bin zero_1024.bin zero_512.bin zero_256.bin wireguard_initiation.bin wireguard_response.bin; do
            [ -s "$FAKES_DIR/$fake_blob" ] && continue
            fetch_file "openwrt/luci-app-blockcheckw/root/usr/share/zapret2wizard/fake/$fake_blob" "$FAKES_DIR/$fake_blob" 5 || true
        done
    ) &
    fake_pid=$!
    waited=0
    while kill -0 "$fake_pid" 2>/dev/null && [ "$waited" -lt 45 ]; do
        sleep 3
        waited=$((waited + 3))
        printf '.'
    done
    echo ""
    kill -9 "$fake_pid" 2>/dev/null || true
    echo -e "${GREEN}✓${NC} fake-блобов установлено: $(ls "$FAKES_DIR" 2>/dev/null | wc -l)"
fi

# Установка базовых списков хостов (лимит 40 с, уже существующие не перекачиваем)
echo -e "${BLUE}ℹ${NC} Проверка списков доменов..."
(
    for ipset_file in zapret_hosts_youtube.txt zapret_hosts_discord.txt zapret_hosts_x.txt zapret_hosts_instagram.txt zapret_hosts_twitch.txt zapret_hosts_user.txt zapret_hosts_user_exclude.txt zapret_hosts_auto.txt; do
        [ -s "/usr/share/zapret2wizard/ipset/$ipset_file" ] && continue
        fetch_file "openwrt/luci-app-blockcheckw/root/usr/share/zapret2wizard/ipset/$ipset_file" "/usr/share/zapret2wizard/ipset/$ipset_file" 5 || true
    done
) &
lists_pid=$!
waited=0
while kill -0 "$lists_pid" 2>/dev/null && [ "$waited" -lt 40 ]; do
    sleep 3
    waited=$((waited + 3))
done
kill -9 "$lists_pid" 2>/dev/null || true
for ipset_file in zapret_hosts_youtube.txt zapret_hosts_discord.txt zapret_hosts_x.txt zapret_hosts_instagram.txt zapret_hosts_twitch.txt zapret_hosts_user.txt zapret_hosts_user_exclude.txt zapret_hosts_auto.txt; do
    [ -f "/etc/zapret2wizard/ipset/$ipset_file" ] || cp -f "/usr/share/zapret2wizard/ipset/$ipset_file" "/etc/zapret2wizard/ipset/$ipset_file" 2>/dev/null || true
done

# Установка автономной службы /etc/init.d/zapret2wizard
fetch_req "openwrt/luci-app-blockcheckw/root/etc/init.d/zapret2wizard" /etc/init.d/zapret2wizard 8
chmod +x /etc/init.d/zapret2wizard /usr/share/zapret2wizard/uci2config /usr/bin/blockcheckw-helper /usr/bin/circular-builder.lua 2>/dev/null || true
ln -sf /usr/bin/blockcheckw-helper /usr/bin/zapret2wizard 2>/dev/null || true

# Настройка конфигурации zapret2wizard
if [ ! -f /etc/config/zapret2wizard ]; then
    if [ -f /etc/config/zapret2 ]; then
        echo -e "${BLUE}ℹ${NC} Миграция настроек из zapret2 в автономную конфигурацию zapret2wizard..."
        sed "s/config zapret2 'main'/config zapret2wizard 'main'/g; s|/opt/zapret2/ipset/|/etc/zapret2wizard/ipset/|g" /etc/config/zapret2 > /etc/config/zapret2wizard 2>/dev/null || true
    fi
    [ -s /etc/config/zapret2wizard ] || fetch_req "openwrt/luci-app-blockcheckw/root/etc/config/zapret2wizard" /etc/config/zapret2wizard 8 || true
fi

# 6.5. Проверка целостности: без этих файлов служба молча не поднимется.
# Именно так ломался install.sh: обрыв загрузки init.d при set -e оставлял
# бинарники без /etc/init.d и /etc/config, а скрипт завершался "успешно".
MISSING=""
for f in /usr/bin/blockcheckw-helper \
         /www/luci-static/resources/view/blockcheckw/main.js \
         /usr/share/zapret2wizard/uci2config \
         /etc/init.d/zapret2wizard \
         /etc/config/zapret2wizard; do
    [ -s "$f" ] || MISSING="$MISSING $f"
done
if [ -n "$MISSING" ]; then
    echo -e "${YELLOW}[WARN]${NC} Не хватает файлов:$MISSING"
    echo -e "${BLUE}ℹ${NC} Пробую автономный бандл с GitHub Releases..."
    VER=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([0-9][0-9.]*\)".*/\1/p' /usr/share/blockcheckw/version.json 2>/dev/null | head -n1)
    if [ -n "$VER" ] && [ -n "$PKG_ARCH" ]; then
        BTMP="/tmp/bcw_bundle.$$"
        BURL="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download/v${VER}/zapret2wizard-${VER}-${PKG_ARCH}-bundle.tar.gz"
        rm -rf "$BTMP"; mkdir -p "$BTMP"
        if curl -fsSL -k -m 240 "$BURL" -o "$BTMP/b.tgz" 2>/dev/null && tar -xzf "$BTMP/b.tgz" -C "$BTMP" 2>/dev/null; then
            BSH=$(ls "$BTMP"/*/install.sh 2>/dev/null | head -n1)
            if [ -n "$BSH" ]; then
                ( cd "$(dirname "$BSH")" && SKIP_PREFLIGHT=1 sh install.sh ) || true
            fi
            rm -rf "$BTMP"
            MISSING=""
            for f in /usr/bin/blockcheckw-helper /www/luci-static/resources/view/blockcheckw/main.js /usr/share/zapret2wizard/uci2config /etc/init.d/zapret2wizard /etc/config/zapret2wizard; do
                [ -s "$f" ] || MISSING="$MISSING $f"
            done
        else
            rm -rf "$BTMP"
            echo -e "${YELLOW}[WARN]${NC} Бандл скачать не удалось"
        fi
    fi
fi
if [ -n "$MISSING" ]; then
    echo -e "${RED}[ERROR] Установка неполная — служба не запустится. Не хватает:$MISSING${NC}"
    echo -e "${YELLOW}Поставьте пакет или бандл вручную:${NC} https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/latest"
    exit 1
fi
chmod +x /etc/init.d/zapret2wizard /usr/share/zapret2wizard/uci2config /usr/bin/blockcheckw-helper 2>/dev/null || true

# Без движка и модулей ядра подбор не работает: лучше остановиться с
# понятным сообщением, чем оставить «установлено, но не сканирует».
if [ "${NFQWS2_MISSING:-0}" = "1" ]; then
    echo -e "${RED}[ERROR] Движок nfqws2 не установлен для архитектуры ${ARCH}.${NC}"
    echo -e "${YELLOW}Проверьте /usr/bin/nfqws2 и повторите установку. Для ручной установки:${NC}"
    echo -e "  curl -fsSL -k -o /tmp/nfq "https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/main/openwrt/engine/nfqws2-linux-${ARCH}""
    echo -e "  cp /tmp/nfq /usr/bin/nfqws2 && chmod +x /usr/bin/nfqws2"
    exit 1
fi
# Модули ядра зависят от версии ядра и не входят в наш пакет — доставляем их
# сами из фида прошивки, а не просим пользователя делать это руками.
modprobe nfnetlink_queue 2>/dev/null || true
modprobe nft_queue 2>/dev/null || true
if [ ! -d /sys/module/nfnetlink_queue ] || [ ! -d /sys/module/nft_queue ]; then
    echo -e "${BLUE}ℹ${NC} Доустанавливаю модули ядра nfqueue (kmod-nfnetlink-queue, kmod-nft-queue)..."
    if [ -x /usr/bin/blockcheckw-helper ]; then
        /usr/bin/blockcheckw-helper kmods_install >/dev/null 2>&1 || true
    fi
    modprobe nfnetlink_queue 2>/dev/null || true
    modprobe nft_queue 2>/dev/null || true
    if [ ! -d /sys/module/nfnetlink_queue ] || [ ! -d /sys/module/nft_queue ]; then
        if command -v opkg >/dev/null 2>&1; then
            opkg update >/dev/null 2>&1 || true
            opkg install kmod-nfnetlink-queue kmod-nft-queue >/dev/null 2>&1 || true
        elif command -v apk >/dev/null 2>&1; then
            apk update >/dev/null 2>&1 || true
            apk add kmod-nfnetlink-queue kmod-nft-queue >/dev/null 2>&1 || true
        fi
        modprobe nfnetlink_queue 2>/dev/null || true
        modprobe nft_queue 2>/dev/null || true
    fi
fi
if [ ! -d /sys/module/nfnetlink_queue ] || [ ! -d /sys/module/nft_queue ]; then
    echo -e "${RED}[ERROR] Не загружаются модули nfqueue для ядра $(uname -r).${NC}"
    echo -e "${YELLOW}В фиде прошивки нет подходящих kmod-пакетов. Проверьте:${NC}"
    echo -e "  opkg update && opkg install kmod-nfnetlink-queue kmod-nft-queue"
    echo -e "  (на apk-прошивках: apk add kmod-nfnetlink-queue kmod-nft-queue)"
    exit 1
fi
# nftables нужен и службе, и сканеру.
if ! command -v nft >/dev/null 2>&1; then
    echo -e "${BLUE}ℹ${NC} Устанавливаю nftables..."
    if command -v opkg >/dev/null 2>&1; then
        opkg update >/dev/null 2>&1 || true
        opkg install nftables >/dev/null 2>&1 || true
    elif command -v apk >/dev/null 2>&1; then
        apk add nftables >/dev/null 2>&1 || true
    fi
fi
if ! command -v nft >/dev/null 2>&1; then
    echo -e "${RED}[ERROR] nftables не установлен и не ставится из фида прошивки.${NC}"
    echo -e "${YELLOW}Установите пакет nftables и повторите.${NC}"
    exit 1
fi

# Остановка и отключение старой службы zapret2 (полная изоляция)
if [ -f /etc/init.d/zapret2 ]; then
    echo -e "${BLUE}ℹ${NC} Остановка старой службы zapret2 для предотвращения конфликтов..."
    /etc/init.d/zapret2 stop >/dev/null 2>&1 || true
    /etc/init.d/zapret2 disable >/dev/null 2>&1 || true
    if grep -q "Compatibility wrapper for Zapret2Wizard" /etc/init.d/zapret2 2>/dev/null; then
        if [ -f /opt/zapret2/init.d/openwrt/zapret2 ]; then
            cp -f /opt/zapret2/init.d/openwrt/zapret2 /etc/init.d/zapret2
        fi
    fi
fi

# Включение и запуск единой автономной службы
/usr/bin/blockcheckw-helper kmods_install >/dev/null 2>&1 || true
/etc/init.d/zapret2wizard enable 2>/dev/null || true
( /etc/init.d/zapret2wizard restart >/dev/null 2>&1 </dev/null & )

chmod 644 /www/luci-static/resources/view/blockcheckw/main.js
chmod 644 /usr/share/blockcheckw/* /usr/share/luci/menu.d/luci-app-blockcheckw.json /usr/share/rpcd/acl.d/luci-app-blockcheckw.json 2>/dev/null || true
[ -f /etc/hotplug.d/firewall/90-zapret2wizard-bypass ] && chmod 755 /etc/hotplug.d/firewall/90-zapret2wizard-bypass || true

# Инициализация списков хостов для сервисов в Zapret2
/usr/bin/blockcheckw-helper ensure_hostlists >/dev/null 2>&1 || true

echo -e "${GREEN}✓${NC} Автономная служба Zapret2Wizard успешно настроена и запущена."

# 7. Настройка Firewall: блокировка QUIC (UDP 443)
echo -e "${BLUE}ℹ${NC} Проверка настройки блокировки QUIC (UDP 443)..."
if command -v uci >/dev/null 2>&1 && [ -f /etc/config/firewall ]; then
    if ! uci get firewall.reject_quic >/dev/null 2>&1; then
        echo -e "${YELLOW}ℹ${NC} Добавление правила Reject-QUIC в межсетевой экран..."
        uci set firewall.reject_quic=rule
        uci set firewall.reject_quic.name='Reject-QUIC'
        uci set firewall.reject_quic.src='lan'
        uci set firewall.reject_quic.dest='wan'
        uci set firewall.reject_quic.proto='udp'
        uci set firewall.reject_quic.dest_port='443'
        uci set firewall.reject_quic.target='REJECT'
        uci commit firewall
        /etc/init.d/firewall reload >/dev/null 2>&1 || true
        echo -e "${GREEN}✓${NC} Правило Reject-QUIC успешно добавлено."
    else
        echo -e "${GREEN}✓${NC} Правило Reject-QUIC уже активно."
    fi
fi

# 8. Очистка кэша LuCI и перезапуск служб
echo -e "${BLUE}ℹ${NC} Очистка кэша LuCI и перезапуск служб веб-интерфейса..."
rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache*
/etc/init.d/rpcd restart >/dev/null 2>&1 || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true
/etc/init.d/nginx restart >/dev/null 2>&1 || true
/etc/init.d/lighttpd restart >/dev/null 2>&1 || true
ubus call luci reload >/dev/null 2>&1 || true

# 9. Автозапуск и проверка конфликтов с другими DPI-службами
echo -e "${BLUE}ℹ${NC} Включение автозапуска и проверка конфликтов..."
/etc/init.d/zapret2wizard enable >/dev/null 2>&1 || true
/usr/bin/blockcheckw-helper cron_install >/dev/null 2>&1 || true
( /etc/init.d/zapret2wizard restart >/dev/null 2>&1 </dev/null & )
sleep 2
if [ -x /usr/bin/blockcheckw-helper ]; then
    CONFLICTS=$(/usr/bin/blockcheckw-helper conflicts 2>/dev/null)
    case "$CONFLICTS" in
        *'"ok":true'*)
            echo -e "${GREEN}✓${NC} Конфликтов нет: служба в приоритете, автозапуск включён."
            ;;
        *)
            echo -e "${YELLOW}⚠${NC} Проверка конфликтов: $CONFLICTS"
            ;;
    esac
fi

# Очистка временных файлов
rm -rf "$TMP_DIR"

# Автонастройка: если стратегий нет — подобрать в фоне
STRATS=$(uci show zapret2wizard 2>/dev/null | grep -c '=strategy')
if [ "${STRATS:-0}" -eq 0 ] && [ "${AUTOSETUP:-1}" != "0" ] && [ -x /usr/bin/blockcheckw-helper ]; then
    echo -e "${BLUE}ℹ${NC} Стратегий нет — запускаю автонастройку в фоне (5-20 минут)."
    echo -e "   Прогресс: LuCI -> Службы -> Zapret2Wizard. Лог: /tmp/bcw_autosetup.log"
    (/usr/bin/blockcheckw-helper autosetup >/tmp/bcw_autosetup.log 2>&1 &) || true
fi

# Определение локального IP-адреса роутера
ROUTER_IP=$(uci get network.lan.ipaddr 2>/dev/null || echo "192.168.1.1")

echo -e "\n${GREEN}${BOLD}==============================================================================${NC}"
echo -e "${GREEN}${BOLD}        Zapret2Wizard и LuCI интерфейс успешно установлены!                    ${NC}"
echo -e "${GREEN}${BOLD}==============================================================================${NC}\n"
echo -e "Теперь веб-интерфейс доступен в меню роутера:"
echo -e "  🌐 ${BOLD}Службы${NC} ➔ ${BOLD}Zapret2Wizard (поиск стратегий)${NC}"
echo -e "  🔗 Ссылка: ${CYAN}http://${ROUTER_IP}/cgi-bin/luci/admin/services/blockcheckw${NC}\n"
echo -e "В будущем вы сможете обновлять службу в 1 клик прямо из веб-интерфейса LuCI"
echo -e "с помощью кнопки ${BOLD}[ 🔄 Проверить обновление ]${NC}."
echo ""

if [ "${NFQWS2_MISSING:-0}" = "1" ]; then
    echo -e "${RED}${BOLD}ВНИМАНИЕ:${NC} ${RED}движок nfqws2 не установлен, служба не запустится.${NC}"
    echo -e "Выполните команды из блока [ERROR] выше или запустите установщик повторно —"
    echo -e "он скачает ядро с одного из зеркал. После установки проверьте:"
    echo -e "  ${BOLD}blockcheckw-helper doctor${NC}"
    exit 1
fi
