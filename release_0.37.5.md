# Release 0.37.5 — Фиксы issues #5 и #6

**Дата:** 2026-11-22

## #6: не запускался поиск на чистом OpenWrt 25.x (NanoPi R3s)

- **Причина 1:** пакеты (.ipk/.apk) не объявляли kmod-зависимости. Без
  `kmod-nfnetlink-queue` и `kmod-nft-queue` nfqws2 не стартует и очередь
  nftables не создаётся → предполётная проверка → «нет движка nfqws2,
  модулей nfqueue или nftables». Модули добавлены в зависимости во всех
  сборщиках (Makefile, build-ipk.sh, build.py, build-apk.sh).
- **Причина 2:** `doctor` дёргал чужие init-скрипты и `conflicts` без таймаута —
  висящий procd-лок сторонней службы вешал диагностику до «Ошибка вызова helper».
  Все такие вызовы обёрнуты в `timeout 3/5`.
- **Улучшение:** при сбое подбора показывается конкретная причина из
  предполётной проверки, а не общий текст.

Для тех, кто обновляется кнопкой (не переустанавливая пакет):
```sh
apk add kmod-nfnetlink-queue kmod-nft-queue
modprobe nfnetlink_queue nft_queue
```

## #5: apply «Встроенных хостов» всегда откатывался

- `client_probe_output`/`client_probe_netns` трактовали цель `builtin` как имя
  хоста: резолвили `builtin` → «no A record» → проверка трафика падала →
  вечный откат «Стратегия не подняла видео».
- Теперь цель резолвит `rutracker.org` (как `target_domain`).
- UI: для не-YouTube целей откат честно говорит «Стратегия не подтвердила
  трафик» вместо «не подняла видео».

## Проверено

- `client_probe builtin` на живом роутере: host=rutracker.org (раньше был builtin)
- doctor: отрабатывает быстро, JSON корректен
- Страница LuCI: карточка видна, ошибок нет
- Синтаксис: busybox ash -n (helper), node --check (main.js), py_compile (build.py)
