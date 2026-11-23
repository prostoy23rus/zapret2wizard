#!/bin/sh
# Repository and package removal share the installed lifecycle owner.
# --remove-quic is retained: owned QUIC is now always cleaned.
AUTO_YES=0
for arg in "$@"; do
    case "$arg" in
        -y|--yes) AUTO_YES=1 ;;
        --remove-quic) ;;
        --purge-zapret) echo "Purge is no longer implicit: user strategies, hostlists and foreign engines are preserved." >&2 ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done
[ "$(id -u)" = 0 ] || { echo "Run as root" >&2; exit 1; }
if [ "$AUTO_YES" != 1 ]; then
    printf 'Remove Zapret2Wizard package/service (preserve user strategies and hostlists)? [y/N]: '
    read -r confirm
    case "$confirm" in y|Y|yes|YES) ;; *) echo "Cancelled"; exit 0 ;; esac
fi
MODULE="${BCW_LIFECYCLE_ROOT:-}/usr/share/zapret2wizard/lifecycle.sh"
[ -r "$MODULE" ] || MODULE="$(CDPATH= cd -- "$(dirname "$0")" && pwd)/openwrt/luci-app-blockcheckw/root/usr/share/zapret2wizard/lifecycle.sh"
[ -r "$MODULE" ] || { echo "Lifecycle module missing; use the complete repository" >&2; exit 1; }
. "$MODULE"
if bcw_lifecycle_remove; then
    echo "Zapret2Wizard removed; user strategies and hostlists preserved."
else
    echo "Removal failed: ${BCW_LIFECYCLE_ERROR:-unknown}" >&2
    exit 1
fi
