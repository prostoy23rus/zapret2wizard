#!/bin/sh
# Source a path-rebased init under a temp root. Never execute real nft, UCI,
# helper, engine, service hooks, or write host /etc. Run with sh and busybox ash.
set -eu
REPO=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'command rm -rf "$TMP"' EXIT HUP INT TERM
ROOT="$TMP/root"
LOG="$TMP/calls"
export ROOT LOG
mkdir -p "$ROOT/usr/bin" "$ROOT/usr/share/zapret2wizard/fake" "$ROOT/etc/zapret2wizard" "$ROOT/etc/config" "$ROOT/etc/init.d" "$ROOT/opt/zapret2" "$ROOT/var/run" "$ROOT/tmp"
# Rebase absolute paths in one pass; repeated replacements could prefix /tmp
# inside the inserted sandbox prefix a second time.
awk -v prefix="$ROOT" '{gsub(/\/(etc|usr|opt|tmp|var|proc|lib|sbin)\//, prefix "&"); print}' \
    "$REPO/openwrt/luci-app-blockcheckw/root/etc/init.d/zapret2wizard" > "$TMP/init"
cat > "$TMP/forbidden" <<'HOOK'
#!/bin/sh
printf 'FORBIDDEN hook %s %s\n' "$0" "$*" >> "$LOG"
exit 99
HOOK
for f in "$ROOT/usr/bin/blockcheckw-helper" "$ROOT/usr/share/zapret2wizard/uci2config" "$ROOT/usr/share/zapret2wizard/quic_reject.sh" "$ROOT/etc/init.d/firewall"; do
    cp "$TMP/forbidden" "$f"
    chmod 755 "$f"
done
# Presence checks must pass, but this engine must never actually be executed.
cp "$TMP/forbidden" "$ROOT/usr/bin/nfqws2"
chmod 755 "$ROOT/usr/bin/nfqws2"
echo blob > "$ROOT/usr/share/zapret2wizard/fake/quic_initial_dbankcloud_ru.bin"
printf "NFQWS2_OPT='--filter-tcp=443 --lua-desync=original:marker=keep'\nQNUM=300\n" > "$ROOT/etc/zapret2wizard/config"
printf 'unchanged strategy UCI\n' > "$ROOT/etc/config/zapret2wizard"
printf 'unchanged DNS\n' > "$ROOT/etc/config/dhcp"
printf 'unchanged firewall QUIC policy\n' > "$ROOT/etc/config/firewall"
printf 'unchanged network\n' > "$ROOT/etc/config/network"
printf 'unchanged hostlist\n' > "$ROOT/etc/zapret2wizard/hosts.txt"
printf 'unchanged firewall snapshot\n' > "$ROOT/etc/zapret2wizard/fw.nft"
# Snapshot every persistent fixture before shell functions are mocked.
for f in "$ROOT/etc/config/"* "$ROOT/etc/zapret2wizard/"*; do cksum "$f"; done > "$TMP/before"
extra_command() { :; }
. "$TMP/init"
BCW_ENGINE_ONLY=1
BCW_INTERNAL_STOP=0
forbidden() { printf 'FORBIDDEN %s\n' "$*" >> "$LOG"; return 99; }
logger() { :; }
modprobe() { printf 'modprobe %s\n' "$*" >> "$LOG"; }
uci() {
    case "$*" in
        '-q get zapret2wizard.main.enabled'|'-q get zapret2wizard.main.canary') echo 1 ;;
        '-q get zapret2wizard.main.canary_interval') echo 300 ;;
        '-q get firewall.@defaults[0].flow_offloading') echo 0 ;;
        *) forbidden "uci $*" ;;
    esac
}
detect_interfaces() { WAN_IFACE=mockwan; LAN_IFACE=mocklan; WAN6_IFACE=''; }
nft() {
    printf 'nft %s\n' "$*" >> "$LOG"
    case "$*" in
        '-f -') while IFS= read -r line; do :; done ;;
        'delete table inet zapret2wizard'|'list table inet zapret2wizard') ;;
        *) forbidden "nft $*" ;;
    esac
}
disable_flow_offloading() { forbidden flow_offloading; }
guard_conflicts() { forbidden guard_conflicts; }
kill_orphan_scans() { forbidden kill_orphan_scans; }
chmod() { forbidden "chmod $*"; }
mkdir() { forbidden "mkdir $*"; }
cp() { forbidden "cp $*"; }
mv() { forbidden "mv $*"; }
ln() { forbidden "ln $*"; }
kill() { forbidden "kill $*"; }
sleep() { forbidden "sleep $*"; }
sh() { forbidden "sh $*"; }
rm() {
    case "$*" in
        "-f $PIDDIR/zapret2wizard_"*) printf 'runtime-pid-cleanup\n' >> "$LOG" ;;
        *) forbidden "rm $*" ;;
    esac
}
procd_open_instance() { printf 'instance %s\n' "$*" >> "$LOG"; }
procd_set_param() { printf 'procd-set %s\n' "$*" >> "$LOG"; }
procd_append_param() { printf 'procd-append %s\n' "$*" >> "$LOG"; }
procd_close_instance() { :; }
fail() { echo "FAIL: $*" >&2; command cat "$LOG" >&2; exit 1; }
: > "$LOG"
prepare_environment || fail prepare
[ ! -s "$LOG" ] || fail 'prepare called mutators'
echo 'ok 1 - engine-only prepare reuses generated config without side effects'
start_service || fail start
for instance in main discord_media stun; do
    grep -q "^instance $instance$" "$LOG" || fail "missing $instance process registration"
done
grep -q '^procd-append command --lua-desync=original:marker=keep$' "$LOG" || fail 'existing strategy not passed to engine'
grep -q '^nft -f -$' "$LOG" || fail 'owned runtime firewall not restored'
! grep -q FORBIDDEN "$LOG" || fail 'start called forbidden mutation'
echo 'ok 2 - engine-only start restores owned firewall and engines with original strategy'
stop_service || fail stop
! grep -q FORBIDDEN "$LOG" || fail 'stop called DNS/QUIC/service mutation'
grep -q '^runtime-pid-cleanup$' "$LOG" || fail 'runtime PID cleanup missing'
echo 'ok 3 - engine-only stop preserves QUIC policy even without INTERNAL_STOP'
for f in "$ROOT/etc/config/"* "$ROOT/etc/zapret2wizard/"*; do cksum "$f"; done > "$TMP/after"
cmp "$TMP/before" "$TMP/after" || fail 'persistent config changed'
echo 'ok 4 - strategy DNS firewall network hostlist and snapshot fixtures unchanged'
# A missing generated configuration must fail instead of invoking migrations.
command rm "$CONFIG_FILE"
: > "$LOG"
if prepare_environment; then fail 'missing config accepted'; fi
[ ! -s "$LOG" ] || fail 'missing config triggered mutations'
echo 'ok 5 - missing generated config fails closed without generator or migration'
printf 'PASS: 5 engine-only init checks\n'
