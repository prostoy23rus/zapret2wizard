#!/bin/sh
# Проверка маршрутного движка без роутера: nft-таблица в отдельном netns,
# заглушка службы маршрутизации с родным списком исключений и локальный
# «dnsmasq». Требует root, nft, unshare.
#
#   sudo unshare -n sh tools/test_route_engine.sh
#
# Проверяет: правило return стоит ДО mark set, IPv4+IPv6 наборы заполнены,
# списковые исключения применяются и снимаются, чужая запись в списке цела,
# гейт включения и миграция со старой установки.
set -u

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
HELPER="$ROOT/openwrt/luci-app-blockcheckw/root/usr/bin/blockcheckw-helper"
[ -f "$HELPER" ] || { echo "helper not found: $HELPER"; exit 1; }
command -v nft >/dev/null 2>&1 || { echo "skip: nft not found"; exit 0; }

BCW_LIB_ONLY=1
. "$HELPER"

T=$(mktemp -d /tmp/bcw-route-test.XXXXXX)
trap 'rm -rf "$T"' EXIT INT TERM
mkdir -p "$T/user" "$T/bin" "$T/svc"

RT_STATE="$T/state"; RT_BACKEND_FILE="$T/backend"; RT_DOMAINS="$T/domains"
RT_IPS4="$T/ips4"; RT_IPS6="$T/ips6"; RT_STATIC4="$T/s4"; RT_STATIC6="$T/s6"
RT_DIR="$T/route"; RT_LOG="$T/log"; RT_VERIFY="$T/verify"
RT_WATCH_PID="$T/pid"; RT_WATCH_RUN="$T/run"; RT_LOCK="$T/lock"
RT_CRON="$T/crontab"; RT_LEGACY_STATE="$T/legacy_state.txt"
RT_SPEC_DIR="$T/etc"

# Служба маршрутизации: спека описывает свои списки доменов и префиксов —
# ровно так это делают оркестраторы, имя службы нигде не зашито.
# В спеке несколько списков: наш должен выбрать именно список исключений,
# а не первый попавшийся (у службы там свои сервисные домены).
cat > "$T/svc/spec.json" <<EOF
{"version":2,"lists":{"svc_other":{"domains_file":["/opt/svc/lists/svc_other.lst"]},"direct":{"domains_file":["$T/svc/exclude.lst"],"prefixes_file":["$T/svc/exclude.pfx"]}},"rules":[{"name":"Исключения","to":"direct","out":"direct"}]}
EOF
printf 'mybank.ru\n' > "$T/svc/exclude.lst"
: > "$T/svc/exclude.pfx"

cat > "$T/bin/svc" <<'EOS'
#!/bin/sh
case "$1" in
    reload) exit 0 ;;
    explain) echo '{"out":"direct"}'; exit 0 ;;
esac
exit 0
EOS
chmod +x "$T/bin/svc"
PATH="$T/bin:$PATH"; export PATH

EXCL="$T/svc/exclude.lst"

uci() {
    case "$*" in
        "-q get zapret2wizard.main.route_enabled") echo "${TEST_ROUTE_ENABLED-1}" ;;
        "-q get zapret2wizard.main.route_backend") echo "${TEST_BACKEND:-nft}" ;;
        "-q get zapret2wizard.main.route_services") echo youtube ;;
        "-q get zapret2wizard.main.route_list_spec") echo "${TEST_LIST_SPEC-$T/svc/spec.json}" ;;
        "-q get zapret2wizard.main.route_list_file") echo "${TEST_LIST_FILE:-}" ;;
        "-q get zapret2wizard.main.route_list_pfx") echo "" ;;
        "-q get zapret2wizard.main.route_list_reload") echo "" ;;
        "-q get zapret2wizard.main.route_list_verify") echo "${TEST_VERIFY:-svc explain {}}" ;;
        "-q get zapret2wizard.main.route_list_ips") echo 0 ;;
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

fail() { echo "FAIL: $*"; exit 1; }

nft add table inet tnl || fail "nft table"
nft add set inet tnl s4 '{ type ipv4_addr; flags interval; }'
nft add set inet tnl s6 '{ type ipv6_addr; flags interval; }'
nft add chain inet tnl prerouting_mark '{ type filter hook prerouting priority mangle; policy accept; }'
nft add rule inet tnl prerouting_mark iifname "lo" counter
nft add rule inet tnl prerouting_mark ip daddr @s4 meta mark set 0x40000000
nft add chain inet tnl ingress_mark '{ type filter hook ingress device "lo" priority -150; policy accept; }'
nft add rule inet tnl ingress_mark ip daddr @s4 meta mark set 0x40000000

# --- nft-исполнение ---
[ "$(route_collect_domains)" -ge 10 ] || fail "domains"
grep -qx youtubei.googleapis.com "$RT_DOMAINS" || fail "youtubei missing"
grep -qx mybank.ru "$RT_DOMAINS" && fail "user exclusion leaked"

[ -n "$(route_nft_targets)" ] || fail "targets"
route_refresh_ips
route_nft_apply
nft -a list chain inet tnl prerouting_mark | grep -q 'bcw-route' || fail "rule"
awk '/bcw-route/{r=NR} /mark set/{m=NR} END{exit !(r && m && r<m)}' <<EOF || fail "rule after mark"
$(nft -a list chain inet tnl prerouting_mark)
EOF
nft get element inet tnl bcw_route4 '{ 1.2.3.4 }' >/dev/null 2>&1 || fail "ipv4 set"
nft get element inet tnl bcw_route6 '{ 2a00:1450::1 }' >/dev/null 2>&1 || fail "ipv6 set"

route_disable
[ -z "$(nft list chain inet tnl prerouting_mark 2>/dev/null | grep bcw-route)" ] || fail "leftover rule"

# --- списковое исполнение: выбран именно список исключений ---
TEST_BACKEND=list
route_enable
grep -qF "$RT_MB" "$EXCL" || fail "list block"
grep -qx mybank.ru "$EXCL" || fail "list user entry"
grep -qx youtube.com "$EXCL" || fail "list youtube"
grep -qx google.com "$EXCL" && fail "google.com leaked"
[ "$(cat "$RT_BACKEND_FILE")" = "list" ] || fail "backend file"
route_status | grep -q "\"list\":\"$EXCL\"" || fail "status must report the list file"
route_verify | grep -q '"ok":true' || fail "verify"
route_explain youtube.com | grep -q 'direct' || fail "explain"

# переключение list -> nft -> list
TEST_BACKEND=nft
route_enable
grep -qF "$RT_MB" "$EXCL" && fail "list block left on nft"
nft list chain inet tnl prerouting_mark 2>/dev/null | grep -q bcw-route || fail "nft rules after switch"
TEST_BACKEND=list
route_enable
grep -qF "$RT_MB" "$EXCL" || fail "list block after switch back"
[ -z "$(nft list chain inet tnl prerouting_mark 2>/dev/null | grep bcw-route)" ] || fail "nft rules left on list"

route_disable
grep -qF "$RT_MB" "$EXCL" && fail "list block not removed"
grep -qx mybank.ru "$EXCL" || fail "list user entry removed"

# --- несколько оркестраторов: берём спеку со списком исключений, а не первую ---
mkdir -p "$T/etc/svcA" "$T/etc/svc"
printf '{"version":2,"lists":{"x":{"domains_file":["/opt/a/service_only.lst"]}}}\n'     > "$T/etc/svcA/spec.json"
cat > "$T/etc/svc/spec.json" <<EOF
{"version":2,"lists":{"svc_other":{"domains_file":["/opt/svc/lists/svc_other.lst"]},"direct":{"domains_file":["$T/etc/svc/exclude.lst"],"prefixes_file":["$T/etc/svc/exclude.pfx"]}}}
EOF
: > "$T/etc/svc/exclude.lst"
: > "$T/etc/svc/exclude.pfx"
TEST_LIST_SPEC=""
RT_SPEC_DIR="$T/etc"
[ "$(route_list_excl_path)" = "$T/etc/svc/exclude.lst" ] \
    || fail "wrong list picked: $(route_list_excl_path)"
[ "$(route_list_spec)" = "$T/etc/svc/spec.json" ] || fail "wrong spec picked"
[ "$(route_list_pfx_path)" = "$T/etc/svc/exclude.pfx" ] || fail "wrong pfx picked"
TEST_LIST_SPEC="$T/svc/spec.json"
RT_SPEC_DIR="/etc"

# --- спека без списка исключений: пишем правила nft, а не чужой список ---
cat > "$T/svc/spec2.json" <<EOF
{"version":2,"lists":{"svc_other":{"domains_file":["/opt/svc/lists/svc_other.lst"]}}}
EOF
TEST_LIST_SPEC="$T/svc/spec2.json"
TEST_BACKEND=auto
route_disable >/dev/null 2>&1
[ -z "$(route_list_excl_path)" ] || fail "non-exclusion list must not be chosen"
route_enable
[ "$(cat "$RT_BACKEND_FILE")" = "nft" ] || fail "auto must fall back to nft"
TEST_LIST_SPEC="$T/svc/spec.json"
TEST_BACKEND=list
route_disable >/dev/null 2>&1

# --- своя служба без спеки: путь из UCI ---
TEST_LIST_FILE="$T/user/custom.lst"
TEST_LIST_SPEC=""
TEST_BACKEND=list
: > "$T/user/custom.lst"
route_enable
grep -qx youtube.com "$T/user/custom.lst" || fail "custom list file not used"
route_disable
TEST_LIST_FILE=""
TEST_LIST_SPEC="$T/svc/spec.json"
TEST_BACKEND=nft

# --- гейт включения: маршрут не включается сам, только явной командой ---
TEST_BACKEND=list
TEST_ROUTE_ENABLED=0
: > "$T/sets"
case "$(cmd_bypass sync)" in
    *'"bypass":"disabled"'*) ;;
    *) fail "sync applied while route_enabled is off" ;;
esac
grep -qF "$RT_MB" "$EXCL" && fail "sync applied block while off"

case "$(cmd_bypass enable)" in
    *'"bypass":"active"'*) ;;
    *) fail "enable did not report active" ;;
esac
grep -q 'main.route_enabled=1' "$T/sets" || fail "enable must persist route_enabled=1"
grep -qF "$RT_MB" "$EXCL" || fail "enable must apply block"
TEST_ROUTE_ENABLED=1

# временная остановка службы снимает правила, но не выключает маршрут
: > "$T/sets"
cmd_bypass disable keep >/dev/null
grep -q 'route_enabled=0' "$T/sets" && fail "keep must not disable the UCI switch"
grep -qF "$RT_MB" "$EXCL" && fail "keep must remove the block"

# --- миграция с прежней версии: переключателя не было, блок уже стоит ---
TEST_ROUTE_ENABLED=
: > "$T/sets"
printf '%s\nyoutube.com\n%s\n' "$RT_MB" "$RT_ME" > "$EXCL"
cmd_bypass sync >/dev/null 2>&1
grep -q 'main.route_enabled=1' "$T/sets" || fail "legacy install must keep the route enabled"

# --- миграция по старой cron-строке (её ставила прежняя версия) ---
TEST_ROUTE_ENABLED=
: > "$T/sets"
printf '%s\n' "$RT_MB" "$RT_ME" > "$EXCL"   # блок уже снят disable'ом
printf '*/2 * * * * /usr/bin/blockcheckw-helper bypass_sync enable >/dev/null 2>&1 # bcw-bypass\n' > "$RT_CRON"
cmd_bypass sync >/dev/null 2>&1
grep -q 'main.route_enabled=1' "$T/sets" || fail "old cron line must trigger the migration"
grep -q 'bypass_sync enable' "$RT_CRON" && fail "old cron line must be rewritten"
grep -q 'bypass_sync sync' "$RT_CRON" || fail "cron line must become sync"

# без нашего сигнала миграция не срабатывает: чистый crontab не трогаем
TEST_ROUTE_ENABLED=
: > "$T/sets"
: > "$EXCL"
rm -f "$RT_LEGACY_STATE"
printf '0 3 * * * /usr/bin/keepalive\n' > "$RT_CRON"
cmd_bypass sync >/dev/null 2>&1
grep -q 'main.route_enabled=1' "$T/sets" && fail "migration must not fire without a signal"
grep -q 'keepalive' "$RT_CRON" || fail "foreign cron line must survive"

echo "OK: route engine"
