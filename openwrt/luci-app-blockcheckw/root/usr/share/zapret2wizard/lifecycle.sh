#!/bin/sh
# Shared lifecycle owner. Source this file; it never runs actions on load.
# BCW_LIFECYCLE_ROOT is an absolute disposable root for offline tests only.
bcw_lifecycle_error() { BCW_LIFECYCLE_ERROR="$1"; return 1; }
bcw_lifecycle_root() {
    case "${BCW_LIFECYCLE_ROOT:-}" in
        "") return 0 ;;
        /*) [ "$BCW_LIFECYCLE_ROOT" != / ] && [ -d "$BCW_LIFECYCLE_ROOT" ] && return 0 ;;
    esac
    bcw_lifecycle_error "invalid lifecycle root"
}
# A single mutation lock joins admission/commit with Stop teardown. An old worker
# either finishes before teardown or is refused after Stop; lock timeout is failure.
bcw_lifecycle_policy_lock() {
    local lock="${BCW_LIFECYCLE_ROOT:-}/var/run/bcw_policy.lock" n=0
    mkdir -p "${BCW_LIFECYCLE_ROOT:-}/var/run" || return 1
    while ! mkdir "$lock" 2>/dev/null; do
        [ "$n" -lt 10 ] || return 1
        sleep 1; n=$((n + 1))
    done
    BCW_POLICY_LOCK_HELD=1; export BCW_POLICY_LOCK_HELD
    [ "${1:-}" = same-shell ] || trap 'rmdir "${BCW_LIFECYCLE_ROOT:-}/var/run/bcw_policy.lock"' EXIT
}
bcw_lifecycle_transaction() (
    bcw_lifecycle_root || exit 1
    [ "${BCW_POLICY_LOCK_HELD:-0}" = 1 ] || bcw_lifecycle_policy_lock || exit 1
    "$@"
)
bcw_lifecycle_policy_run() (
    bcw_lifecycle_root || exit 1
    [ "${BCW_POLICY_LOCK_HELD:-0}" = 1 ] || bcw_lifecycle_policy_lock || exit 1
    [ ! -e "${BCW_LIFECYCLE_ROOT:-}/var/run/bcw_service.stopped" ] || exit 1
    if [ "$1" = dns ]; then
        [ "$(uci -q get zapret2wizard.main.auto_dns 2>/dev/null)" != 0 ] || exit 1
    fi
    shift
    "$@"
)
bcw_lifecycle_dns_add() {
    local key="$1" value="$2" current e journal="${BCW_LIFECYCLE_ROOT:-}/etc/zapret2wizard/dns-owned"
    case "$key" in server|address) ;; *) return 1 ;; esac
    case "$value" in /*/*) ;; *) return 1 ;; esac
    uci -q show dhcp >/dev/null 2>&1 || return 1
    current=$(uci -q get "dhcp.@dnsmasq[0].$key" 2>/dev/null)
    for e in $current; do
        [ "$e" != "$value" ] || return 0
        # Never override an existing user's same-domain pin/forwarder.
        [ "${e%/*}" != "${value%/*}" ] || return 1
    done
    mkdir -p "${journal%/*}" || return 1
    uci -q add_list "dhcp.@dnsmasq[0].$key=$value" || return 1
    # Persist exact ownership before acknowledging the write. A crash before this
    # record leaves unknown state preserved, never authority over a future user row.
    printf '%s|%s\n' "$key" "$value" >> "$journal" || {
        uci -q del_list "dhcp.@dnsmasq[0].$key=$value"
        return 1
    }
}
bcw_lifecycle_init() {
    timeout -s KILL 15 "${BCW_LIFECYCLE_ROOT:-}/etc/init.d/$1" "$2" >/dev/null 2>&1
}
bcw_lifecycle_engines() {
    local c p cmd root="${BCW_LIFECYCLE_ROOT:-}"
    for c in "$root"/proc/[0-9]*/comm; do
        [ -r "$c" ] || continue
        [ "$(cat "$c" 2>/dev/null)" = nfqws2 ] || continue
        p=${c%/comm}
        cmd=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)
        case "$cmd " in
            *--qnum=300\ *|*--qnum=65300\ *|*--qnum=65301\ *) echo "${p##*/}" ;;
        esac
    done
}
bcw_lifecycle_table_remove() {
    local tables
    tables=$(nft list tables 2>/dev/null) || return 1
    if printf '%s\n' "$tables" | grep -qx "table inet $1"; then
        nft delete table inet "$1" >/dev/null 2>&1 || return 1
    fi
    tables=$(nft list tables 2>/dev/null) || return 1
    ! printf '%s\n' "$tables" | grep -qx "table inet $1"
}

bcw_lifecycle_quic_generated() {
    local expected
    expected=$(cat <<'BCW_QUIC_BODY'
#!/bin/sh
nft delete table inet bcw_quic 2>/dev/null
nft add table inet bcw_quic
nft add chain inet bcw_quic forward '{ type filter hook forward priority -10; policy accept; }'
nft add rule inet bcw_quic forward udp dport 443 counter reject
BCW_QUIC_BODY
)
    [ "$(cat "$1" 2>/dev/null)" = "$expected" ]
}
bcw_lifecycle_quic_remove() {
    local root="${BCW_LIFECYCLE_ROOT:-}" changed=0
    bcw_lifecycle_root || return 1
    uci -q show firewall >/dev/null 2>&1 || return 1
    # Only the application's include is ours; preserve a same-named foreign section.
    if uci -q get firewall.bcw_quic >/dev/null 2>&1; then
        [ "$(uci -q get firewall.bcw_quic.path)" = /etc/bcw_quic_reject.sh ] || return 1
        uci -q delete firewall.bcw_quic || return 1
        changed=1
    fi
    if [ -f "$root/etc/bcw_quic_reject.sh" ]; then
        # Without UCI ownership require the exact script emitted by apply_quic.
        bcw_lifecycle_quic_generated "$root/etc/bcw_quic_reject.sh" || return 1
        rm -f "$root/etc/bcw_quic_reject.sh" || return 1
    fi
    if [ "$changed" = 1 ]; then uci -q commit firewall || return 1; fi
    bcw_lifecycle_table_remove bcw_quic || return 1
    [ ! -e "$root/etc/bcw_quic_reject.sh" ] && ! uci -q get firewall.bcw_quic >/dev/null 2>&1
}
bcw_lifecycle_legacy_quic_remove() {
    uci -q show firewall >/dev/null 2>&1 || return 1
    if uci -q get firewall.reject_quic >/dev/null 2>&1; then
        # Historical signature written by ensure_firewall_quic_reject.
        [ "$(uci -q get firewall.reject_quic.name)" = Reject-QUIC ] &&
        [ "$(uci -q get firewall.reject_quic.proto)" = udp ] &&
        [ "$(uci -q get firewall.reject_quic.dest_port)" = 443 ] &&
        [ "$(uci -q get firewall.reject_quic.target)" = REJECT ] || return 0
        uci -q delete firewall.reject_quic && uci -q commit firewall &&
            bcw_lifecycle_init firewall reload || return 1
    fi
}
bcw_lifecycle_stop_effects() {
    if [ "${BCW_INTERNAL_STOP:-0}" = 1 ] || [ "${BCW_ENGINE_ONLY:-0}" = 1 ]; then
        bcw_lifecycle_stop_effects_locked "$@"
    else bcw_lifecycle_transaction bcw_lifecycle_stop_effects_locked "$@"; fi
}
bcw_lifecycle_stop_effects_locked() {
    bcw_lifecycle_root || return 1
    bcw_lifecycle_table_remove zapret2wizard || return 1
    bcw_lifecycle_table_remove dead_ggc || return 1
    rm -f "${BCW_LIFECYCLE_ROOT:-}/var/run/zapret2wizard_"*.pid || return 1
    # Scanner/engine-only stop deliberately retains DNS, canary and QUIC state.
    [ "${BCW_INTERNAL_STOP:-0}" = 1 ] || [ "${BCW_ENGINE_ONLY:-0}" = 1 ] && return 0
    local root="${BCW_LIFECYCLE_ROOT:-}"
    mkdir -p "$root/var/run" || return 1
    touch "$root/var/run/bcw_service.stopped" || return 1
    if [ -x "$root/usr/bin/blockcheckw-helper" ]; then
        timeout -s KILL 5 "$root/usr/bin/blockcheckw-helper" canary_stop >/dev/null 2>&1 || return 1
    fi
    bcw_lifecycle_dns_cleanup && bcw_lifecycle_quic_remove && bcw_lifecycle_legacy_quic_remove
}
bcw_lifecycle_unsupervised() {
    local data instances
    data=$(timeout -s KILL 5 ubus call service list '{"name":"zapret2wizard"}') || return 1
    printf '%s' "$data" | jsonfilter -e '@' >/dev/null 2>&1 || return 1
    instances=$(printf '%s' "$data" | jsonfilter -e '@.zapret2wizard.instances.*' 2>/dev/null)
    [ -z "$instances" ]
}
bcw_lifecycle_service() { bcw_lifecycle_transaction bcw_lifecycle_service_locked "$@"; }
bcw_lifecycle_service_locked() {
    BCW_LIFECYCLE_ERROR=""
    bcw_lifecycle_root || return 1
    local action="$1" i=0 root="${BCW_LIFECYCLE_ROOT:-}"
    [ -x "$root/etc/init.d/zapret2wizard" ] || { bcw_lifecycle_error "init service missing"; return 1; }
    case "$action" in
        stop)
            # No disable: a user Stop does not change boot preference.
            mkdir -p "$root/var/run" && touch "$root/var/run/bcw_service.stopped" || return 1
            bcw_lifecycle_init zapret2wizard stop || { bcw_lifecycle_error "init stop failed"; return 1; }
            while [ -n "$(bcw_lifecycle_engines)" ] && [ "$i" -lt 5 ]; do sleep 1; i=$((i + 1)); done
            [ -z "$(bcw_lifecycle_engines)" ] || { bcw_lifecycle_error "owned engines still running"; return 1; }
            bcw_lifecycle_unsupervised || { bcw_lifecycle_error "service supervision remains or is unknown"; return 1; }
            bcw_lifecycle_stop_effects || { bcw_lifecycle_error "stop cleanup failed"; return 1; }
            ;;
        start|restart)
            [ ! -e "$root/var/run/bcw_service.removing" ] || { bcw_lifecycle_error "removal is in progress"; return 1; }
            rm -f "$root/var/run/bcw_service.stopped" || return 1
            bcw_lifecycle_init zapret2wizard "$action" || { bcw_lifecycle_error "init action failed"; return 1; }
            while [ "$i" -lt 10 ]; do
                if [ -n "$(bcw_lifecycle_engines)" ] && nft list table inet zapret2wizard >/dev/null 2>&1; then return 0; fi
                sleep 1; i=$((i + 1))
            done
            bcw_lifecycle_error "service readiness not confirmed"; return 1
            ;;
        *) bcw_lifecycle_error "invalid service action"; return 1 ;;
    esac
}
bcw_lifecycle_dns_cleanup() {
    local journal="${BCW_LIFECYCLE_ROOT:-}/etc/zapret2wizard/dns-owned" key value current e changed=0
    BCW_LIFECYCLE_DNS_CHANGED=0
    uci -q show dhcp >/dev/null 2>&1 || return 1
    # Unknown historical pins/forwarders have no provenance: preserve them.
    if [ -f "$journal" ]; then
        while IFS='|' read -r key value; do
            case "$key" in server|address) ;; *) return 1 ;; esac
            current=$(uci -q get "dhcp.@dnsmasq[0].$key" 2>/dev/null)
            for e in $current; do
                if [ "$e" = "$value" ]; then
                    uci -q del_list "dhcp.@dnsmasq[0].$key=$value" || return 1
                    changed=1
                fi
            done
        done < "$journal"
    fi
    if [ "$changed" = 1 ]; then
        uci -q commit dhcp && bcw_lifecycle_init dnsmasq restart || return 1
    fi
    rm -f "$journal" || return 1
    BCW_LIFECYCLE_DNS_CHANGED="$changed"
}
bcw_lifecycle_cron_cleanup() {
    local cron="${BCW_LIFECYCLE_ROOT:-}/etc/crontabs/root" tmp
    [ -f "$cron" ] || return 0
    tmp="$cron.bcw.$$"
    # A generic word such as watchdog is never ownership evidence.
    awk '!/\/usr\/bin\/blockcheckw-helper[[:space:]]+(health_tick|evolve_nightly|bypass_sync|dead_clusters_cron_run)([[:space:]]|$)/ && !/[[:space:]]#[[:space:]]bcw-(health|evolve|bypass|deadggc)[[:space:]]*$/' "$cron" > "$tmp" || return 1
    if ! cmp -s "$cron" "$tmp"; then
        cat "$tmp" > "$cron" || { rm -f "$tmp"; return 1; }
        rm -f "$tmp"
        bcw_lifecycle_init cron restart || return 1
    else rm -f "$tmp"; fi
}
bcw_lifecycle_cleanup() { bcw_lifecycle_transaction bcw_lifecycle_cleanup_locked "$@"; }
bcw_lifecycle_cleanup_locked() {
    bcw_lifecycle_root || return 1
    bcw_lifecycle_dns_cleanup && bcw_lifecycle_quic_remove &&
        bcw_lifecycle_legacy_quic_remove && bcw_lifecycle_table_remove zapret2wizard &&
        bcw_lifecycle_table_remove dead_ggc &&
        bcw_lifecycle_cron_cleanup || { bcw_lifecycle_error "owned resource cleanup failed"; return 1; }
}
bcw_lifecycle_prepare_remove() { bcw_lifecycle_transaction bcw_lifecycle_prepare_remove_guarded "$@"; }
bcw_lifecycle_prepare_remove_guarded() {
    bcw_lifecycle_prepare_remove_locked "$@" && return 0
    # No package manager has been invoked yet. A failed preparation must remain
    # retryable, unlike an interrupted package transaction of unknown completion.
    rm -f "${BCW_LIFECYCLE_ROOT:-}/var/run/bcw_service.removing"
    return 1
}
bcw_lifecycle_prepare_remove_locked() {
    bcw_lifecycle_root || return 1
    local comm
    for comm in "${BCW_LIFECYCLE_ROOT:-}"/proc/[0-9]*/comm; do
        [ "$(cat "$comm" 2>/dev/null)" != blockcheckw ] || { bcw_lifecycle_error "scanner active"; return 1; }
    done
    local root="${BCW_LIFECYCLE_ROOT:-}" link
    mkdir -p "$root/var/run" && touch "$root/var/run/bcw_service.removing" || return 1
    if [ -x "$root/etc/init.d/zapret2wizard" ]; then
        bcw_lifecycle_service stop && bcw_lifecycle_init zapret2wizard disable || return 1
    elif [ -n "$(bcw_lifecycle_engines)" ]; then
        bcw_lifecycle_error "cannot stop engines without init"; return 1
    fi
    bcw_lifecycle_unsupervised || { bcw_lifecycle_error "service supervision remains or is unknown"; return 1; }
    for link in "$root"/etc/rc.d/[SK][0-9][0-9]zapret2wizard; do
        [ ! -e "$link" ] && [ ! -L "$link" ] || { bcw_lifecycle_error "autostart link remains"; return 1; }
    done
    bcw_lifecycle_cleanup
}
bcw_lifecycle_package() {
    local list name
    BCW_LIFECYCLE_PACKAGE=""
    BCW_LIFECYCLE_PACKAGE_NAME=""
    if command -v apk >/dev/null 2>&1; then
        list=$(timeout -s KILL 5 apk info 2>/dev/null) || { bcw_lifecycle_error "apk query failed"; return 1; }
        for name in zapret2wizard luci-app-blockcheckw; do
            if printf '%s\n' "$list" | grep -qx "$name"; then
                [ -z "$BCW_LIFECYCLE_PACKAGE" ] || { bcw_lifecycle_error "ambiguous package ownership"; return 1; }
                BCW_LIFECYCLE_PACKAGE=apk; BCW_LIFECYCLE_PACKAGE_NAME="$name"
            fi
        done
    fi
    if command -v opkg >/dev/null 2>&1; then
        list=$(timeout -s KILL 5 opkg list-installed 2>/dev/null) || { bcw_lifecycle_error "opkg query failed"; return 1; }
        if printf '%s\n' "$list" | grep -q '^luci-app-blockcheckw - '; then
            [ -z "$BCW_LIFECYCLE_PACKAGE" ] || { bcw_lifecycle_error "ambiguous package ownership"; return 1; }
            BCW_LIFECYCLE_PACKAGE=opkg; BCW_LIFECYCLE_PACKAGE_NAME=luci-app-blockcheckw
        fi
    fi
}
bcw_lifecycle_remove_files() {
    local root="${BCW_LIFECYCLE_ROOT:-}" path
    # Keep /etc/config/zapret2wizard and /etc/zapret2wizard (strategies/hostlists).
    for path in usr/bin/blockcheckw usr/bin/blockcheckw-helper usr/bin/zapret2wizard usr/bin/circular-builder.lua etc/init.d/zapret2wizard etc/hotplug.d/firewall/90-zapret2wizard-bypass usr/share/blockcheckw usr/share/zapret2wizard usr/share/luci/menu.d/luci-app-blockcheckw.json usr/share/rpcd/acl.d/luci-app-blockcheckw.json www/luci-static/resources/view/blockcheckw; do
        rm -rf "$root/$path" || return 1
        [ ! -e "$root/$path" ] && [ ! -L "$root/$path" ] || return 1
    done
    # Only remove the compatibility link, never a foreign legacy engine/binary.
    path="$root/opt/zapret2/nfq2/nfqws2"
    [ "$(readlink "$path" 2>/dev/null)" != /usr/bin/nfqws2 ] || rm -f "$path" || return 1
}
bcw_lifecycle_remove() { bcw_lifecycle_transaction bcw_lifecycle_remove_locked "$@"; }
bcw_lifecycle_remove_locked() {
    BCW_LIFECYCLE_ERROR=""
    bcw_lifecycle_root && bcw_lifecycle_package || return 1
    local manager="$BCW_LIFECYCLE_PACKAGE" package_name="$BCW_LIFECYCLE_PACKAGE_NAME" root="${BCW_LIFECYCLE_ROOT:-}" backup="" rc=0
    bcw_lifecycle_prepare_remove || { bcw_lifecycle_error "removal preparation failed"; return 1; }
    if [ -n "$manager" ]; then
        # Package managers own registered files; protect mutable user data even
        # when an older package forgot to declare it as conffiles.
        backup=$(mktemp -d "$root/tmp/bcw-preserve.XXXXXX") || return 1
        if [ -d "$root/etc/zapret2wizard" ]; then cp -pR "$root/etc/zapret2wizard" "$backup/data" || return 1; fi
        if [ -f "$root/etc/config/zapret2wizard" ]; then cp -p "$root/etc/config/zapret2wizard" "$backup/config" || return 1; fi
        case "$manager" in
            apk) timeout -s KILL 45 apk del "$package_name" >/dev/null 2>&1 || rc=1 ;;
            opkg) timeout -s KILL 45 opkg remove "$package_name" >/dev/null 2>&1 || rc=1 ;;
        esac
        if [ -d "$backup/data" ]; then mkdir -p "$root/etc/zapret2wizard" && cp -pR "$backup/data/." "$root/etc/zapret2wizard/" || return 1; fi
        if [ -f "$backup/config" ]; then mkdir -p "$root/etc/config" && cp -p "$backup/config" "$root/etc/config/zapret2wizard" || return 1; fi
        rm -rf "$backup" || return 1
        [ "$rc" = 0 ] || { bcw_lifecycle_error "package removal failed"; return 1; }
        bcw_lifecycle_package && [ -z "$BCW_LIFECYCLE_PACKAGE" ] || { bcw_lifecycle_error "package remains registered"; return 1; }
    fi
    # Also retire files left by an in-place bundle update over a package.
    bcw_lifecycle_remove_files || { bcw_lifecycle_error "owned files remain"; rm -f "$root/var/run/bcw_service.removing"; return 1; }
    [ -z "$(bcw_lifecycle_engines)" ] || { bcw_lifecycle_error "owned engines remain"; rm -f "$root/var/run/bcw_service.removing"; return 1; }
    rm -f "$root/var/run/bcw_service.removing"
}
bcw_lifecycle_remove_status() {
    local file="${BCW_LIFECYCLE_ROOT:-}/tmp/blockcheckw_uninstall.json"
    printf '{"operation":"%s","status":"%s","success":%s,"error":"%s"}\n' "$1" "$2" "$3" "$4" > "$file.new" && mv -f "$file.new" "$file"
}
bcw_lifecycle_remove_begin() {
    bcw_lifecycle_root || return 1
    local root="${BCW_LIFECYCLE_ROOT:-}" work op
    mkdir -p "$root/var/run" "$root/tmp" || return 1
    if ! mkdir "$root/var/run/bcw_uninstall.lock" 2>/dev/null; then
        echo '{"success":false,"error":"removal already running"}'; return 1
    fi
    work=$(mktemp -d "$root/tmp/bcw-uninstall.XXXXXX") || { rmdir "$root/var/run/bcw_uninstall.lock"; return 1; }
    op="$(date +%s)-$$"
    if ! cp "$root/usr/share/zapret2wizard/lifecycle.sh" "$work/lifecycle.sh"; then
        rmdir "$root/var/run/bcw_uninstall.lock"; return 1
    fi
    bcw_lifecycle_remove_status "$op" running false "" || { rm -rf "$work"; rmdir "$root/var/run/bcw_uninstall.lock"; return 1; }
    cat > "$work/run.sh" <<'BCW_RUNNER'
#!/bin/sh
work="$1"; op="$2"
. "$work/lifecycle.sh"
if bcw_lifecycle_remove; then
    bcw_lifecycle_remove_status "$op" done true ""
else
    bcw_lifecycle_remove_status "$op" error false "${BCW_LIFECYCLE_ERROR:-removal failed}"
fi
rmdir "${BCW_LIFECYCLE_ROOT:-}/var/run/bcw_uninstall.lock"
rm -rf "$work"
BCW_RUNNER
    [ -s "$work/run.sh" ] || { bcw_lifecycle_remove_status "$op" error false "runner creation failed"; rm -rf "$work"; rmdir "$root/var/run/bcw_uninstall.lock"; return 1; }
    # Close RPC descriptors. The copied owner outlives package self-removal.
    ( exec 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&-; export BCW_LIFECYCLE_ROOT; exec sh "$work/run.sh" "$work" "$op" ) </dev/null >/dev/null 2>&1 &
    printf '{"success":false,"started":true,"status":"running","operation":"%s"}\n' "$op"
}

