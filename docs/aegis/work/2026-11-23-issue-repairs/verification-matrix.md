# Verification receipt — final 2026-11-23

Baseline main b9aa19f; TaskStartSnapshot and scope in plan. TDD off/skipped. Sources changed for R1–R12; independent reviews qualified PASS (confidence B), including runtime-discovered ensure/empty/cksum followups.

## Executed final evidence
- cargo fmt --check; cargo test --offline --lib353; scanner_report_paths10; cargo clippy --offline -- -D warnings: PASS. Dedicated report integration emits harmless from_env dead-code warning; ordinary clippy has no warning. ARM64musl release build PASS; staticallylinked scanner SHA515a2cf6b1667a304ff414329bf325272a14b875f9b477f8d533f6b7de4a59ae.
- Lifecycle33, state12, hostlistintegration15, hostlist_io18, helpertransfer12, transferloopback15 +282Lua assertions: PASS. Enginehelper20, enginelifecycle25, timeoutdependency23, init5(sh+ash), QUIC/netcheck fixtures PASS. UI VM lifecycle6, metric11assertions, hostlistmodal6states/4saveoutcomes PASS. PackagingIPK/bundle smoke+realAPK build PASS. Final fullmatrix lead job pwsh-8abe8d63c90a45f9 exit0; jobs collected.
- Actual RouterichAX3000v1/OpenWrt25.12.6/kernel6.12.112/Lua5.1.5/curl8.23. Installed apk0.37.10-r3 SHA24c86982317f26b75b8131bc8d6d6c1ea8390318ad2d9d0b02dd24649b1fefc3. All8checked core artifacts exact hashmatch localreviewedsource.
- Realprocd Stop: no ownedengines/supervision/table, norespawn after6sec, bootlinksretained. RealChrome reload+hostlistmodal while stopped: no pageerrors, truthfulstoppedwarnings, noengine/table/legacyQUIC/includerecreation. Start restored3instances and ownedtables, foreignfw4/https_dns_proxy_notrack/steer retained.
- ActualLua5.1 pure282assertions PASS; realcurl loopback capture retains correctHTTPerror,completion,5788bytes; private hostlistclear→slowensure→fastensure→directensure all8empty preserved; User/excludecount0domains[]SHA64. No actualuserlistcleared. Actualinstalled readuser33/exclude631 success, UsereditorChrome openslist noerrors.
- RealYouTube check: complete941823-byte page below1.2MiBsamplethreshold => all_okfalse/playbackunknown; i.ytimg16KiBcomplete; manifest404 reachabilityonly. Speedprimaryfailed but fallbackdl2MiBcomplete notpromoted. These are diagnostictruth checks, not playbackrecovery.

## Preservation / installation
Backups local and device, packageDB+files included. Upgrades used --no-network --no-scripts --allow-untrusted, manual verifiedinit adoption .apk-new, userconfig restored. Initial DB0.36.32-r1 was older than hotfiles0.37.9; final DBmatches0.37.10r3. No reboot/uninstall/reset/GitHubwrite.
DHCP/network/rootcron/hosts unchangedhash. Userstrategyrecipes/enabled unchanged;4ownedglobalexclude bindings added toDiscord/Voice/Instagram/YTApi by planned migration. Firewallchanges onlyownedQUIC: oldduplicateReject rule retired, canonicalinclude/table remainwhenrunning and absentwhenstopped. UnknownlegacyDNSpreserved notdeletedwithoutprovenance.

## Uncovered / residual
Realuninstall/destructivepackagehooks and reboot notexecuted; mockedAPK/opkg/bundlepaths tested. No fullfreshinstall onanotherrouter or everyarchitecture. No interactiveYouTubeplayback/clientnetnsallstrategies acceptance. Rate-cappedHTTPsample notchannelcapacity; shortcompletepageinsufficientsample isunknown notproofDPI. Power-lossfsync/hostileancestorreplacement unsupported. Abruptkilledmutator may leavefailclosedruntime lock/fence requiring verifiedrecovery. Fixedbugs code+boundedruntime B, notglobalnetworkequivalence.

Private raw captures and configuration backups were retained outside the repository. Public verification summary and limitations are in [release_0.37.10.md](<../../../../release_0.37.10.md>). No credentials or private backup archives are shipped.
