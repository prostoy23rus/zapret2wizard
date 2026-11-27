# Матрица проверок 0.36.9

Проверки выполнены на реальных роутерах после чистых пакетных установок.
Тестовые данные не заменяют проверки на других провайдерах.

## Провайдеры

| Провайдер | ASN | Платформа | Версия | Результат |
|---|---|---|---|---|
| Ростелеком | AS12389 | OpenWrt 25.12 / 24.10.5 aarch64 | 0.36.5-0.36.9 | YouTube/Discord/Instagram работают |
| МТС Москва | AS25513 | RouteRich 25.12.6 aarch64 | 0.36.9 | exact probes пройдены |

## aarch64

| Платформа | Пакет | Установка | DNS | Движки | nft |
|---|---|---|---|---|---|
| OpenWrt 25.12 | .apk | чистая | ok | 3 | 1 |
| OpenWrt 24.10.5 | .ipk | чистая | ok | 3 | 1 |

## Exact probes

### Домашний 25.12, .apk

| Сервис | output | netns |
|---|---|---|
| YouTube | 200, 889627 | не проверялся (нет kmod-veth) |
| Discord | 200, 77711 | не проверялся |
| Instagram | 200, 391513 | не проверялся |

На ПК: YouTube играет, Discord gateway 200.

### Удалённый 24.10.5, .ipk

| Сервис | output | netns |
|---|---|---|
| YouTube | 200, 878109 | 200, 881027 |
| Discord | 200, 77711 | 200, 77739 |
| Instagram | 200, 390814 | 200, 390815 |

### МТС Москва, AS25513, 25.12.6 aarch64, 0.36.9

| Сервис | output | netns |
|---|---|---|
| YouTube | 200, 1039963 + video host ok | 200, 980495 |
| Discord | 200, 77334 | 200, 77306 |
| Instagram | 200, 390671 | 200, 390700 |

Установлен `kmod-veth`; `client_probe_netns` проходит по всем трём сервисам.

## Пакеты

```
luci-app-blockcheckw_0.36.5-1_aarch64_cortex-a53.ipk: OK
zapret2wizard_0.36.5-r1_aarch64_cortex-a53.apk: OK
```

Checksums из релиза `v0.36.5` проверены.

## Baseline

- source tag: `v0.36.5`;
- baseline tag: `v0.36.5-baseline`;
- branch: `stable/v0.36.5`;
- snapshot: `/etc/zapret2wizard/baseline-0.36.5`.

## Что ещё не проверено

- Билайн/МегаФон;
- `arm_cortex-a7` и `x86_64` на реальном железе;
- чистый `.apk` на роутере без уже установленных зависимостей;
- IPv6-сеть (сейчас baseline рассчитан на IPv4-only).
## Совместимость с ZeroBlock

Проверено на RouteRich 25.12.6 aarch64, МТС AS25513, оба сервиса включены.

- ZeroBlock полностью маршрутизирует клиента через `fully_routed_ips`:
  `nft` ставит метку `0x10000`, TPROXY отправляет трафик в `127.0.0.1:2154`,
  DNS клиента подменяется на `127.0.0.42:53`.
- Такой клиент **не проходит через nfqws2** Zapret2Wizard: это не конфликт
  очередей, а другой путь обработки. Без ZeroBlock тот же клиент идёт через
  наши правила и YouTube работает.
- У ZeroBlock `Awg_multi` использует URLTest по интерфейсам. Health-check
  `gstatic.com/generate_204` может проходить на всех, но YouTube на части
  интерфейсов недоступен. Пример: `rrws_112_17` — health 143 ms, YouTube timeout;
  `rrws_192_26` — YouTube 350 ms. URLTest может выбрать плохой интерфейс.
- Исправление на роутере: оставить в `Awg_multi` только проверенные
  интерфейсы (`rrws_192_26`, `rrws_192_95`) или убрать клиента из
  `fully_routed_ips`, если он должен обрабатываться Zapret2Wizard.

Проверка через тестовый клиент 192.168.11.250, полностью routed через ZeroBlock:

| Selector | YouTube via ZeroBlock |
|---|---|
| `rrws_112_17` | timeout (000) |
| `rrws_192_26` | 200 |
| после удаления `rrws_112_17` | 200, оба сервиса включены |

Вывод: для совместной работы нужно исправлять выбор интерфейса в ZeroBlock;
Zapret2Wizard не должен и не может применять desync к уже tproxy-нутому трафику.
### OnePlus .107 и ZeroBlock

- `.107` не входит в `fully_routed_ips`, но ZeroBlock tproxy-ит его
  Google/Telegram через community-списки FPTN; в цепочке соединения видно
  `FPTN__section`, а не nfqws2.
- Прямой тест FPTN SOCKS (127.0.0.2:20180) открывает YouTube: 200/204.
- Нормальный клиент через netns (без ZeroBlock tproxy) проходит через нашу
  службу: YouTube 200 при обоих включённых сервисах.
- Исторические per-client логи 18:00-02:00 на роутере не сохраняются:
  logread начинается после перезагрузки, ZeroBlock API хранит только
  daemon-события с 00:00 без IP клиента. Для разбора нужен live trace.
### OnePlus .107: pcap разбора YouTube (02:30–02:34)

- DNS для `www.youtube.com`, `i.ytimg.com`, `googlevideo.com`
  возвращает реальные IP (212.188.x, 142.251.x), не fakeip.
- TCP до CDN `212.188.35.205/208`, `212.188.37.46` устанавливается,
  данные идут (SYN-ACK, TLS, payload).
- `youtubei.googleapis.com` (108.177.14.102, 142.251.127.198) — reset/timeout;
  приложение не может инициализировать API.
- С полностью выключенными ZeroBlock и Zapret2Wizard этот IP тоже
  недоступен (timeout), то есть это блокировка MTS, а не пересечение сервисов.
- `cmd_fix_ytapi` проверяет API через `curl` **на самом роутере**, а не через
  путь LAN-клиента/очередь nfqws2; поэтому все кандидаты ошибочно получают
  `api=000` и YTApi отключается. Это баг проекта.
- AWG-интерфейсы `rrws_192_26/95` открывают и YouTube (200), и API (405):
  маршрутизация клиента через AWG является рабочим обходом.

## Жизненный цикл: удаление → reboot → переустановка (0.37.24, закрытие #10)

Проверено 2026-11-26 на Routerich AX3000, OpenWrt 25.12.6, aarch64 (apk), пакет `zapret2wizard` 0.37.24-r3.

| Шаг | Результат |
|---|---|
| `helper uninstall` (путь кнопки LuCI) | `status=done, success=true` |
| После удаления | пакета нет; init.d/rc.d/меню/ACL/helper/сканер/UI удалены; nfqws2 нет; nft `zapret2wizard`/`bcw_quic` удалены; cron `# bcw-*` удалён |
| Пользовательские данные | `/etc/config/zapret2wizard` и `/etc/zapret2wizard` (genomes, memory, good_history) сохранены |
| **Reboot** | автозапуска нет: пакет отсутствует, nfqws2 не стартовал, cron/nft чистые (#10 не воспроизводится) |
| Reinstall `.apk` 0.37.24-r3 (sha256 сверен) | служба running (300/65300/65301), стратегия из конфига применилась, `test preset_youtube` = optimal |

Причина исходного бага (0.37.9): удаление было `rm -f`-скриптом без disable и удаления пакета. Начиная с 0.37.10 — проверяемый lifecycle (`lifecycle.sh`).

## issue #6: самовосстановление несовместимого движка (0.37.26, live)

Проверено 2026-11-27 на Routerich AX3000, OpenWrt 25.12.6, aarch64 (apk), пакет `zapret2wizard` 0.37.26-r3.

| Шаг | Результат |
|---|---|
| `/usr/bin/nfqws2` заменён на несовместимый бинарник без `--filter-mark` | `start_bg` → `{"repairing":true}`, панель показывает восстановление |
| `engine_repair_status` | `running` → `done`; движок восстановлен (sha256 совпал), `/opt/zapret2/nfq2/nfqws2` — корректный симлинк |
| Служба после восстановления | `running` (300/65300/65301) |
| Повторный `start_bg` | `started:true`, подбор пошёл; `stop` → служба `running`, `test preset_youtube` = optimal |

Причина, найденная live: `nfqws2` сбрасывает uid и не мог читать Lua из staged-каталога `mktemp` (0700) — скачанный движок отклонялся. Исправлено в 0.37.26 (staged `755`/`644` + освобождение flock).

## Списки доменов и цель «Встроенные хосты» (0.37.27, live)

Проверено 2026-11-27 на Routerich AX3000, OpenWrt 25.12.6, aarch64 (apk), 0.37.27.

| Проверка | Результат |
|---|---|
| `read_hostlist user` | `count:33`, `revision:<sha256 64 hex>`, домены возвращаются |
| `write_hostlist user --revision <sha256> …` | `saved:true`, `restart:"verified"`, `restart_verified:true` |
| Откат записи (исходный список) | hash совпал с исходным, 33 домена |
| `start_bg --target builtin` | подбор пошёл: «Фаза 1: Экспресс-тест векторов DPI (rutracker.org), target=builtin» |
| `stop` после подбора | служба running (300/65300/65301), `test preset_youtube` = optimal |
| 0.37.27 UI | у «Общих сайтов (User)» есть пояснение и кнопка «🎯 Подобрать стратегию для этих сайтов»; при отказе применения — модалка с причиной |

## Матрица провайдеров: как добавить свой отчёт

Отчёт готовится в панели: **Диагностика → 📤 Отчёт для матрицы** (или по SSH:
`blockcheckw-helper evidence --markdown`). Он приватный: без доменов и IP, без телеметрии —
только модель/версии, ASN, количество доменов и выбранные стратегии.
Отправка — через шаблон issue **«Отчёт провайдера для матрицы»**; подробности: `docs/PROVIDER-EVIDENCE.md`.

### Текущие записи

| Провайдер | ASN | Платформа | Версия | Результат |
|---|---|---|---|---|
| Ростелеком | AS12389 | Routerich AX3000, OpenWrt 25.12.6 aarch64 (apk) | 0.37.27 | YouTube optimal (200, 4.07 МБ, 72 КБ/с); встроенные хосты: подбор стартует; Discord degraded (200, 4.36 МБ); hostlist read/write с revision + restart_verified |
| МТС Москва | AS25513 | RouteRich 25.12.6 aarch64 | 0.36.9 | exact probes пройдены (YouTube/Discord/Instagram, netns ok) |

После любых изменений стратегий присылайте новый отчёт с датой и версией: у провайдеров бывают «волны».

## Репозиторий (feed): обновление пакетом (0.37.31, live)

Проверено 2026-11-27 на Routerich AX3000, OpenWrt 25.12.6, aarch64 (apk).

| Шаг | Результат |
|---|---|
| Добавлен `https://raw.githubusercontent.com/prostoy23rus/zapret2wizard/feed/apk` в `/etc/apk/repositories` | `apk update --allow-untrusted` → 11183 пакета, наш индекс найден |
| `apk add --allow-untrusted --upgrade zapret2wizard` | 0.37.28-r3 → **0.37.31-r3** из feed, без ручных файлов |
| После обновления | служба running (300/65300/65301), `test preset_youtube` = optimal, `evidence` показывает app 0.37.31 / pkg 0.37.31-r3 |
| Восстановление | строка feed удалена, `apk update` чистый; пакет 0.37.31-r3 остался |

opkg-индекс (`feed/opkg/<arch>/Packages`) и apk-индекс (`feed/apk/<arch>/APKINDEX.tar.gz`) генерируются CI на каждый тег; база feed: `https://raw.githubusercontent.com/prostoy23rus/zapret2wizard/feed`. Пакеты пока без подписи (`--allow-untrusted`), подпись — следующий шаг.

## Подписанный feed: доверие apk (0.37.34, live)

Проверено 2026-11-27 на Routerich AX3000, OpenWrt 25.12.6, aarch64 (apk).

| Шаг | Результат |
|---|---|
| Публичный ключ в `/etc/apk/keys/zapret2wizard-apk.pem` | 178 байт, EC P-256 |
| `apk adbdump --keys-dir /etc/apk/keys packages.adb` | `# sig v00 h04 ...: OK` |
| `apk update` **без** `--allow-untrusted` | подпись индекса проверена, 11183 пакета |
| `apk add --upgrade zapret2wizard` **без** `--allow-untrusted` | 0.37.31-r3 → **0.37.34-r3** из подписанного feed |
| После обновления | служба running (300/65300/65301), `test preset_youtube` = optimal, evidence app 0.37.34 |

Публичный ключ: `release-keys/zapret2wizard-apk.pem` (SHA256 `3983f89f80d9168ec822c0721b72d48dd7d60b97103bd8eedb0e649431f5dbe1`). Приватный ключ хранится только в GitHub Actions secret `APK_SIGN_KEY` и локальном бэкапе вне репозитория.

## issue #7/#9: честная проверка потока (0.37.35–0.37.36, live)

| Проверка | Результат |
|---|---|
| `test preset_youtube` (0.37.36) | `all_ok=true`, `optimal`; эндпоинты: страница 200/943386, объёмный гейт 206/3112260, видео-хост googlevideo 200 |
| Мёртвый `test.googlevideo.com` | NXDOMAIN (проверено router/1.1.1.1/8.8.8.8) — в 0.37.36 удалён из проверки и hostlist; primary теперь полная страница www.youtube.com |
| Объёмный гейт | 2×3.1 МБ `base.js` с Content-Length через временный nfqws; обрыв = `volume_capped`, `all_ok=false` |
| Регрессия обрыва | `test_cut_at_one_mib_is_not_verified`: 2 МиБ объявлено, 1 МиБ доставлено → `transfer_verified=false`, `termination=partial` |
| Сканер кандидатов | `check` использует полную передачу (`BodyMode::Unlimited`, M=3), не 16 КБ |

Граница: фактическое воспроизведение видео не заявляется (`playback: unknown`); видео-CDN-кап, не затрагивающий www, публичным статическим объектом не измеряется (test.googlevideo мёртв, videoplayback требует poToken).
