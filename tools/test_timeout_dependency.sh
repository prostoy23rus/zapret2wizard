#!/bin/sh
# No network, real package managers, services, or router paths are touched.
set -eu
REPO=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
MODULE="$REPO/openwrt/luci-app-blockcheckw/root/usr/share/zapret2wizard/engine.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
. "$MODULE"
N=0
ok() { N=$((N + 1)); printf 'ok %s - %s\n' "$N" "$1"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

# Match dependency-bearing fields, not comments or unrelated package mentions.
grep -Eq '^LUCI_DEPENDS:=.*[+]coreutils-timeout([[:space:]]|$)' "$REPO/openwrt/luci-app-blockcheckw/Makefile" || fail 'OpenWrt dependency missing'
ok 'OpenWrt Makefile requires coreutils-timeout'
for builder in packaging/build.py packaging/build-ipk.sh; do
    grep -Eq 'Depends:.*[, ]coreutils-timeout([, ]|$)' "$REPO/$builder" || fail "$builder dependency missing"
    ok "$builder IPK metadata requires coreutils-timeout"
done
grep -Eq -- '--info "depends:.* coreutils-timeout([ "]|$)' "$REPO/packaging/build-apk.sh" || fail 'APK dependency missing'
ok 'APK metadata requires coreutils-timeout'
if grep -Eq 'for pkg in .*coreutils-timeout' "$REPO/install.sh"; then
    fail 'timeout bootstrap must not run through unbounded generic dependency loops'
fi
ok 'installer reserves timeout dependency installation for bounded shared owner'

# The real installer guard must be immediately after sourcing the shared owner,
# before ensure. Execute just that guard with function mocks, never the installer.
awk '
    $0 == ". /usr/share/zapret2wizard/engine.sh" { source=NR; next }
    /^if ! bcw_engine_require_timeout; then$/ { require=NR }
    /^if ! bcw_engine_ensure; then$/ { ensure=NR }
    END { exit !(source && require == source + 1 && ensure > require) }
' "$REPO/install.sh" || fail 'installer guard ordering'
awk '
    /^if ! bcw_engine_require_timeout; then$/ { capture=1 }
    capture { print }
    capture && /^fi$/ { exit }
' "$REPO/install.sh" > "$TMP/installer-guard.sh"
for result in success fail; do
    rc=0
    (
        RED='' NC='' BCW_ENGINE_ERROR='mock coreutils-timeout unavailable'
        bcw_engine_require_timeout() { echo require >> "$TMP/order"; [ "$result" = success ]; }
        bcw_engine_ensure() { echo ensure >> "$TMP/order"; }
        . "$TMP/installer-guard.sh"
        bcw_engine_ensure
    ) > "$TMP/installer-output" 2>&1 || rc=$?
    if [ "$result" = success ]; then
        [ "$rc" -eq 0 ] && [ "$(tr '\n' ' ' < "$TMP/order")" = 'require ensure ' ] || fail 'installer success ordering'
    else
        [ "$rc" -eq 1 ] && [ "$(tr '\n' ' ' < "$TMP/order")" = 'require ' ] || fail 'installer continued after dependency failure'
        grep -q 'mock coreutils-timeout unavailable' "$TMP/installer-output" || fail 'installer hid dependency error'
    fi
    rm -f "$TMP/order"
    ok "installer $result guard preserves dependency-before-ensure and truthful errors"
done

# Execute the real helper dependency guard alone. A failure must exit before
# its changed marker, so the existing cleanup cannot restart a broken runtime.
HELPER="$REPO/openwrt/luci-app-blockcheckw/root/usr/bin/blockcheckw-helper"
awk '
    /^[[:space:]]*bcw_engine_require_timeout [|][|]/ { capture=1; guard=1; print; next }
    capture && /^[[:space:]]*changed=1$/ { changed=1; exit }
    END { if (!guard || !changed) exit 1 }
' "$HELPER" > "$TMP/helper-guard.sh" || fail 'helper dependency guard missing before changed marker'
for result in success fail; do
    rc=0
    (
        changed=0
        trap 'echo "$changed" > "$TMP/helper-changed"' EXIT
        BCW_ENGINE_ERROR='mock dependency unavailable'
        bcw_engine_require_timeout() { [ "$result" = success ]; }
        engine_repair_state() { printf '%s %s\n' "$1" "$2" > "$TMP/helper-state"; }
        . "$TMP/helper-guard.sh"
        changed=1
    ) || rc=$?
    if [ "$result" = fail ]; then
        [ "$rc" -eq 1 ] && [ "$(cat "$TMP/helper-changed")" = 0 ] || fail 'helper dependency failure marked runtime changed'
        [ "$(cat "$TMP/helper-state")" = 'error mock dependency unavailable' ] || fail 'helper hid dependency error'
    else
        [ "$rc" -eq 0 ] && [ "$(cat "$TMP/helper-changed")" = 1 ] || fail 'helper success stopped before changed marker'
    fi
    ok "helper $result dependency seam keeps cleanup mutation marker truthful"
done

# The module gets an isolated PATH containing only sleep, chmod and explicitly
# selected mock package managers. Even an accidental external apk/opkg call
# cannot reach the host package managers. The mock itself uses shell builtins.
SLEEP=$(command -v sleep)
CHMOD=$(command -v chmod)
reset() {
    MOCK_BIN="$TMP/bin-$N"
    MOCK_LOG="$TMP/package-$N.log"
    MOCK_MODE=success
    BCW_ENGINE_DEP_TIMEOUT=1
    BCW_ENGINE_ERROR=''
    mkdir -p "$MOCK_BIN"
    ln -s "$SLEEP" "$MOCK_BIN/sleep"
    ln -s "$CHMOD" "$MOCK_BIN/chmod"
    export MOCK_BIN MOCK_LOG MOCK_MODE
}
mock_manager() {
    cat > "$MOCK_BIN/$1" <<'MOCK'
#!/bin/sh
printf '%s %s\n' "${0##*/}" "$*" >> "$MOCK_LOG"
printf 'mock package-manager output\n'
case "$MOCK_MODE" in
    fail) exit 42 ;;
    hang) sleep 20; exit 0 ;;
    missing) exit 0 ;;
    success)
        printf '#!/bin/sh\nexit 0\n' > "$MOCK_BIN/timeout"
        chmod 755 "$MOCK_BIN/timeout"
        ;;
    *) exit 99 ;;
esac
MOCK
    chmod 755 "$MOCK_BIN/$1"
}
require() {
    BCW_ENGINE_ERROR=''
    rc=0
    # Assignment is not scoped to the function: restore PATH explicitly.
    saved_path=$PATH
    PATH=$MOCK_BIN
    bcw_engine_require_timeout > "$TMP/require-stdout" 2> "$TMP/require-stderr" || rc=$?
    PATH=$saved_path
    [ ! -s "$TMP/require-stdout" ] || fail 'package-manager output polluted caller stdout'
    return "$rc"
}
expect_failure() {
    if require; then fail 'module accepted unavailable timeout'; fi
    [ -n "$BCW_ENGINE_ERROR" ] || fail 'module failed without error'
}
reset
printf '#!/bin/sh\nexit 0\n' > "$MOCK_BIN/timeout"
chmod 755 "$MOCK_BIN/timeout"
require || fail 'existing timeout rejected'
[ ! -e "$MOCK_LOG" ] || fail 'existing timeout installed packages'
ok 'existing timeout is accepted without package calls'

reset
expect_failure
[ ! -e "$MOCK_LOG" ] || fail 'no-manager case called package command'
case "$BCW_ENGINE_ERROR" in *coreutils-timeout*) ;; *) fail 'no-manager error lost dependency name' ;; esac
ok 'missing timeout without package manager fails honestly'

for manager in apk opkg; do
    reset
    mock_manager "$manager"
    require || fail "$manager installation failed: $BCW_ENGINE_ERROR"
    grep -q 'mock package-manager output' "$TMP/require-stderr" || fail 'package output not routed to stderr'
    case "$manager" in apk) expected='apk add coreutils-timeout' ;; opkg) expected='opkg install coreutils-timeout' ;; esac
    [ "$(cat "$MOCK_LOG")" = "$expected" ] || fail "$manager incorrect install arguments"
    [ -x "$MOCK_BIN/timeout" ] || fail "$manager timeout not installed"
    require || fail "$manager repeat rejected"
    [ "$(wc -l < "$MOCK_LOG")" -eq 1 ] || fail "$manager repeated package install"
    ok "$manager installs coreutils-timeout once and repeat is idempotent"

    reset
    mock_manager "$manager"
    MOCK_MODE=fail
    expect_failure
    case "$BCW_ENGINE_ERROR" in *42*) ;; *) fail "$manager failure code lost" ;; esac
    ok "$manager package failure is reported"

    reset
    mock_manager "$manager"
    MOCK_MODE=missing
    expect_failure
    [ ! -e "$MOCK_BIN/timeout" ] || fail 'missing-timeout mock invalid'
    ok "$manager success without timeout is rejected"

    reset
    mock_manager "$manager"
    MOCK_MODE=hang
    started=$(date +%s)
    expect_failure
    elapsed=$(( $(date +%s) - started ))
    [ "$elapsed" -lt 6 ] || fail "$manager dependency watcher exceeded bound ($elapsed seconds)"
    ok "$manager hanging install bounded without timeout executable"
done

reset
mock_manager apk
mock_manager opkg
require || fail 'dual-manager case failed'
[ "$(cat "$MOCK_LOG")" = 'apk add coreutils-timeout' ] || fail 'apk not preferred over opkg'
ok 'apk preferred when both managers exist'

for invalid in 0 -1 invalid; do
    reset
    mock_manager apk
    BCW_ENGINE_DEP_TIMEOUT=$invalid
    expect_failure
    [ ! -e "$MOCK_LOG" ] || fail 'invalid deadline invoked package manager'
    ok "invalid dependency deadline $invalid rejected before package call"
done
printf 'PASS: %s timeout dependency regressions\n' "$N"
