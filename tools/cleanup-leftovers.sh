#!/bin/sh
# Use the same owner as init/helper/packages. After removal use a local checkout.
MODULE="${BCW_LIFECYCLE_ROOT:-}/usr/share/zapret2wizard/lifecycle.sh"
if [ ! -r "$MODULE" ]; then
    MODULE="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)/openwrt/luci-app-blockcheckw/root/usr/share/zapret2wizard/lifecycle.sh"
fi
[ -r "$MODULE" ] || { echo "Lifecycle module missing; use the complete repository" >&2; exit 1; }
. "$MODULE"
if bcw_lifecycle_cleanup; then
    echo "Owned DNS, QUIC, nft and cron leftovers removed."
else
    echo "Cleanup failed: ${BCW_LIFECYCLE_ERROR:-unknown}" >&2
    exit 1
fi
