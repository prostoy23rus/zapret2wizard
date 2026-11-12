#!/bin/sh
# Удаляет следы Zapret2Wizard, если служба уже удалена:
# DNS-переадресации на 127.0.0.1#5053/#5055 и Reject-QUIC.
# Запуск: sh cleanup-leftovers.sh

changed=0
if uci -q get dhcp.@dnsmasq[0] >/dev/null 2>&1; then
    for s in $(uci -q get dhcp.@dnsmasq[0].server 2>/dev/null); do
        case "$s" in
            /googlevideo.com/*|/ytimg.com/*|/ggpht.com/*|/instagram.com/*|/cdninstagram.com/*|/discord.com/*|/twitch.tv/*|/x.com/*)
                case "$s" in
                    *127.0.0.1#5053*|*127.0.0.1#5055*|*77.88.8.8#1253*|*208.67.222.222#5353*)
                        uci -q del_list dhcp.@dnsmasq[0].server="$s" && changed=1
                        ;;
                esac
                ;;
        esac
    done
    for s in $(uci -q get dhcp.@dnsmasq[0].address 2>/dev/null); do
        case "$s" in
            /instagram.com/*|/cdninstagram.com/*|/www.instagram.com/*)
                uci -q del_list dhcp.@dnsmasq[0].address="$s" && changed=1
                ;;
        esac
    done
    if [ "$changed" = "1" ]; then
        uci commit dhcp
        /etc/init.d/dnsmasq restart
    fi
fi
if uci -q get firewall.reject_quic >/dev/null 2>&1; then
    uci -q delete firewall.reject_quic
    uci commit firewall
    /etc/init.d/firewall reload
fi
nft delete table inet zapret2wizard 2>/dev/null
echo "Готово: DNS-записи и Reject-QUIC удалены."
