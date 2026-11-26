#!/bin/sh
# Offline helper regressions. All writes stay in a private mktemp tree.
# Run: sh tools/test_engine_helper.sh (requires python3; no root/router needed).
set -u
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
HELPER="$ROOT/openwrt/luci-app-blockcheckw/root/usr/bin/blockcheckw-helper"
ENGINE="$ROOT/openwrt/luci-app-blockcheckw/root/usr/share/zapret2wizard/engine.sh"
command -v python3 >/dev/null 2>&1 || { echo 'FAIL: python3 is required'; exit 1; }
TMP=$(mktemp -d "${TMPDIR:-/tmp}/bcw-helper-test.XXXXXX") || exit 1
# TMP is exclusively the directory returned by mktemp, never a router path.
trap 'rm -rf "$TMP"' EXIT
trap 'exit 1' HUP INT TERM
BCW_LIB_ONLY=1
. "$HELPER"
# Sourcing only defines functions; redirect every helper data file before calls.
STATUS_FILE="$TMP/status.json"
LOG_FILE="$TMP/scan.log"
OUTPUT_SCAN="$TMP/scan.json"
OUTPUT_CIRCULAR="$TMP/circular.txt"
failures=0
fail() { echo "FAIL: $*"; failures=$((failures + 1)); }
ok() { echo "OK: $*"; }

# Original error must survive trailing progress output (not just the last 5 lines).
error='ERROR nfqws2 rejected "--filter-mark=0x0"; requires build "new"'
printf '%s\n' "$error" > "$LOG_FILE"
i=0
while [ "$i" -lt 12 ]; do printf 'progress %s\n' "$i" >> "$LOG_FILE"; i=$((i + 1)); done
[ "$(scan_error_detail "$LOG_FILE" 6)" = "$error" ] \
    && ok 'uppercase ERROR before trailing progress is preserved' \
    || fail 'uppercase ERROR before trailing progress was lost'
printf 'progress only\n' > "$TMP/no-error.log"
case "$(scan_error_detail "$TMP/no-error.log" 6)" in
    *6*) ok 'missing diagnostic falls back to exit code' ;;
    *) fail 'missing diagnostic lost exit code' ;;
esac

# Verify the exact write_status boundary, without requiring OpenWrt luci.jsonc.
# JSON encoding itself belongs to write_status/LuCI; this asserts unchanged raw
# quoted detail and separate extra JSON arguments, not an interpolated JSON blob.
(
    write_status() { printf '%s\000' "$@" > "$TMP/status.args"; }
    scan_failure 6 "$LOG_FILE"
) || fail 'scan_failure returned nonzero'
if python3 - "$TMP/status.args" "$error" <<'PY'
import pathlib, sys
args = pathlib.Path(sys.argv[1]).read_bytes().split(b'\0')
assert args == [b'error', b'0', ('Ошибка подбора: ' + sys.argv[2]).encode(), b',"strategies":[]', b''], args
PY
then ok 'scan_failure preserves quoted detail at write_status boundary'
else fail 'scan_failure mangled quoted diagnostic/status arguments'; fi

# Extract production blocks: fail loudly when anchors change, never silently test
# a reimplementation. Only the scanner executable is replaced with our fixture.
python3 - "$HELPER" "$TMP" <<'PY'
import pathlib, re, sys
source = pathlib.Path(sys.argv[1]).read_text()
out = pathlib.Path(sys.argv[2])
start = source.index('        BCW_REPORT_DIR="$report_run/probe" HOME="$scan_home" /usr/bin/blockcheckw --qnum "$scan_qnum"')
end = source.index('        local probe_eval=', start)
block = source[start:end]
assert 'local probe_exit=$?' in block and 'scan_failure ' in block
assert block.count('/usr/bin/blockcheckw') == 1
(out / 'phase1.sh').write_text(block.replace('/usr/bin/blockcheckw', '"$scanner"'))
start = source.index('        cleanup_subshell() {')
end = source.index('\n        }', start) + len('\n        }')
cleanup = source[start:end]
cleanup = re.sub(r'(?<![\w/])/(?:etc|usr|opt|tmp|var)(?=/|[\s;\"\']|$)', lambda m: str(out / 'cleanup-root') + m[0], cleanup)
(out / 'cleanup.sh').write_text(cleanup + '\n')
preflight = source[source.index('scan_preflight() {'):source.index('\ncmd_start() {')]
start = preflight.index('    if ! engine_load')
end = preflight.index('\n    fi', start) + len('\n    fi')
(out / 'preflight-engine.sh').write_text(preflight[start:end] + '\n')
(out / 'preflight-full.sh').write_text(source[source.index('scan_preflight() {'):source.index('\ncmd_start() {')] + '\n')
# Extract just the real worker, not the dispatcher or any background launcher.
start = source.index('\ncmd_engine_repair() {') + 1
end = source.index('\n}\n', start) + 3
worker = source[start:end]
start = source.index('\ncmd_engine_repair_bg() {') + 1
end = source.index('\n}\n', start) + 3
worker += '\n' + source[start:end]
start = source.index('\nensure_lua_layout() {') + 1
end = source.index('\n}\n', start) + 3
worker += '\n' + source[start:end]
# Prefix literal router roots, including bare /opt in chmod. Real engine.sh is
# not transformed: BCW_ENGINE_ROOT supplies its supported fixture root instead.
worker = re.sub(r'(?<![\w/])/(?:etc|usr|opt|tmp|var)(?=/|[\s;\"\']|$)', lambda m: str(out / 'worker-root') + m[0], worker)
(out / 'worker.sh').write_text(worker)
PY
[ "$?" = 0 ] || { echo 'FAIL: production block extraction'; exit 1; }

printf '#!/bin/sh\nprintf "ERROR fixture preflight failure\\n"\nexit "${SCANNER_EXIT:-6}"\n' > "$TMP/scanner"
chmod +x "$TMP/scanner"
run_probe() (
    scanner="$TMP/scanner"
    report_run="$TMP/report-run"
    mkdir -p "$report_run/probe"
    scan_home="$TMP" scan_qnum=49000 workers=1 domain=example.invalid
    protocols=tls12 scan_dns=system probe_corpus="$TMP/corpus" probe_output="$TMP/probe.json"
    LOG_FILE="$TMP/probe.log"
    scan_failure() { printf '%s\n%s\n' "$1" "$2" > "$TMP/probe.failure"; }
    probe() {
        . "$TMP/phase1.sh"
        printf 'phase2\n' > "$TMP/phase2.marker"
    }
    probe
)
run_probe
rc=$?
if [ "$rc" = 6 ] && [ ! -e "$TMP/phase2.marker" ] &&
   [ "$(cat "$TMP/probe.failure")" = "$(printf '6\n%s' "$TMP/probe.log")" ]; then
    ok 'phase1 exit 6 records failure and prevents phase2'
else fail "phase1 failfast (exit=$rc)"; fi
SCANNER_EXIT=0; export SCANNER_EXIT
run_probe
rc=$?
[ "$rc" = 0 ] && [ -f "$TMP/phase2.marker" ] \
    && ok 'successful phase1 reaches next phase marker' || fail 'successful phase1 was blocked'
unset SCANNER_EXIT

# Execute the same fatal probe with the actual EXIT cleanup installed. Record
# effects instead of deleting paths, sending signals, or running firewall tools.
run_probe_cleanup() (
    scan_lock_owned="$1" scan_service_was_running="$2"
    report_run=""
    LOG_FILE="$TMP/cleanup-probe.log" PID_FILE="$TMP/cleanup.pid"
    scanner="$TMP/scanner" scan_home="$TMP" scan_qnum=49000 workers=1
    domain=example.invalid protocols=tls12 scan_dns=system
    probe_corpus="$TMP/corpus" probe_output="$TMP/probe.json"
    SCAN_KEEPER=12345
    rm() { printf 'rm %s\n' "$*" >> "$TMP/cleanup.events"; }
    kill() { printf 'kill %s\n' "$*" >> "$TMP/cleanup.events"; }
    nft() { printf 'nft %s\n' "$*" >> "$TMP/cleanup.events"; }
    get_dpi_service_status() { echo stopped; }
    restart_dpi_service() { printf 'restart\n' >> "$TMP/cleanup.events"; }
    scan_failure() { :; }
    . "$TMP/cleanup.sh"
    trap cleanup_subshell EXIT
    probe() { . "$TMP/phase1.sh"; }
    probe
)
for cleanup_case in 0:1 1:0 1:1; do
    : > "$TMP/cleanup.events"
    run_probe_cleanup "${cleanup_case%:*}" "${cleanup_case#*:}"
    rc=$?
    if python3 - "$TMP/cleanup.events" "$cleanup_case" "$rc" <<'PY'
import pathlib, sys
lines = pathlib.Path(sys.argv[1]).read_text().splitlines()
owned, running = map(int, sys.argv[2].split(':'))
assert sys.argv[3] == '6', sys.argv[3]
if not owned:
    assert lines == [], lines
else:
    releases = [i for i, line in enumerate(lines) if line.startswith('rm ') and '/bcw_scan.lock' in line]
    assert len(releases) == 1, lines
    restarts = [i for i, line in enumerate(lines) if line == 'restart']
    if running:
        assert len(restarts) == 1 and restarts[0] < releases[0], lines
    else:
        assert not restarts, lines
PY
    then ok "fatal probe EXIT cleanup ownership $cleanup_case"
    else fail "fatal probe EXIT cleanup ownership $cleanup_case"; fi
done

# Load/check/link fixture: never source installed modules or call modprobe/nft.
(
    BCW_ENGINE_ROOT="$TMP/module-root"
    mkdir -p "$BCW_ENGINE_ROOT/usr/share/zapret2wizard"
    cat > "$BCW_ENGINE_ROOT/usr/share/zapret2wizard/engine.sh" <<'MODULE'
bcw_engine_check() { printf 'check\n' >> "$TMP/module.calls"; return "${CHECK_RC:-0}"; }
bcw_engine_link() { bcw_engine_check || return 1; printf 'link\n' >> "$TMP/module.calls"; }
MODULE
    engine_load || exit 1
    bcw_engine_check || exit 1
    miss='' hint=''
    . "$TMP/preflight-engine.sh"
    [ -z "$miss" ] || exit 1
    [ "$(cat "$TMP/module.calls")" = "$(printf 'check\ncheck\nlink')" ] || exit 1
    CHECK_RC=1 BCW_ENGINE_ERROR='fixture incompatible'
    . "$TMP/preflight-engine.sh"
    case "$miss" in *'fixture incompatible'*) ;; *) exit 1 ;; esac
    BCW_ENGINE_ROOT="$TMP/absent-module-root"
    engine_load && exit 1
    [ -n "$BCW_ENGINE_ERROR" ]
) && ok 'engine_load and preflight delegate to fixture check/link' \
  || fail 'engine_load/preflight fixture delegation'

# issue #6: an incompatible/foreign nfqws2 must be classified as "engine" with a
# JSON error_code and the repair hint; --no-reply must stay silent so start_bg
# can emit the single repairing reply itself.
(
    . "$TMP/preflight-full.sh"
    ensure_lua_layout() { :; }
    engine_load() { BCW_ENGINE_ERROR='Движок не поддерживает обязательный --filter-mark: /usr/bin/nfqws2'; return 1; }
    bcw_engine_link() { return 1; }
    write_status() { :; }
    engine_reply() { :; }
    modprobe() { :; }
    LOG_FILE="$TMP/preflight.log"
    BCW_PREFLIGHT_CODE="" BCW_PREFLIGHT_JSON=""
    scan_preflight --no-reply >"$TMP/pf.out" && exit 1
    [ -s "$TMP/pf.out" ] && exit 1
    [ "$BCW_PREFLIGHT_CODE" = engine ] || exit 1
    case "$BCW_PREFLIGHT_JSON" in *'"error_code":"engine"'*) ;; *) exit 1 ;; esac
    case "$BCW_PREFLIGHT_JSON" in *engine_repair*) ;; *) exit 1 ;; esac
    python3 -c 'import json,sys; json.loads(sys.argv[1])' "$BCW_PREFLIGHT_JSON" || exit 1
    # Quotes from engine output must not break JSON.
    engine_load() { BCW_ENGINE_ERROR='unsupported "--filter-mark"'; return 1; }
    scan_preflight --no-reply >/dev/null || true
    python3 -c 'import json,sys; json.loads(sys.argv[1])' "$BCW_PREFLIGHT_JSON" || exit 1
    # start_bg must advertise repair instead of a dead end.
    grep -q 'cmd_engine_repair_bg >/dev/null 2>&1' "$HELPER" || exit 1
    # issue #6 root cause: staged Lua must be readable by the dropped nfqws2 uid.
    grep -q 'chmod 755 "$work"' "$HELPER" || exit 1
    grep -q 'chmod 755 "$work/new-lua"' "$HELPER" || exit 1
    grep -q 'exec 9>&-; cmd_engine_repair_bg' "$HELPER" || exit 1
    grep -q '"repairing":true' "$HELPER" || exit 1
) && ok 'preflight classifies incompatible engine and start_bg offers repair' \
  || fail 'preflight engine classification / start_bg repair advert'

# Full synchronous worker with production engine module, fake executable and
# fake downloads. Worker/layout hardcoded paths are relocated; services and
# status serialization are mocked. No live modules/services/nft are invoked.
worker_root="$TMP/worker-root"
mkdir -p "$TMP/fixtures"
cat > "$TMP/fixtures/compatible" <<'GOOD'
#!/bin/sh
if [ "${1:-}" = --help ]; then echo ' --filter-mark=<mark>'; exit 1; fi
for arg do
    case "$arg" in --lua-init=@*)
        f=${arg#--lua-init=@}
        [ -s "$f" ] || exit 4
        printf '%s\n' "$f" >> "$BCW_ENGINE_ROOT/probe.paths"
    ;; esac
done
exit 0
GOOD
printf '#!/bin/sh\necho "old executable without supported option"\nexit 1\n' > "$TMP/fixtures/old"
chmod +x "$TMP/fixtures/compatible" "$TMP/fixtures/old"

# Each case has a unique root; avoid cleanup/reuse that could hide stale state.
run_worker_case() (
    case_name="$1"
    # worker.sh contains one exact generated root; derive a separate safe copy.
    BCW_ENGINE_ROOT="$TMP/case-$case_name"
    export BCW_ENGINE_ROOT
    BCW_ENGINE_ARCH=x86_64; export BCW_ENGINE_ARCH
    python3 - "$TMP/worker.sh" "$worker_root" "$BCW_ENGINE_ROOT" <<'PY'
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
assert sys.argv[2].startswith('/tmp/') or '/bcw-helper-test.' in sys.argv[2]
pathlib.Path(sys.argv[3]).mkdir()
pathlib.Path(sys.argv[3], 'worker.sh').write_text(text.replace(sys.argv[2], sys.argv[3]))
PY
    mkdir -p "$BCW_ENGINE_ROOT/usr/bin" "$BCW_ENGINE_ROOT/usr/share/zapret2wizard/lua" \
        "$BCW_ENGINE_ROOT/opt/zapret2/nfq2" "$BCW_ENGINE_ROOT/var/run" "$BCW_ENGINE_ROOT/tmp" "$BCW_ENGINE_ROOT/etc/init.d"
    printf '#!/bin/sh\n# BCW_ENGINE_ONLY fixture\nexit 0\n' > "$BCW_ENGINE_ROOT/etc/init.d/zapret2wizard"
    cp "$ENGINE" "$BCW_ENGINE_ROOT/usr/share/zapret2wizard/engine.sh"
    cp "$ROOT/openwrt/luci-app-blockcheckw/root/usr/share/zapret2wizard/lifecycle.sh" "$BCW_ENGINE_ROOT/usr/share/zapret2wizard/lifecycle.sh"
    if [ "$case_name" = old-updater-migration ]; then
        rm -f "$BCW_ENGINE_ROOT/usr/share/zapret2wizard/lifecycle.sh"
        rm -f "$BCW_ENGINE_ROOT/usr/share/zapret2wizard/engine.sh"
        printf '#!/bin/sh\n# old init\nexit 0\n' > "$BCW_ENGINE_ROOT/etc/init.d/zapret2wizard"
    fi
    for f in zapret-lib.lua zapret-antidpi.lua zapret-auto.lua zapret-obfs.lua zapret-pcap.lua zapret-tests.lua zapret-wgobfs.lua; do
        printf 'old Lua %s\n' "$f" > "$BCW_ENGINE_ROOT/usr/share/zapret2wizard/lua/$f"
    done
    cp "$TMP/fixtures/old" "$BCW_ENGINE_ROOT/usr/bin/nfqws2"
    cp "$TMP/fixtures/old" "$BCW_ENGINE_ROOT/opt/zapret2/nfq2/nfqws2"
    if [ "$case_name" = compatible ]; then
        cp "$TMP/fixtures/compatible" "$BCW_ENGINE_ROOT/usr/bin/nfqws2"
        ln -sf "$BCW_ENGINE_ROOT/usr/bin/nfqws2" "$BCW_ENGINE_ROOT/opt/zapret2/nfq2/nfqws2"
    fi
    case "$case_name" in
        rollback-absence)
            rm -rf "$BCW_ENGINE_ROOT/usr/share/zapret2wizard/lua"
            ;;
        source-lua-symlink)
            mv "$BCW_ENGINE_ROOT/usr/share/zapret2wizard/lua" "$BCW_ENGINE_ROOT/external-lua"
            ln -s "$BCW_ENGINE_ROOT/external-lua" "$BCW_ENGINE_ROOT/usr/share/zapret2wizard/lua"
            ;;
        rollback-symlinks)
            mv "$BCW_ENGINE_ROOT/usr/bin/nfqws2" "$BCW_ENGINE_ROOT/usr/bin/original-engine"
            ln -s original-engine "$BCW_ENGINE_ROOT/usr/bin/nfqws2"
            ln -s "$BCW_ENGINE_ROOT/usr/share/zapret2wizard/lua" "$BCW_ENGINE_ROOT/opt/zapret2/lua"
            ;;
    esac
    if [ -d "$BCW_ENGINE_ROOT/usr/share/zapret2wizard/lua" ]; then
        cp -RPp "$BCW_ENGINE_ROOT/usr/share/zapret2wizard/lua" "$BCW_ENGINE_ROOT/lua-before"
    fi
    cp -pP "$BCW_ENGINE_ROOT/usr/bin/nfqws2" "$BCW_ENGINE_ROOT/engine-before"
    cp -pP "$BCW_ENGINE_ROOT/opt/zapret2/nfq2/nfqws2" "$BCW_ENGINE_ROOT/legacy-before"
    _svc_running() { case "$case_name" in old-updater-migration|restart-failure|rollback-*) return 0 ;; *) return 1 ;; esac; }
    wait_dpi_ready() { return 0; }
    timeout() {
        # Never invoke a router service path, even if assertions regress.
        case "$*" in *'/etc/init.d/zapret2wizard restart'*)
            [ "${BCW_ENGINE_ONLY:-0}" = 1 ] && [ "${BCW_INTERNAL_STOP:-0}" = 1 ] || return 99
            grep -q BCW_ENGINE_ONLY "$BCW_ENGINE_ROOT/etc/init.d/zapret2wizard" || return 99
            printf 'restart\n' >> "$BCW_ENGINE_ROOT/restarts"
            # Fail the updated service once; rollback restart may recover. A
            # second case verifies backup retention when rollback restart fails.
            case "$case_name" in
                restart-failure) return 1 ;;
                rollback-*) [ "$(wc -l < "$BCW_ENGINE_ROOT/restarts")" -gt 1 ]; return $? ;;
            esac
            return 0 ;;
        esac
        command timeout "$@"
    }
    fetch_file() {
        printf '%s\n' "$1" >> "$BCW_ENGINE_ROOT/downloads"
        [ "$case_name" != download-failure ] || return 1
        case "$1" in
            */engine.sh) cp "$ENGINE" "$2" ;;
            */transfer_probe.lua|*/hostlist_io.sh) cp "$ROOT/openwrt/luci-app-blockcheckw/root/usr/share/zapret2wizard/${1##*/}" "$2" ;;
            */lifecycle.sh) cp "$ROOT/openwrt/luci-app-blockcheckw/root/usr/share/zapret2wizard/lifecycle.sh" "$2" ;;
            */etc/init.d/zapret2wizard)
                printf '#!/bin/sh\n# BCW_ENGINE_ONLY fixture\nexit 0\n' > "$2" ;;
            */lua/*.lua) printf 'new Lua %s\n' "${1##*/}" > "$2" ;;
            openwrt/engine/nfqws2-linux-*)
                [ "$case_name" != engine-download-failure ] || return 1
                cp "$TMP/fixtures/compatible" "$2" ;;
            *) echo "unexpected download: $1" >&2; return 1 ;;
        esac
    }
    engine_repair_state() {
        printf '%s\n' "$1" > "$BCW_ENGINE_ROOT/state"
        printf '%s\n' "$2" > "$BCW_ENGINE_ROOT/state-detail"
        printf '{"state":"%s"}\n' "$1" > "$BCW_ENGINE_ROOT/tmp/bcw_engine_repair.json"
    }
    engine_reply() { printf '%s\n' "$1" > "$BCW_ENGINE_ROOT/reply"; }
    . "$BCW_ENGINE_ROOT/worker.sh"
    LUA_SRC_DIR="$BCW_ENGINE_ROOT/usr/share/zapret2wizard/lua"
    if [ "$case_name" = early-io-failure ]; then
        engine_repair_state done 'stale previous success'
        cp() {
            case "$*" in *'/usr/bin/nfqws2 '*) return 1 ;; esac
            command cp "$@"
        }
    fi
    if [ "$case_name" = duplicate-background ]; then
        # WSL uutils mkdir 0.10.0 was independently observed returning success
        # to both simultaneous callers for one inode. Prefer OpenWrt's BusyBox
        # mkdir for this contention fixture only; production code is unchanged.
        if command -v busybox >/dev/null 2>&1; then
            mkdir() { busybox mkdir "$@"; }
        fi
        setsid() { printf 'spawn\n' >> "$BCW_ENGINE_ROOT/spawns"; }
        ( cmd_engine_repair_bg; wait ) & first=$!
        ( cmd_engine_repair_bg; wait ) & second=$!
        wait "$first" && wait "$second" || exit 1
        [ -d "$BCW_ENGINE_ROOT/var/run/bcw_engine_repair.lock" ] || exit 1
        [ "$(wc -l < "$BCW_ENGINE_ROOT/spawns")" = 1 ] || exit 1
        [ "$(cat "$BCW_ENGINE_ROOT/state")" = running ] || exit 1
        engine_repair_state done 'winner terminal state'
        cmd_engine_repair_bg; wait
        [ "$(wc -l < "$BCW_ENGINE_ROOT/spawns")" = 1 ] || exit 1
        [ "$(cat "$BCW_ENGINE_ROOT/state")" = done ] || exit 1
        exit 0
    fi
    cmd_engine_repair
    rc=$?
    [ ! -d "$BCW_ENGINE_ROOT/var/run/bcw_engine_repair.lock" ] || exit 1
    case "$case_name" in
        upgrade|old-updater-migration)
            [ "$rc" = 0 ] && [ "$(cat "$BCW_ENGINE_ROOT/state")" = done ] || exit 1
            cmp -s "$TMP/fixtures/compatible" "$BCW_ENGINE_ROOT/usr/bin/nfqws2" || exit 1
            [ "$(readlink "$BCW_ENGINE_ROOT/opt/zapret2/nfq2/nfqws2")" = "$BCW_ENGINE_ROOT/usr/bin/nfqws2" ] || exit 1
            grep -q '/new-lua/zapret-lib.lua' "$BCW_ENGINE_ROOT/probe.paths" || exit 1
            grep -q '^new Lua' "$BCW_ENGINE_ROOT/usr/share/zapret2wizard/lua/zapret-lib.lua" || exit 1
            if [ "$case_name" = old-updater-migration ]; then
                grep -q '/engine.sh$' "$BCW_ENGINE_ROOT/downloads" || exit 1
                grep -q '/etc/init.d/zapret2wizard$' "$BCW_ENGINE_ROOT/downloads" || exit 1
                grep -q BCW_ENGINE_ONLY "$BCW_ENGINE_ROOT/etc/init.d/zapret2wizard" || exit 1
                grep -q 'old init' "$BCW_ENGINE_ROOT/etc/init.d/zapret2wizard.engine-backup" || exit 1
                [ "$(wc -l < "$BCW_ENGINE_ROOT/restarts")" = 1 ] || exit 1
            fi
            downloads_before=$(wc -l < "$BCW_ENGINE_ROOT/downloads")
            cmd_engine_repair || exit 1
            # Repeated repair refreshes the two helper modules, never the engine/Lua or service.
            [ "$(wc -l < "$BCW_ENGINE_ROOT/downloads")" = "$((downloads_before + 2))" ] || exit 1
            tail -n 2 "$BCW_ENGINE_ROOT/downloads" | grep -q '/transfer_probe.lua$' || exit 1
            tail -n 2 "$BCW_ENGINE_ROOT/downloads" | grep -q '/hostlist_io.sh$' || exit 1
            [ "$(cat "$BCW_ENGINE_ROOT/state")" = done ] || exit 1
            ;;
        compatible)
            [ "$rc" = 0 ] && [ "$(cat "$BCW_ENGINE_ROOT/state")" = done ] || exit 1
            [ "$(wc -l < "$BCW_ENGINE_ROOT/downloads")" = 2 ] && [ ! -e "$BCW_ENGINE_ROOT/restarts" ] || exit 1
            grep -q '/transfer_probe.lua$' "$BCW_ENGINE_ROOT/downloads" || exit 1
            grep -q '/hostlist_io.sh$' "$BCW_ENGINE_ROOT/downloads" || exit 1
            cmp -s "$ROOT/openwrt/luci-app-blockcheckw/root/usr/share/zapret2wizard/transfer_probe.lua" "$BCW_ENGINE_ROOT/usr/share/zapret2wizard/transfer_probe.lua" || exit 1
            cmp -s "$ROOT/openwrt/luci-app-blockcheckw/root/usr/share/zapret2wizard/hostlist_io.sh" "$BCW_ENGINE_ROOT/usr/share/zapret2wizard/hostlist_io.sh" || exit 1
            ;;
        source-lua-symlink)
            [ "$rc" != 0 ] && [ "$(cat "$BCW_ENGINE_ROOT/state")" = error ] || exit 1
            [ -L "$LUA_SRC_DIR" ] && [ ! -e "$BCW_ENGINE_ROOT/downloads" ] || exit 1
            diff -r "$BCW_ENGINE_ROOT/lua-before" "$BCW_ENGINE_ROOT/external-lua" || exit 1
            ;;
        download-failure|engine-download-failure|restart-failure|rollback-*|early-io-failure)
            [ "$rc" != 0 ] && [ "$(cat "$BCW_ENGINE_ROOT/state")" = error ] || exit 1
            [ ! -e "$BCW_ENGINE_ROOT/reply" ] || [ "$(cat "$BCW_ENGINE_ROOT/reply")" != 1 ] || exit 1
            if [ "$case_name" = rollback-symlinks ]; then
                [ -L "$BCW_ENGINE_ROOT/usr/bin/nfqws2" ] || exit 1
                [ "$(readlink "$BCW_ENGINE_ROOT/usr/bin/nfqws2")" = original-engine ] || exit 1
                [ "$(readlink "$BCW_ENGINE_ROOT/opt/zapret2/lua")" = "$LUA_SRC_DIR" ] || exit 1
            else
                cmp -s "$BCW_ENGINE_ROOT/engine-before" "$BCW_ENGINE_ROOT/usr/bin/nfqws2" || exit 1
            fi
            cmp -s "$BCW_ENGINE_ROOT/legacy-before" "$BCW_ENGINE_ROOT/opt/zapret2/nfq2/nfqws2" || exit 1
            if [ "$case_name" = rollback-absence ]; then
                [ ! -e "$LUA_SRC_DIR" ] && [ ! -L "$LUA_SRC_DIR" ] || exit 1
            else
                diff -r "$BCW_ENGINE_ROOT/lua-before" "$LUA_SRC_DIR" || exit 1
            fi
            [ "$case_name" = rollback-symlinks ] || { [ ! -e "$BCW_ENGINE_ROOT/opt/zapret2/lua" ] && [ ! -L "$BCW_ENGINE_ROOT/opt/zapret2/lua" ]; } || exit 1
            if [ "$case_name" = restart-failure ]; then
                # The reported retained snapshot must be a private mktemp
                # workspace, not the retired PID-derived directory.
                retained=$(sed 's/.*: //' "$BCW_ENGINE_ROOT/state-detail")
                case "$retained" in "$BCW_ENGINE_ROOT"/tmp/bcw-engine-repair.*) ;; *) exit 1 ;; esac
                [ -d "$retained" ] && [ -f "$retained/nfqws2" ] && [ -d "$retained/lua" ] || exit 1
            fi
            ;;
    esac
)
for test_case in upgrade old-updater-migration compatible download-failure engine-download-failure restart-failure rollback-absence rollback-symlinks early-io-failure source-lua-symlink duplicate-background; do
    run_worker_case "$test_case" && ok "isolated repair worker: $test_case" \
        || fail "isolated repair worker: $test_case"
done
[ "$failures" = 0 ] || { echo "$failures helper regression(s) failed"; exit 1; }
echo 'OK: helper engine regressions (offline/temp-only)'
