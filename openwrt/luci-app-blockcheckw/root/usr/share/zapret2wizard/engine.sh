#!/bin/sh
# Shared engine lifecycle. Source from ash; no JSON, Lua-layout changes or restarts.
# Defaults are prefixed by BCW_ENGINE_ROOT (test sandbox only). Explicit check
# arguments are used verbatim. BCW_ENGINE_LUA_DIR can select a staged Lua set.
# check preserves CHANGED; ensure/link reset it and return CHANGED=0|1.
# ensure requires fetch_file(relative_path, destination, per-mirror timeout).
# Probe timeout: BCW_ENGINE_TIMEOUT=8; total fetch: BCW_ENGINE_FETCH_TIMEOUT=150.
# Optional BCW_ENGINE_ARCH selects a checked-in architecture (otherwise uname).
# BCW_ENGINE_BACKUP names the preserved previous canonical binary, if replaced.

bcw_engine_timeout() {
    local seconds="${BCW_ENGINE_TIMEOUT:-8}"
    case "$seconds" in ''|*[!0-9]*) return 125 ;; esac
    [ "$seconds" -gt 0 ] || return 125
    command -v timeout >/dev/null 2>&1 || return 125
    timeout -s KILL "$seconds" "$@"
}

bcw_engine_check() {
    local engine="${1:-${BCW_ENGINE_ROOT:-}/usr/bin/nfqws2}"
    local lua="${2:-${BCW_ENGINE_LUA_DIR:-${BCW_ENGINE_ROOT:-}/usr/share/zapret2wizard/lua}}"
    local output status f
    BCW_ENGINE_ERROR=""
    BCW_ENGINE_CHANGED="${BCW_ENGINE_CHANGED:-0}"
    [ -x "$engine" ] && [ -f "$engine" ] || {
        BCW_ENGINE_ERROR="Движок отсутствует или не исполняется: $engine"; return 1;
    }
    command -v timeout >/dev/null 2>&1 || {
        BCW_ENGINE_ERROR="Безопасная проверка невозможна: утилита timeout отсутствует"; return 1;
    }
    status=0
    output=$(bcw_engine_timeout "$engine" --help 2>&1) || status=$?
    # Current nfqws2 prints complete usage and exits 1 for --help.
    case "$status" in 0|1) ;; *)
        BCW_ENGINE_ERROR="Ошибка или таймаут --help движка (exit $status): $engine"; return 1 ;;
    esac
    printf '%s\n' "$output" | grep -Eq '(^|[[:space:]])--filter-mark([=[:space:]]|$)' || {
        BCW_ENGINE_ERROR="Движок не поддерживает обязательный --filter-mark: $engine"; return 1;
    }
    set -- --dry-run --qnum=0 --filter-mark=0x0
    # Load base before dependants, including optional modules shipped to scanner.
    for f in zapret-lib.lua zapret-antidpi.lua zapret-auto.lua zapret-obfs.lua zapret-pcap.lua zapret-tests.lua zapret-wgobfs.lua; do
        [ -r "$lua/$f" ] && [ -s "$lua/$f" ] || {
            BCW_ENGINE_ERROR="Обязательный Lua-модуль отсутствует или не читается: $lua/$f"; return 1;
        }
        set -- "$@" "--lua-init=@$lua/$f"
    done
    status=0
    output=$(bcw_engine_timeout "$engine" "$@" 2>&1) || status=$?
    [ "$status" = 0 ] || {
        output=$(printf '%s' "$output" | tr '\r\n' '  ' | cut -c 1-1200)
        BCW_ENGINE_ERROR="Ошибка или таймаут совместимости движка/Lua --dry-run (exit $status): $output"; return 1;
    }
    return 0
}

bcw_engine_arch() {
    local arch="${BCW_ENGINE_ARCH:-$(uname -m)}"
    case "$arch" in
        aarch64|arm64) echo arm64 ;;
        arm* ) echo arm ;;
        x86_64|amd64) echo x86_64 ;;
        mipsel|mipsle) echo mipsel ;;
        mips64*) echo mips64 ;;
        mips*)
            # uname does not distinguish little-endian 32-bit MIPS.
            if [ "$arch" = mips ] && [ -z "${BCW_ENGINE_ARCH:-}" ] &&
                [ -f "${BCW_ENGINE_ROOT:-}/etc/openwrt_release" ] &&
                grep -q mipsel "${BCW_ENGINE_ROOT:-}/etc/openwrt_release"; then echo mipsel
            else echo mips; fi ;;
        ppc*|powerpc*) echo ppc ;;
        riscv64) echo riscv64 ;;
        *) return 1 ;;
    esac
}

# Kill only our bounded downloader subtree, never an engine/service PID.
bcw_engine_kill_tree() {
    local pid="${1}" child children=""
    if [ -r "/proc/$pid/task/$pid/children" ]; then
        read -r children < "/proc/$pid/task/$pid/children" || true
        for child in $children; do bcw_engine_kill_tree "$child"; done
    fi
    kill -KILL "$pid" 2>/dev/null || true
}

bcw_engine_fetch() {
    local pid timer status=0 seconds="${BCW_ENGINE_FETCH_TIMEOUT:-150}"
    case "$seconds" in ''|*[!0-9]*) return 125 ;; esac
    [ "$seconds" -gt 0 ] || return 125
    ( fetch_file "${1}" "${2}" 14 ) &
    pid=$!
    BCW_ENGINE_FETCH_PID="$pid"
    ( sleep "$seconds"; bcw_engine_kill_tree "$pid" ) &
    timer=$!
    BCW_ENGINE_TIMER_PID="$timer"
    wait "$pid" 2>/dev/null || status=$?
    bcw_engine_kill_tree "$timer"
    wait "$timer" 2>/dev/null || true
    BCW_ENGINE_FETCH_PID="" BCW_ENGINE_TIMER_PID=""
    return "$status"
}

bcw_engine_backup_name() {
    local name="${1}.bcw-backup" n=0
    while [ -e "$name" ] || [ -L "$name" ]; do
        n=$((n + 1)); name="${1}.bcw-backup.$n"
    done
    printf '%s\n' "$name"
}

# Internal: caller holds the lifecycle lock and has checked the canonical engine.
bcw_engine_link_locked() {
    local canonical="${BCW_ENGINE_ROOT:-}/usr/bin/nfqws2"
    local legacy="${BCW_ENGINE_ROOT:-}/opt/zapret2/nfq2/nfqws2" backup
    [ ! -L "$canonical" ] || {
        BCW_ENGINE_ERROR="Основной движок — симлинк; выполните восстановление движка перед синхронизацией сканера"; return 1;
    }
    if [ -L "$legacy" ] && [ "$(readlink "$legacy")" = "$canonical" ]; then return 0; fi
    [ ! -d "$legacy" ] || [ -L "$legacy" ] || {
        BCW_ENGINE_ERROR="Каталог движка не будет заменён: $legacy"; return 1;
    }
    mkdir -p "${legacy%/*}" || {
        BCW_ENGINE_ERROR="Не удалось создать каталог движка сканера"; return 1;
    }
    if [ -e "$legacy" ] || [ -L "$legacy" ]; then
        backup=$(bcw_engine_backup_name "$legacy")
        cp -pP "$legacy" "$backup" || {
            BCW_ENGINE_ERROR="Не удалось сохранить предыдущий движок сканера: $legacy"; return 1;
        }
    fi
    BCW_ENGINE_LINK_STAGE=$(mktemp -d "${legacy%/*}/.nfqws2-link.XXXXXX") || {
        BCW_ENGINE_ERROR="Не удалось подготовить ссылку движка сканера"; return 1;
    }
    ln -s "$canonical" "$BCW_ENGINE_LINK_STAGE/link" &&
        mv -fT "$BCW_ENGINE_LINK_STAGE/link" "$legacy" || {
            BCW_ENGINE_ERROR="Не удалось атомарно синхронизировать движок сканера: $legacy"; return 1;
        }
    BCW_ENGINE_CHANGED=1
    return 0
}

bcw_engine_ensure_locked() {
    local canonical="${BCW_ENGINE_ROOT:-}/usr/bin/nfqws2" arch previous_error current_good=0
    if bcw_engine_check; then
        if [ ! -L "$canonical" ]; then bcw_engine_link_locked; return $?; fi
        current_good=1
    fi
    previous_error="$BCW_ENGINE_ERROR"
    [ "$current_good" = 1 ] || command -v fetch_file >/dev/null 2>&1 || {
        BCW_ENGINE_ERROR="$previous_error; функция загрузки fetch_file недоступна"; return 1;
    }
    arch=$(bcw_engine_arch) || {
        BCW_ENGINE_ERROR="Архитектура движка не поддерживается: ${BCW_ENGINE_ARCH:-$(uname -m)}"; return 1;
    }
    # Same filesystem as canonical: final rename cannot write a running inode.
    mkdir -p "${canonical%/*}" || {
        BCW_ENGINE_ERROR="Не удалось создать каталог основного движка"; return 1;
    }
    BCW_ENGINE_STAGE=$(mktemp -d "${canonical%/*}/.nfqws2-stage.XXXXXX") || {
        BCW_ENGINE_ERROR="Не удалось создать временный каталог движка"; return 1;
    }
    if [ "$current_good" = 1 ]; then
        cp -pL "$canonical" "$BCW_ENGINE_STAGE/nfqws2" || {
            BCW_ENGINE_ERROR="Не удалось заменить симлинк основного движка проверенным файлом"; return 1;
        }
    elif ! bcw_engine_fetch "openwrt/engine/nfqws2-linux-$arch" "$BCW_ENGINE_STAGE/nfqws2"; then
        BCW_ENGINE_ERROR="Ошибка или таймаут загрузки движка; предыдущий движок сохранён. $previous_error"; return 1
    fi
    [ -s "$BCW_ENGINE_STAGE/nfqws2" ] && chmod 755 "$BCW_ENGINE_STAGE/nfqws2" || {
        BCW_ENGINE_ERROR="Загруженный движок пуст или недоступен; предыдущий движок сохранён"; return 1;
    }
    bcw_engine_check "$BCW_ENGINE_STAGE/nfqws2" || {
        BCW_ENGINE_ERROR="Загруженный движок отклонён; предыдущий движок сохранён. $BCW_ENGINE_ERROR"; return 1;
    }
    [ ! -d "$canonical" ] || [ -L "$canonical" ] || {
        BCW_ENGINE_ERROR="Каталог основного движка не будет заменён"; return 1;
    }
    if [ -e "$canonical" ] || [ -L "$canonical" ]; then
        BCW_ENGINE_BACKUP=$(bcw_engine_backup_name "$canonical")
        # Exact entry state is private rollback data; public backup retains
        # runnable bytes even when canonical points into the legacy tree.
        cp -pP "$canonical" "$BCW_ENGINE_STAGE/original" || {
            BCW_ENGINE_ERROR="Не удалось сохранить исходный путь движка; замена отменена"; return 1;
        }
        if [ -L "$canonical" ] && [ ! -e "$canonical" ]; then
            cp -pP "$canonical" "$BCW_ENGINE_BACKUP"
        else
            cp -pL "$canonical" "$BCW_ENGINE_BACKUP"
        fi || {
            BCW_ENGINE_ERROR="Не удалось сохранить текущий движок; замена отменена"; return 1;
        }
    fi
    mv -fT "$BCW_ENGINE_STAGE/nfqws2" "$canonical" || {
        BCW_ENGINE_ERROR="Не удалось атомарно установить проверенный движок; предыдущий движок сохранён"; return 1;
    }
    BCW_ENGINE_CHANGED=1
    if ! bcw_engine_link_locked; then
        # Roll back canonical atomically when scanner reconciliation fails.
        if [ -n "$BCW_ENGINE_BACKUP" ]; then
            if mv -fT "$BCW_ENGINE_STAGE/original" "$canonical"; then
                BCW_ENGINE_CHANGED=0
            else
                BCW_ENGINE_ERROR="$BCW_ENGINE_ERROR; откат исходного пути движка не удался (копия: $BCW_ENGINE_BACKUP)"
            fi
        elif rm -f "$canonical"; then
            BCW_ENGINE_CHANGED=0
        else
            BCW_ENGINE_ERROR="$BCW_ENGINE_ERROR; не удалось удалить новый движок при откате"
        fi
        return 1
    fi
    BCW_ENGINE_ERROR=""
    return 0
}

# Isolate traps from sourcing callers, returning plain state via private files.
bcw_engine_transaction() {
    local operation="${1}" work status=0
    BCW_ENGINE_ERROR="" BCW_ENGINE_CHANGED=0 BCW_ENGINE_BACKUP=""
    mkdir -p "${BCW_ENGINE_ROOT:-}/tmp" "${BCW_ENGINE_ROOT:-}/var/run" || {
        BCW_ENGINE_ERROR="Не удалось создать рабочие каталоги движка"; return 1;
    }
    work=$(mktemp -d "${BCW_ENGINE_ROOT:-}/tmp/bcw-engine.XXXXXX") || {
        BCW_ENGINE_ERROR="Не удалось создать рабочий каталог движка"; return 1;
    }
    (
        BCW_ENGINE_WORK="$work"
        BCW_ENGINE_STAGE="" BCW_ENGINE_LINK_STAGE=""
        BCW_ENGINE_FETCH_PID="" BCW_ENGINE_TIMER_PID=""
        local lock="${BCW_ENGINE_ROOT:-}/var/run/bcw-engine.lock" locked=0
        trap 'printf "%s" "$BCW_ENGINE_ERROR" > "$work/error"; printf "%s" "$BCW_ENGINE_CHANGED" > "$work/changed"; printf "%s" "$BCW_ENGINE_BACKUP" > "$work/backup"; [ -z "$BCW_ENGINE_FETCH_PID" ] || bcw_engine_kill_tree "$BCW_ENGINE_FETCH_PID"; [ -z "$BCW_ENGINE_TIMER_PID" ] || bcw_engine_kill_tree "$BCW_ENGINE_TIMER_PID"; [ -z "$BCW_ENGINE_STAGE" ] || rm -rf "$BCW_ENGINE_STAGE"; [ -z "$BCW_ENGINE_LINK_STAGE" ] || rm -rf "$BCW_ENGINE_LINK_STAGE"; [ "$locked" = 0 ] || rmdir "$lock"' EXIT
        trap 'BCW_ENGINE_ERROR="Восстановление движка прервано; проверьте сохранённую резервную копию"; exit 1' HUP INT TERM
        # Fail immediately rather than racing another updater or a live probe.
        mkdir "$lock" 2>/dev/null || {
            BCW_ENGINE_ERROR="Другая операция с движком удерживает блокировку $lock"; exit 1;
        }
        locked=1
        if [ "$operation" = ensure ]; then bcw_engine_ensure_locked
        else bcw_engine_check && bcw_engine_link_locked; fi
    ) || status=$?
    [ ! -f "$work/error" ] || BCW_ENGINE_ERROR=$(cat "$work/error")
    [ ! -f "$work/changed" ] || BCW_ENGINE_CHANGED=$(cat "$work/changed")
    [ ! -f "$work/backup" ] || BCW_ENGINE_BACKUP=$(cat "$work/backup")
    rm -rf "$work"
    if [ "$status" != 0 ] && [ -z "$BCW_ENGINE_ERROR" ]; then BCW_ENGINE_ERROR="Ошибка восстановления движка (exit $status)"; fi
    return "$status"
}

bcw_engine_ensure() { bcw_engine_transaction ensure; }
bcw_engine_link() { bcw_engine_transaction link; }
