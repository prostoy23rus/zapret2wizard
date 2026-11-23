# Исправление дефектов аудита Zapret2Wizard 0.37.9
Дата: 2026-11-23

## Цель и основания
Пользователь разрешил исправить все подтверждённые дефекты из аудита 2026-11-23 и использовать собственный Routerich AX3000 v1/OpenWrt25.12.6 для проверок. Источник требований: аудит всех десяти GitHub issues и 59 комментариев проекта (R1–R12); публичный итог — в release_0.37.10.md. Проверены README.md, CONTRIBUTING.md, scripts/ci-local.sh, Cargo.toml. CONTEXT/AGENTS/ADR индекс не обнаружен. CONTRIBUTING ссылается на старый upstream, не менять это вне текущей задачи.

## TaskStartSnapshot
main; HEAD b9aa19f466641d9b8ed3f820e8f626bda91124eb; tracked diff пуст.
Предсуществующие untracked: packaging/__pycache__/, references/, release_0.36.33.md, report_zapret2wizard_{full_testing,runtime,summary}_2026-11-21.md. Не трогать/не включать в коммит.

## Архитектура / необходимость
Decision: code-change. Настройкой исправить неверный lifecycle, фабрикацию измерений, неверную память и необработанные I/O ошибки нельзя.
Канонические владельцы: init/procd для start/stop; один общий teardown для принадлежащих приложению ресурсов и package manager для зарегистрированной установки; HTTP probe-result для transport/status/body termination; принятый кандидат для config/memory; hostlist persistence для atomic I/O; UI потребляет проверенное состояние, не выводит его из наличия файла.
ArchitectureReviewRequired: yes (общие owner/producer-consumer boundaries).
Малые модули допустимы для извлечения ответственности из 7767-строчного helper; не добавлять альтернативные duplicate owners/fallback chains. Внешние helper команды/JSON поля сохранить, расширять аддитивно; изменять ложные success-результаты на failure/unknown намеренно.

## Совместимость и сохранность
Сохранять чужие UCI/DNS/firewall/cron и пользовательские стратегии/списки. Удалять только принадлежащие службе ресурсы. Внутреннюю kill-only stop логику вывести из публичного Stop; не менять изоляцию временного nfqws сканирования. Startup migrations, no-auto-DNS и global excludes должны иметь явную семантику. Никаких tier/entitlement экспериментов или Antigravity изменений.
Не внедрять dead-edge/RST-/24 feature из issue8; не сливать предлагаемый #7 patch. Исторически исправленные issues не регрессировать.
Локально проверять unlink/package/uninstall только в mock root/disposable fixture. На реальном роутере без отдельного согласия не запускать uninstall/reboot/factory reset. На этапе исправлений публикация не выполнялась. Последующим отдельным запросом пользователь разрешил обновить GitHub и Releases; история и чужие файлы сохраняются.

## TDD Route
Mode off; decision skipped; authority текущая пользовательская настройка Aegis. RED/GREEN не обязателен, но диагностические контрпримеры и регрессии обязательны для каждой причины. Это не разрешение пропустить проверку.

## План исполнения (последовательные implementers, shared helper не редактировать одновременно)
Execution update: task4 lifecycle FINAL QUALIFIED PASS offline/source,32tests; task9 transfermodule/task10hostlistmodule/task11Rustreportpaths complete. Integration tasks6/7/8 now parallel STRICT DISJOINT function-scoped tools.edit only: probecheck/speed/client/applyverification+speedUI+moduleincludes; statecmd_start/evolve/DNS/globalexclusion attachment; hostlistIOcommands/hostlistsstatus+hostlistUI. No fullfile replacement/generator/formatters sharedfiles; agents must coordinate overlap first. Parent finaldiff review/test remains mandatory.

1. Lifecycle R1/R2/R7/R8: helper cmd_service/uninstall/cleanup, init, standalone uninstaller, package hooks, UI async status при необходимости. Одна canonical остановка и общая очистка; package removal для apk/opkg; truthful terminal status; cron строго owned. Добавить offline mock-root tests и refusal/failure cases. Явный старт не считается успешным до готовности; Stop должен отключать supervision, но не менять boot preference (disable только uninstall).
2. Verification R3/R4 + streaming integration: централизовать результат curl (exit/status/size/declared completeness), не отключать TLS trust без необходимости, убрать придуманные bytes/speed/fallback-success, разделить HTTP reachability и demonstrated transfer, согласовать check/apply/evolve. 404 root не video success; неизвестный playback честно unknown. Не требовать 4MiB у короткого законного объекта. Тесты actual production logic partial200 exit18,204zero,404tiny,valid206,rangeignored complete200,slow complete,fallback,all-fail. Осмысленный bounded data gate для YT/Discord; не обещать отсутствие всех стратегий.
3. State/consent R5/R6/R10 и дополнительные пробелы: принятый рецепт используется в memory и Circular restore; auto_dns0 контролирует все автоматические DNS writers включая gv_clear; global exclusions согласовать со всеми service profiles; autosetup не пропускать из-за generated Instagram; scanner report paths/freshness/retention направить в caller-owned directory без ломки CLI. Регрессии A fail/B pass/Circular fail; no-autoDNS; unrelated preserved; install first-run fixtures; report freshness.
4. Hostlist/UI R9/R11/R12: атомарные checked writes, строгий count/JSON, no data loss on I/O failures; restart verified отдельно от saved. Состояния exists/attached/enabled/service running, warning видим. UI service/removal/speed consumers адаптировать к truthful results, доступные feedback/error/retry states. Никакого косметического redesign. Тесты empty/comments/absent/nonempty,writefail,atomic preserve,disabled General,excludes.
5. Интеграция/проверки/доставка: независимый spec затем quality review, весь offline suite+ci-local по доступности, packaging smoke. Read-only router baseline/backup после подтверждения адреса, staged files с rollback, выборочные недеструктивные runtime/actual LuCI checks; rate/byte bounds для сетевых проверок. Сохранить суммы конфигов/чужие службы. Если live блокирован — продолжать offline и явно ограничить итог. Один scoped local commit после прохождения целого workstream; публикация только по отдельному разрешению пользователя.

## Проверки и stop conditions
На slice: исходный контрпример + valid сосед + failure/ownership. Не считать build либо HTTP404 доказательством работы службы/видео. Проверять retired path отсутствует. Review замечания важного уровня устранить до следующего slice.
Закончено только после R1–R12 dispositions, тестов и live evidence/явных ограничений; не объявлять router-fixed до runtime. Запросить недостающий адрес/host key, а не угадывать устройство. Секреты не писать в repo/логи/процессные аргументы/отчёты.
