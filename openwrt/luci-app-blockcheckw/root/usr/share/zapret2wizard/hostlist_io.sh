#!/bin/sh
# Storage/count only: source this file; sourcing performs no I/O.
# hostlist_io_save SOURCE DEST: copy caller-sanitized bytes, then atomically
# replace DEST. No stdout. 0 = saved; nonzero = not saved (stderr diagnostics,
# including fixed error tokens, never JSON). Existing mode is retained; new files
# are private (0600). SOURCE is retained. Parent must already exist.
# hostlist_io_count FILE: one unsigned decimal integer + newline on success;
# absent/empty/blank/comment-only files yield 0. I/O/unsupported type => nonzero,
# no stdout. Comments start with # after optional whitespace; inline # counts.
#
# Paths/parent directories must be trusted and not concurrently retargeted by
# another actor. Leaf symlinks (including dangling links) are unsupported; no
# symlink is followed intentionally. This is atomic visibility, not fsync-based
# power-loss durability or serialization of concurrent read/modify/write edits.
# No sanitation, JSON, parent creation, restart, service or network operations.

hostlist_io_save() (
    [ "$#" -eq 2 ] && [ -n "$1" ] && [ -n "$2" ] || {
        printf '%s\n' hostlist_io_invalid_arguments >&2; exit 1;
    }
    # Prefix relative paths to prevent option interpretation by external tools.
    case "$1" in /*) source=$1 ;; *) source=./$1 ;; esac
    case "$2" in /*) dest=$2 ;; *) dest=./$2 ;; esac
    [ ! -L "$source" ] && [ -f "$source" ] && [ -r "$source" ] || {
        printf '%s\n' hostlist_io_invalid_source >&2; exit 1;
    }
    [ ! -L "$dest" ] && { [ ! -e "$dest" ] || [ -f "$dest" ]; } || {
        printf '%s\n' hostlist_io_invalid_destination >&2; exit 1;
    }
    parent=${dest%/*}
    [ -d "$parent" ] && [ ! -L "$parent" ] || {
        printf '%s\n' hostlist_io_invalid_parent >&2; exit 1;
    }
    # mktemp creates the private staging file on the destination filesystem.
    temp=$(mktemp "$parent/.hostlist_io.XXXXXX" 2>/dev/null) || {
        printf '%s\n' hostlist_io_temp_failed >&2; exit 1;
    }
    [ -n "$temp" ] || {
        printf '%s\n' hostlist_io_temp_failed >&2; exit 1;
    }
    trap 'rm -f "$temp"' 0
    trap 'exit 1' HUP INT TERM
    # cp -p carries the existing mode without requiring the optional stat
    # applet. Copy failure (including metadata preservation) aborts the save.
    # New destinations retain mktemp's private 0600 mode. Ownership/timestamps
    # may also be copied; ACL/xattr preservation is not promised.
    if [ -e "$dest" ]; then
        if ! cp -p "$dest" "$temp"; then
            printf '%s\n' hostlist_io_copy_failed >&2; exit 1
        fi
    fi
    if ! cat "$source" > "$temp"; then
        printf '%s\n' hostlist_io_write_failed >&2; exit 1
    fi
    # Recheck the leaf before committing; -T refuses directories instead of
    # moving the staging file *into* one (BusyBox/GNU mv both support -T).
    [ ! -L "$dest" ] && { [ ! -e "$dest" ] || [ -f "$dest" ]; } || {
        printf '%s\n' hostlist_io_invalid_destination >&2; exit 1;
    }
    if ! mv -fT "$temp" "$dest"; then
        printf '%s\n' hostlist_io_rename_failed >&2; exit 1
    fi
    trap - 0 HUP INT TERM
)

hostlist_io_count() (
    [ "$#" -eq 1 ] && [ -n "$1" ] || {
        printf '%s\n' hostlist_io_invalid_arguments >&2; exit 1;
    }
    case "$1" in /*) file=$1 ;; *) file=./$1 ;; esac
    [ ! -L "$file" ] || {
        printf '%s\n' hostlist_io_invalid_source >&2; exit 1;
    }
    if [ ! -e "$file" ]; then
        printf '0\n'; exit 0
    fi
    [ -f "$file" ] && [ -r "$file" ] || {
        printf '%s\n' hostlist_io_invalid_source >&2; exit 1;
    }
    # Capture before printing so even a read error after partial input cannot
    # leak a plausible count to a caller that checks the exit status.
    count=$(LC_ALL=C awk '!/^[[:space:]]*(#|$)/ { n++ } END { printf "%.0f\n", n+0 }' "$file") || {
        printf '%s\n' hostlist_io_count_failed >&2; exit 1;
    }
    case "$count" in ''|*[!0-9]*)
        printf '%s\n' hostlist_io_count_failed >&2; exit 1 ;;
    esac
    printf '%s\n' "$count"
)
