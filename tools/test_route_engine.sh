#!/bin/sh
# Проверка маршрутного движка без роутера: nft-таблица в отдельном netns,
# steer-заглушка, локальный "dnsmasq". Требует root, nft, unshare.
#
#   sudo unshare -n sh tools/test_route_engine.sh
#
# Проверяет: правило return стоит ДО mark set, IPv4+IPv6 наборы заполнены,
# steer-блок добавляется и снимается, чужая запись в exclude.lst цела.
set -u

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
HELPER="$ROOT/openwrt/luci-app-blockcheckw/root/usr/bin/blockcheckw-helper"
[ -f "$HELPER" ] || { echo "helper not found: $HELPER"; exit 1; }
command -v nft >/dev/null 2>&1 || { echo "skip: nft not found"; exit 0; }

BCW_LIB_ONLY=1
. "$HELPER"

T=$(mktemp -d /tmp/bcw-route-test.XXXXXX)
trap 'rm -rf "$T"' EXIT INT TERM
mkdir -p "$T/user" "$T/bin"

RT_STATE="$T/state"; RT_BACKEND_FILE="$T/backend"; RT_DOMAINS="$T/domains"
RT_IPS4="$T/ips4"; RT_IPS6="$T/ips6"; RT_STATIC4="$T/s4"; RT_STATIC6="$T/s6"
RT_DIR="$T/route"; RT_LOG="$T/log"; RT_VERIFY="$T/verify"
RT_WATCH_PID="$T/pid"; RT_WATCH_RUN="$T/run"; RT_LOCK="$T/lock"
RT_STEER_SPEC="$T/spec.json"; RT_STEER_USER="$T/user"
RT_STEER_EXCL="$T/user/exclude.lst"; RT_STEER_PFX="$T/user/exclude.pfx"
RT_CRON="$T/crontab"; RT_LEGACY_STATE="$T/legacy_state.txt"

cat > "$RT_STEER_SPEC" <<EOF
{"lists":{"zm_excl":{"domains_file":["$T/user/exclude.lst"],"prefixes_file":["$T/user/exclude.pfx"]}},"rules":[{"name":"Исключения","to":"zm_excl","out":"zm_direct"}]}
EOF
printf 'mybank.ru\n' > "$RT_STEER_EXCL"

uci() {
    case "$*" in
        "-q get zapret2wizard.main.route_enabled") echo "${TEST_ROUTE_ENABLED-1}" ;;
        "-q get zapret2wizard.main.route_backend") echo "${TEST_BACKEND:-nft}" ;;
        "-q get zapret2wizard.main.route_services") echo youtube ;;
        "-q get zapret2wizard.main.route_steer_ips") echo 0 ;;
        "-q get zapret2wizard.main.route_extra") echo "" ;;
        "-q get zapret2wizard.main.route_exclude") echo "" ;;
        "show zapret2wizard") echo "zapret2wizard.BlockcheckW_YouTube=strategy" ;;
        "-q get zapret2wizard.BlockcheckW_YouTube.enabled") echo 1 ;;
        "-q get zapret2wizard.BlockcheckW_YouTube.hostlist") echo list_hosts_youtube ;;
        "-q get zapret2wizard.list_hosts_youtube.path") echo /etc/zapret2wizard/ipset/zapret_hosts_youtube.txt ;;
        "-q get zapret2wizard.BlockcheckW_YouTube.hostlist_exclude") echo list_hosts_user_exclude ;;
        "-q get zapret2wizard.list_hosts_user_exclude.path") echo "$T/user_exclude.txt" ;;
        *" set "*) echo "$*" >> "$T/sets" ;;
        *) echo "" ;;
    esac
}

nslookup() {
    case "$*" in *-type=aaaa*) return 0 ;; esac
    printf 'Server:\t\t127.0.0.1\nAddress:\t127.0.0.1:53\nName:\t%s\nAddress 1: 1.2.3.4\nAddress 2: 2a00:1450::1\n' "$1"
}

cat > "$T/bin/steer" <<'EOS'
#!/bin/sh
case "$1" in
    explain) echo '{"out":"zm_direct","why":"exclude"}' ;;
esac
exit 0
EOS
chmod +x "$T/bin/steer"
PATH="$T/bin:$PATH"; export PATH

fail() { echo "FAIL: $*"; exit 1; }

nft add table inet steer || fail "nft table"
nft add set inet steer s4 '{ type ipv4_addr; flags interval; }'
nft add set inet steer s6 '{ type ipv6_addr; flags interval; }'
nft add chain inet steer prerouting_mark '{ type filter hook prerouting priority mangle; policy accept; }'
nft add rule inet steer prerouting_mark iifname "lo" counter
nft add rule inet steer prerouting_mark ip daddr @s4 meta mark set 0x40000000
nft add chain inet steer ingress_mark '{ type filter hook ingress device "lo" priority -150; policy accept; }'
nft add rule inet steer ingress_mark ip daddr @s4 meta mark set 0x40000000

[ "$(route_collect_domains)" -ge 10 ] || fail "domains"
grep -qx youtubei.googleapis.com "$RT_DOMAINS" || fail "youtubei missing"
grep -qx mybank.ru "$RT_DOMAINS" && fail "user exclusion leaked"

[ -n "$(route_nft_targets)" ] || fail "targets"
route_refresh_ips
route_nft_apply
nft -a list chain inet steer prerouting_mark | grep -q 'bcw-route' || fail "rule"
awk '/bcw-route/{r=NR} /mark set/{m=NR} END{exit !(r && m && r<m)}' <<EOF || fail "rule after mark"
$(nft -a list chain inet steer prerouting_mark)
EOF
nft get element inet steer bcw_route4 '{ 1.2.3.4 }' >/dev/null 2>&1 || fail "ipv4 set"
nft get element inet steer bcw_route6 '{ 2a00:1450::1 }' >/dev/null 2>&1 || fail "ipv6 set"

route_disable
[ -z "$(nft list chain inet steer prerouting_mark 2>/dev/null | grep bcw-route)" ] || fail "leftover rule"

TEST_BACKEND=steer
route_enable
grep -qF "$RT_MB" "$RT_STEER_EXCL" || fail "steer block"
grep -qx mybank.ru "$RT_STEER_EXCL" || fail "steer user entry"
grep -qx youtube.com "$RT_STEER_EXCL" || fail "steer youtube"
grep -qx google.com "$RT_STEER_EXCL" && fail "google.com leaked"
route_verify | grep -q '"ok":true' || fail "verify"

# переключение steer -> nft -> steer
TEST_BACKEND=nft
route_enable
grep -qF "$RT_MB" "$RT_STEER_EXCL" && fail "steer block left on nft"
nft list chain inet steer prerouting_mark 2>/dev/null | grep -q bcw-route || fail "nft rules after switch"
TEST_BACKEND=steer
route_enable
grep -qF "$RT_MB" "$RT_STEER_EXCL" || fail "steer block after switch back"
[ -z "$(nft list chain inet steer prerouting_mark 2>/dev/null | grep bcw-route)" ] || fail "nft rules left on steer"

route_disable
grep -qF "$RT_MB" "$RT_STEER_EXCL" && fail "steer block not removed"
grep -qx mybank.ru "$RT_STEER_EXCL" || fail "steer user entry removed"

# --- гейт включения: маршрут не включается сам, только явной командой ---
TEST_ROUTE_ENABLED=0
: > "$T/sets"
case "$(cmd_bypass sync)" in
    *'"bypass":"disabled"'*) ;;
    *) fail "sync applied while route_enabled is off" ;;
esac
grep -qF "$RT_MB" "$RT_STEER_EXCL" && fail "sync applied block while off"

case "$(cmd_bypass enable)" in
    *'"bypass":"active"'*) ;;
    *) fail "enable did not report active" ;;
esac
grep -q 'main.route_enabled=1' "$T/sets" || fail "enable must persist route_enabled=1"
grep -qF "$RT_MB" "$RT_STEER_EXCL" || fail "enable must apply block"
TEST_ROUTE_ENABLED=1

# временная остановка службы снимает правила, но не выключает маршрут
: > "$T/sets"
cmd_bypass disable keep >/dev/null
grep -q 'route_enabled=0' "$T/sets" && fail "keep must not disable the UCI switch"
grep -qF "$RT_MB" "$RT_STEER_EXCL" && fail "keep must remove the block"

# --- миграция с 0.18.x: переключателя не было, блок в exclude.lst стоит ---
TEST_ROUTE_ENABLED=
: > "$T/sets"
printf '%s\nyoutube.com\n%s\n' "$RT_MB" "$RT_ME" > "$RT_STEER_EXCL"
cmd_bypass sync >/dev/null 2>&1
grep -q 'main.route_enabled=1' "$T/sets" \
    || fail "legacy install must keep the route enabled"

# --- миграция по старой cron-строке (её ставил 0.18.x, prerm её не удаляет) ---
TEST_ROUTE_ENABLED=
: > "$T/sets"
printf '%s\n' "$RT_MB" "$RT_ME" > "$RT_STEER_EXCL"   # блок уже снят disable'ом
printf '*/2 * * * * /usr/bin/blockcheckw-helper bypass_sync enable >/dev/null 2>&1 # bcw-bypass\n' > "$RT_CRON"
cmd_bypass sync >/dev/null 2>&1
grep -q 'main.route_enabled=1' "$T/sets" \
    || fail "old cron line must trigger the migration"
grep -q 'bypass_sync enable' "$RT_CRON" && fail "old cron line must be rewritten"
grep -q 'bypass_sync sync' "$RT_CRON" || fail "cron line must become sync"

# без нашего сигнала миграция не срабатывает: чистый crontab не трогаем
TEST_ROUTE_ENABLED=
: > "$T/sets"
: > "$RT_STEER_EXCL"
rm -f "$RT_LEGACY_STATE"
printf '0 3 * * * /usr/bin/keepalive\n' > "$RT_CRON"
cmd_bypass sync >/dev/null 2>&1
grep -q 'main.route_enabled=1' "$T/sets" && fail "migration must not fire without a signal"
grep -q 'keepalive' "$RT_CRON" || fail "foreign cron line must survive"

echo "OK: route engine"
