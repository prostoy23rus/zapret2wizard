# Repair checkpoint — public summary

R1–R12 repaired for release v0.37.10. Implementation slices and independent reviews completed; verification scope and residual limitations are recorded in [verification-matrix.md](<verification-matrix.md>) and [release notes](<../../../../release_0.37.10.md>).

Validated Routerich AX3000 v1 / OpenWrt 25.12.6: installed 0.37.10-r3, three engines running, Stop → LuCI reload → no resurrection → Start passed. User and exclusion editor reads succeeded. Private temporary fixtures verified all eight empty lists remain empty. DHCP/network/cron/hosts were preserved; four managed global-exclude bindings were added. Interactive playback was not established.

Private device identity, credentials, configuration backups and raw captures are intentionally not part of the public repository or release assets. Subsequent GitHub publication is separately authorized by the project owner.
