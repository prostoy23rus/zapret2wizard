#!/bin/sh
# Safe temp-root regressions: no network, services or router mutations.
set -eu
REPO=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
MODULE="$REPO/openwrt/luci-app-blockcheckw/root/usr/share/zapret2wizard/engine.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
. "$MODULE"
N=0
ok() { N=$((N + 1)); printf 'ok %s - %s\n' "$N" "$1"; }
fail() { echo "FAIL: $* ($BCW_ENGINE_ERROR)" >&2; exit 1; }
expect_fail() { if "$@"; then fail "unexpected success: $*"; fi; [ -n "$BCW_ENGINE_ERROR" ] || fail 'empty error'; }
reset() {
    BCW_ENGINE_ROOT="$TMP/root-$N"
    BCW_ENGINE_ARCH=x86_64
    BCW_ENGINE_TIMEOUT=1
    BCW_ENGINE_FETCH_TIMEOUT=1
    unset BCW_ENGINE_LUA_DIR
    mkdir -p "$BCW_ENGINE_ROOT/usr/bin" "$BCW_ENGINE_ROOT/opt/zapret2/nfq2" "$BCW_ENGINE_ROOT/usr/share/zapret2wizard/lua"
    CANON="$BCW_ENGINE_ROOT/usr/bin/nfqws2"
    LEGACY="$BCW_ENGINE_ROOT/opt/zapret2/nfq2/nfqws2"
    LUA="$BCW_ENGINE_ROOT/usr/share/zapret2wizard/lua"
    for f in zapret-lib.lua zapret-antidpi.lua zapret-auto.lua zapret-obfs.lua zapret-pcap.lua zapret-tests.lua zapret-wgobfs.lua; do echo good > "$LUA/$f"; done
    FETCH_MODE=good
    FETCH_LOG="$BCW_ENGINE_ROOT/fetch.log"
}
mock() {
    case "$2" in
    good) cat > "$1" <<'MOCK'
#!/bin/sh
if [ "$1" = --help ]; then echo ' --filter-mark=<mark>' >&2; exit 1; fi
[ "$1" = --dry-run ] || exit 2
[ "$2" = --qnum=0 ] || exit 3
[ "$3" = --filter-mark=0x0 ] || exit 4
shift 3
[ "$#" = 7 ] || exit 5
for arg do
    case "$arg" in --lua-init=@*) grep -q bad "${arg#--lua-init=@}" && { echo 'Lua mismatch' >&2; exit 6; } ;; *) exit 7 ;; esac
done
exit 0
MOCK
        ;;
    old) printf '#!/bin/sh\necho " --old-option"\nexit 0\n' > "$1" ;;
    near) printf '#!/bin/sh\necho " --filter-mark-extra=0"\nexit 0\n' > "$1" ;;
    malformed) printf '<html>broken download</html>\n' > "$1" ;;
    wrongarch) printf '\177ELF\002\001\001bad architecture\n' > "$1" ;;
    hang) printf '#!/bin/sh\nexec sleep 20\n' > "$1" ;;
    hangdry) printf '#!/bin/sh\nif [ "$1" = --help ]; then echo " --filter-mark=0"; exit 1; fi\nexec sleep 20\n' > "$1" ;;
    esac
    chmod 755 "$1"
}
fetch_file() {
    echo "$1" >> "$FETCH_LOG"
    [ "$1" = openwrt/engine/nfqws2-linux-x86_64 ] || return 1
    [ "$3" = 14 ] || return 1
    case "$FETCH_MODE" in
        failed) echo partial > "$2"; return 1 ;;
        interrupted) echo partial > "$2"; sh -c 'kill -TERM "$$"'; return 1 ;;
        hang) echo partial > "$2"; sleep 20; return 1 ;;
        *) mock "$2" "$FETCH_MODE" ;;
    esac
}
reset
mock "$CANON" good
bcw_engine_check || fail 'valid help-exit1 engine rejected'
[ "${BCW_ENGINE_CHANGED:-0}" = 0 ] || fail 'check mutated state'
ok 'combined help exit1 accepted and seven Lua modules dry-run validated'

reset
mock "$CANON" old
mock "$LEGACY" old
cp "$CANON" "$TMP/old"
bcw_engine_ensure || fail 'old executable repair'
[ "$BCW_ENGINE_CHANGED" = 1 ] || fail 'missing changed state'
cmp "$TMP/old" "$BCW_ENGINE_BACKUP" || fail 'canonical backup changed'
cmp "$TMP/old" "$LEGACY.bcw-backup" || fail 'legacy backup changed'
[ "$(readlink "$LEGACY")" = "$CANON" ] || fail 'wrong scanner target'
bcw_engine_check || fail 'repaired engine incompatible'
[ "$BCW_ENGINE_CHANGED" = 1 ] || fail 'check reset changed'
ok 'old executable replaced atomically and foreign legacy file preserved'

bcw_engine_ensure || fail idempotence
[ "$BCW_ENGINE_CHANGED" = 0 ] || fail 'idempotent ensure changed state'
[ "$(wc -l < "$FETCH_LOG")" = 1 ] || fail 'healthy engine downloaded again'
ok 'healthy engine and matching Lua skip download; repeated ensure idempotent'

reset
mock "$CANON" good
ln -s /foreign/stale/nfqws2 "$LEGACY"
bcw_engine_link || fail 'stale link reconciliation'
[ "$(readlink "$LEGACY.bcw-backup")" = /foreign/stale/nfqws2 ] || fail 'foreign symlink not backed up'
[ "$BCW_ENGINE_CHANGED" = 1 ] || fail 'link repair not changed'
[ ! -f "$FETCH_LOG" ] || fail 'offline link fetched'
ok 'offline stale or dangling legacy symlink preserved then reconciled'

for kind in malformed wrongarch old near; do
    reset
    mock "$CANON" old
    cp "$CANON" "$TMP/before"
    FETCH_MODE=$kind
    expect_fail bcw_engine_ensure
    cmp "$CANON" "$TMP/before" || fail 'rejected candidate replaced canonical'
    [ "$BCW_ENGINE_CHANGED" = 0 ] || fail 'failed candidate changed state'
    [ ! -e "$LEGACY" ] || fail 'rejected candidate changed legacy'
    ok "$kind candidate rejected without engine replacement"
done

reset
mock "$CANON" good
echo bad > "$LUA/zapret-obfs.lua"
expect_fail bcw_engine_check
case "$BCW_ENGINE_ERROR" in *Lua*mismatch*) ;; *) fail 'missing Lua error';; esac
expect_fail bcw_engine_ensure
ok 'Lua mismatch rejects current engine and downloaded candidate'

reset
mock "$CANON" good
rm "$LUA/zapret-auto.lua"
expect_fail bcw_engine_check
ok 'missing shipped Lua module fails honestly'

for mode in failed interrupted hang; do
    reset
    mock "$CANON" old
    cp "$CANON" "$TMP/before"
    FETCH_MODE=$mode
    start=$(date +%s)
    expect_fail bcw_engine_ensure
    [ "$(( $(date +%s) - start ))" -lt 6 ] || fail 'download not bounded'
    cmp "$CANON" "$TMP/before" || fail 'download failure damaged old engine'
    [ ! -d "$BCW_ENGINE_ROOT/var/run/bcw-engine.lock" ] || fail 'leaked install lock'
    ok "$mode download bounded and current engine preserved"
done

for kind in hang hangdry; do
    reset
    mock "$CANON" "$kind"
    start=$(date +%s)
    expect_fail bcw_engine_check
    [ "$(( $(date +%s) - start ))" -lt 6 ] || fail 'probe timeout not bounded'
    ok "$kind probe timeout is bounded"
done

reset
mock "$CANON" good
mkdir -p "$BCW_ENGINE_ROOT/var/run/bcw-engine.lock"
expect_fail bcw_engine_ensure
[ ! -e "$LEGACY" ] || fail 'concurrent operation changed link'
ok 'concurrent install lock fails closed'

reset
mock "$CANON" old
mkdir "$LEGACY"
cp "$CANON" "$TMP/before"
expect_fail bcw_engine_ensure
cmp "$CANON" "$TMP/before" || fail 'link failure did not roll back canonical'
ok 'scanner link failure rolls canonical back'

reset
mkdir "$LEGACY"
expect_fail bcw_engine_ensure
[ ! -e "$CANON" ] && [ ! -L "$CANON" ] || fail 'fresh canonical remains after failed scanner rebind'
[ "$BCW_ENGINE_CHANGED" = 0 ] || fail 'fresh rollback reported changed'
ok 'failed scanner rebind restores originally absent canonical state'

reset
mock "$BCW_ENGINE_ROOT/old-target" old
ln -s "$BCW_ENGINE_ROOT/old-target" "$CANON"
mkdir "$LEGACY"
expect_fail bcw_engine_ensure
[ "$(readlink "$CANON")" = "$BCW_ENGINE_ROOT/old-target" ] || fail 'rollback lost original canonical symlink'
[ "$BCW_ENGINE_CHANGED" = 0 ] || fail 'symlink rollback reported changed'
ok 'failed scanner rebind restores exact original canonical symlink'

reset
mock "$CANON" good
echo bad > "$LUA/zapret-lib.lua"
mkdir "$TMP/staged-lua"
cp "$LUA"/*.lua "$TMP/staged-lua/"
echo good > "$TMP/staged-lua/zapret-lib.lua"
BCW_ENGINE_LUA_DIR="$TMP/staged-lua"
bcw_engine_ensure || fail 'staged Lua override'
[ ! -e "$FETCH_LOG" ] || fail 'matching staged Lua downloaded engine'
ok 'staged Lua override validates without mutating installed Lua'

reset
mock "$LEGACY" good
ln -s "$LEGACY" "$CANON"
bcw_engine_ensure || fail 'canonical reverse symlink materialization'
[ ! -L "$CANON" ] || fail 'canonical remains a symlink'
bcw_engine_check || fail 'cycle created'
[ "$(readlink "$LEGACY")" = "$CANON" ] || fail 'legacy not canonical'
[ ! -e "$FETCH_LOG" ] || fail 'compatible reverse link downloaded'
ok 'compatible reverse symlink materialized without download or link cycle'

reset
ln -s /missing/old/engine "$CANON"
bcw_engine_ensure || fail 'dangling canonical repair'
[ "$(readlink "$BCW_ENGINE_BACKUP")" = /missing/old/engine ] || fail 'dangling canonical backup lost'
ok 'dangling canonical symlink preserved and repaired'

reset
mock "$CANON" old
printf 'previous backup' > "$CANON.bcw-backup"
bcw_engine_ensure || fail 'backup collision install'
[ "$(cat "$CANON.bcw-backup")" = 'previous backup' ] || fail 'existing backup overwritten'
[ "$BCW_ENGINE_BACKUP" = "$CANON.bcw-backup.1" ] || fail 'backup collision not handled'
ok 'existing rollback backup never overwritten'

reset
bcw_engine_ensure || fail 'fresh engine install'
bcw_engine_check || fail 'fresh engine incompatible'
ok 'missing engine installed from official project callback'

# Actual checked-in executable: no NFQUEUE binding in dry-run.
case "$(uname -s):$(uname -m)" in
Linux:x86_64)
    BCW_ENGINE_TIMEOUT=8
    bcw_engine_check "$REPO/openwrt/engine/nfqws2-linux-x86_64" "$REPO/openwrt/luci-app-blockcheckw/root/usr/share/zapret2wizard/lua" || fail 'real bundled engine dry-run'
    ok 'real bundled x86_64 engine and shipped Lua pass capability dry-run'
    ;;
*) echo 'SKIP real x86_64 Linux engine check on this host' ;;
esac
printf 'PASS: %s engine lifecycle checks\n' "$N"
