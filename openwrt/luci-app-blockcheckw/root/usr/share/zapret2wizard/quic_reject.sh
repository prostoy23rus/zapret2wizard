#!/bin/sh
# Ранний Reject-QUIC: отдельная nft-таблица с hook forward priority -10.
# Штатное правило fw4 стоит после "ct state established accept", поэтому
# уже установленные UDP/443-потоки его обходят. Эта таблица режет QUIC
# до проверки established, и плееры быстро падают на TCP.
#
# Usage: quic_reject.sh {apply|remove|status}

TABLE="bcw_quic"
INCLUDE="/etc/bcw_quic_reject.sh"

apply_quic() {
    nft delete table inet "$TABLE" 2>/dev/null || true
    nft add table inet "$TABLE" 2>/dev/null || return 1
    nft add chain inet "$TABLE" forward '{ type filter hook forward priority -10; policy accept; }' 2>/dev/null || return 1
    nft add rule inet "$TABLE" forward udp dport 443 counter reject 2>/dev/null || return 1

    cat > "$INCLUDE" <<'EOS'
#!/bin/sh
nft delete table inet bcw_quic 2>/dev/null
nft add table inet bcw_quic
nft add chain inet bcw_quic forward '{ type filter hook forward priority -10; policy accept; }'
nft add rule inet bcw_quic forward udp dport 443 counter reject
EOS
    chmod 755 "$INCLUDE" 2>/dev/null || true

    if command -v uci >/dev/null 2>&1; then
        uci -q set firewall.bcw_quic=include
        uci -q set firewall.bcw_quic.type=script
        uci -q set firewall.bcw_quic.path="$INCLUDE"
        uci -q set firewall.bcw_quic.fw4_compatible=1
        uci -q commit firewall 2>/dev/null || true
    fi
    return 0
}

remove_quic() {
    nft delete table inet "$TABLE" 2>/dev/null || true
    rm -f "$INCLUDE" 2>/dev/null || true
    if command -v uci >/dev/null 2>&1; then
        uci -q delete firewall.bcw_quic 2>/dev/null || true
        uci -q commit firewall 2>/dev/null || true
    fi
    return 0
}

case "$1" in
    apply) apply_quic ;;
    remove) remove_quic ;;
    status)
        nft list table inet "$TABLE" 2>/dev/null | grep -q "udp dport 443" && echo applied || echo absent
        ;;
    *) echo "usage: $0 {apply|remove|status}" >&2; exit 2 ;;
esac
