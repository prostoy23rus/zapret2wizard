#!/bin/sh
# ==============================================================================
# Zapret2Wizard & LuCI Universal Uninstaller for OpenWrt
# Repository: https://github.com/prostoy23rus/zapret2wizard
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

AUTO_YES=0
REMOVE_QUIC=0
PURGE_ZAPRET=0

for arg in "$@"; do
    case "$arg" in
        -y|--yes) AUTO_YES=1 ;;
        --remove-quic) REMOVE_QUIC=1 ;;
        --purge-zapret) PURGE_ZAPRET=1 ;;
    esac
done

echo -e "${RED}${BOLD}"
echo "  _____                  _   ___  __          ___                  _ "
echo " |__  / __ _ _ __  _ __ ___| |_|__ \ \ \        / (_)______ _ _ __ __| |"
echo "   / / / _\` | '_ \| '__/ _ \ __| / /  \ \  /\  / /| |_  / _\` | '__/ _\` |"
echo "  / /_| (_| | |_) | | |  __/ |_ / /_   \ \/  \/ / | |/ / (_| | | | (_| |"
echo " /____|\__,_| .__/|_|  \___|\__|____|   \__/\__/  |_/___\__,_|_|  \__,_|"
echo "            |_|                                                         "
echo -e "${NC}"
echo -e "${BOLD}Деинсталлятор службы Zapret2Wizard и LuCI интерфейса${NC}"
echo -e "Репозиторий: ${BLUE}https://github.com/prostoy23rus/zapret2wizard${NC}\n"

# 1. Проверка root прав
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}[ERROR] Скрипт удаления должен быть запущен от имени root!${NC}"
    exit 1
fi

# 2. Запрос подтверждения
if [ "$AUTO_YES" -eq 0 ]; then
    echo -e "${YELLOW}Будут полностью удалены:${NC}"
    echo -e "  • Бинарный исполняемый файл сканера (/usr/bin/blockcheckw)"
    echo -e "  • Скрипты помощника (/usr/bin/blockcheckw-helper, /usr/bin/circular-builder.lua)"
    echo -e "  • Веб-интерфейс LuCI (/www/luci-static/resources/view/blockcheckw)"
    echo -e "  • Меню и ACL права (/usr/share/luci/menu.d, /usr/share/rpcd/acl.d)"
    echo -e "  • Файлы пресетов и данных (/usr/share/blockcheckw)"
    echo -e "  • Временные файлы и кэш LuCI"
    echo ""
    echo -e "${GREEN}✓ Конфигурация Zapret2 (/etc/config/zapret2) будет сохранена,${NC}"
    echo -e "  чтобы ваши настроенные стратегии десинка продолжали работать."
    echo ""
    printf "Вы действительно хотите удалить Zapret2Wizard? [y/N]: "
    read -r CONFIRM
    case "$CONFIRM" in
        y|Y|yes|YES) ;;
        *)
            echo -e "\n${BLUE}Удаление отменено пользователем.${NC}"
            exit 0
            ;;
    esac
fi

echo -e "\n${BLUE}ℹ${NC} Остановка активных процессов..."
if [ -x /etc/init.d/zapret2wizard ]; then
    /etc/init.d/zapret2wizard stop >/dev/null 2>&1 || true
    /etc/init.d/zapret2wizard disable >/dev/null 2>&1 || true
fi
killall -9 blockcheckw 2>/dev/null || true
killall -9 blockcheckw-helper 2>/dev/null || true

echo -e "${BLUE}ℹ${NC} Удаление исполняемых файлов и библиотек..."
rm -f /usr/bin/blockcheckw
rm -f /usr/bin/blockcheckw-helper
rm -f /usr/bin/zapret2wizard
rm -f /usr/bin/circular-builder.lua
rm -rf /usr/share/blockcheckw
rm -rf /usr/share/zapret2wizard
rm -f /etc/init.d/zapret2wizard
if [ -f /etc/init.d/zapret2 ] && grep -q "zapret2wizard" /etc/init.d/zapret2 2>/dev/null; then
    rm -f /etc/init.d/zapret2
fi

echo -e "${BLUE}ℹ${NC} Удаление модулей интерфейса LuCI..."
rm -f /usr/share/luci/menu.d/luci-app-blockcheckw.json
rm -f /usr/share/rpcd/acl.d/luci-app-blockcheckw.json
rm -rf /www/luci-static/resources/view/blockcheckw

echo -e "${BLUE}ℹ${NC} Очистка временных файлов и логов..."
rm -f /tmp/blockcheckw_*
rm -f /etc/blockcheckw_watchdog.json /var/log/blockcheckw_watchdog.log
sed -i '/watchdog/d' /etc/crontabs/root 2>/dev/null || true
rm -f /var/run/blockcheckw.pid

# Опциональное удаление правила Reject-QUIC
if [ "$REMOVE_QUIC" -eq 1 ]; then
    echo -e "${BLUE}ℹ${NC} Удаление правила Reject-QUIC из firewall..."
    if command -v uci >/dev/null 2>&1 && [ -f /etc/config/firewall ]; then
        uci delete firewall.reject_quic 2>/dev/null || true
        uci commit firewall 2>/dev/null || true
        /etc/init.d/firewall reload >/dev/null 2>&1 || true
        echo -e "${GREEN}✓${NC} Правило Reject-QUIC удалено."
    fi
fi

# Опциональная очистка секций zapret2, созданных blockcheckw
if [ "$PURGE_ZAPRET" -eq 1 ]; then
    echo -e "${YELLOW}ℹ${NC} Очистка записей и компонентов Zapret2..."
    rm -rf /etc/zapret2wizard
    rm -f /etc/config/zapret2wizard
    rm -f /usr/bin/nfqws2
    nft delete table inet zapret2 2>/dev/null || true
    killall -9 nfqws2 2>/dev/null || true
    if command -v uci >/dev/null 2>&1 && [ -f /etc/config/zapret2 ]; then
        for sec in $(uci show zapret2 | grep -E "=section" | cut -d'.' -f2 | cut -d'=' -f1); do
            case "$sec" in
                *Tube*|*Discord*|*Twitch*|*Twitter*|*Instagram*|*BlockcheckW*|*Custom*|*Test*)
                    uci delete zapret2."$sec" 2>/dev/null || true
                    ;;
            esac
        done
        uci commit zapret2 2>/dev/null || true
    fi
fi

echo -e "${BLUE}ℹ${NC} Очистка кэша LuCI и перезапуск служб веб-интерфейса..."
rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache*
/etc/init.d/rpcd restart >/dev/null 2>&1 || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true
/etc/init.d/nginx restart >/dev/null 2>&1 || true
/etc/init.d/lighttpd restart >/dev/null 2>&1 || true
ubus call luci reload >/dev/null 2>&1 || true

echo -e "\n${GREEN}${BOLD}==============================================================================${NC}"
echo -e "${GREEN}${BOLD}       Zapret2Wizard и интерфейс LuCI успешно удалены с роутера!                ${NC}"
echo -e "${GREEN}${BOLD}==============================================================================${NC}\n"
