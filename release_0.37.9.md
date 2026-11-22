# 0.37.9 — timeout dependency found by live verification

Live Routerich ARM64/OpenWrt25.12.6 test of0.37.8 found no standalone timeout or BusyBox applet. Runtime remained functional, but engine validation and rollback-status reporting failed.

The shared engine owner now ensures coreutils-timeout before engine/Lua changes. Installation uses apk/opkg with a bounded watchdog even when timeout itself is missing. Package metadata includes the dependency; install.sh uses the bounded shared guard, not its generic unbounded package loop.

Verified locally:21 dependency regressions under sh+BusyBox ash, lifecycle25, helper20, engine-only init5, post-update UI4; independent source review has no blocking findings.

Verified live after installing the missing prerequisite: ARM64 engine repair state done; doctor ok15/15; builtin search done100% with21 unique recipes; data check12 protocol entries passed3/3 with full delivery,34.96s. Service restored to running and existing six strategy sections retained (auto-apply disabled). rutracker.org HTTP200,96503bytes in0.582s. All5 protected configuration SHA256 hashes unchanged. Router-local restricted backup: /root/bcw-pre-0378-20261122. NanoPi reporter acceptance remains unknown.
