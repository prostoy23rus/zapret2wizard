---
name: routerich-guides
description: Практические знания RouteRich: zapret2-finder (поиск стратегий обхода), ZeroBlock (маршрутизация и прокси), soft-матрицы routing/decision, совместимость ZeroBlock с zapret2 по меткам и разбор эталонной circular-связки Routerich. Использовать при работе с finder, ZeroBlock, soft matrix, при подборе и сборке стратегий DPI-обхода.
---

# RouteRich: finder, ZeroBlock и эталонные стратегии

Источники (локальные копии):

- `zapret2-finder_full_manual.pdf` → `E:\deepseek\_refs\zapret2-finder.txt` (12 стр., авг. 2026)
- `zeroblock_full_manual (2).pdf` v0.8.5-r105 → `E:\deepseek\_refs\zeroblock.txt` (141 стр., окт. 2026)
- `SOFT_MATRIX_USER_GUIDE.md` (schema=1) — контракт soft-матриц
- исходный текст эталонной circular-связки — в разделе 4

## 1. Что чем решается

| Задача | Инструмент |
|---|---|
| Найти рабочие desync-стратегии под провайдера | `zapret2-finder` (или наш `blockcheckw` — см. skill `zapret2-desync`) |
| Проверить одну конкретную стратегию | `zapret2-finder --test-strategy`, `blockcheckw-helper apply/test` |
| Раздать трафик по прокси/VPN-секциям, DNS, failover | ZeroBlock |
| Точечно поправить выбор sing-box vs xray под конкретный прокси | soft routing/decision matrix |
| Пропустить прокси-endpoint через zapret2, если он заблокирован DPI | `desync_bypass=0` у секции ZeroBlock |

Правило: **finder и blockcheckw не запускать одновременно** — оба поднимают nfqws2 и перехватывают TCP:443. Службу обхода на время поиска останавливать (finder делает это сам, наш helper тоже).

## 2. zapret2-finder

### 2.1 Как работает

1. Останавливает `zapret2` (`/etc/init.d/zapret2 stop`).
2. Чистит оставшиеся nft-таблицы прошлых запусков.
3. Грузит цели: `--builtin` (33 CDN-хоста + список hyperion-cs/dpi-checkers), `--tcp16` (tcp16.json), `-d` (свои домены, до 64).
4. Baseline: тестирует цели **без обхода** — что реально заблокировано.
5. SNI probe: подбирает whitelist-SNI для `tls_mod` (можно отключить `--no-sni`, задать `--sni`).
6. Настраивает NFQUEUE (TCP или UDP/QUIC); при `--strategy-jobs > 1` — отдельные очереди на воркер.
7. Гоняет каждую стратегию через свой nfqws2 и параллельно проверяет все цели curl-ом.
8. Печатает TOP, пересечение «работает на всех заблокированных», пишет лог `/tmp/zapret2/finder-results.log`.
9. Чистит firewall и возвращает службу.

Прерывание (Ctrl+C / SIGTERM) сохраняет результаты завершённых воркеров и восстанавливает службу. `kill -9` — нельзя: nft-правила останутся.

### 2.2 Режимы

- `--builtin` — встроенный список CDN-хостов; недоступный GitHub → fallback на 33 хоста.
- `--tcp16` — фиксированные IPv4-цели, HEAD + девять запросов с `X-Pad` 4 КБ в одном curl: ловит обрыв после накопления 16–20 КБ исходящих. Не смешивается с `--builtin`.
- `-d domain` / `-f file` — свои домены (HTTPS HEAD/GET).
- `--simulate` — показать список стратегий без теста (не требует root).
- `--test-strategy` — ровно одна строка аргументов nfqws2 по всем целям; код 0 только если стратегия успешна для всех.

```sh
zapret2-finder --builtin
zapret2-finder --tcp16 --no-http --tls12
zapret2-finder -d rutracker.org -d youtube.com
zapret2-finder --simulate --no-http --tls12 --no-default-blob
zapret2-finder --builtin --max-found 3 --jobs 4 --timeout 5
```

### 2.3 Опции (сводка)

| Опция | Смысл | По умолчанию |
|---|---|---|
| `-d/-f/-b` | домен / файл доменов / путь к zapret2 | `rutracker.org` / — / `/opt/zapret2` |
| `-4/-6/-46` | семейство IP (передаётся и в curl, и в nft) | `-4` |
| `-s quick\|standard\|force` | уровень перебора | `standard` |
| `--http/--no-http`, `--tls12`, `--tls13`, `--quic` | протоколы | http, tls12 |
| `--curl-get` | GET вместо HEAD для HTTPS | off |
| `--timeout N`, `--jobs N`, `--strategy-jobs N` | таймаут curl, параллельных целей, параллельных стратегий | 10 / 8 / 4 |
| `-r N` / `--rp N` | повторить последовательно / параллельно (1–5) | 1 / — |
| `--max-found N` | порог безопасных стратегий на группу (0 = без порога) | 0 |
| `--min-kb N` | минимум КБ тела ответа (принудительно GET) | 0 |
| `--sni D`, `--no-sni`, `--sni none` | управление SNI-пробой | автопроба |
| `--no-fake`, `--no-multisplit`, `--no-oob`, `--no-seqovl`, `--no-syndata`, `--no-faked`, `--no-hostfake`, `--no-tcpseg`, `--no-wssize`, `--no-combo-*` | отключить группы | все включены |
| `--no-ttl/--no-autottl/--no-md5/--no-badsum/--no-seq/--no-ack/--no-ts/--no-flags` | отключить fooling-методы | все включены |
| `--combo-only` | только combo-группы | off |
| `--extra-pre/--extra-post ARGS` | обёртка вокруг каждой стратегии | — |
| `--fake-repeats N` | повторы fake-пакетов | 1 |
| `--blob-dir`, `--no-default-blob` | каталог blob-ов | `/opt/zapret2/files/fake` |
| `-j`, `--dump-strategies` | JSON-вывод / TSV-экспорт | off |
| `--debug`, `--verbose` | логи nfqws2 по очередям / curl-команды | off |

### 2.4 Уровни `-s`

- `quick` — стоп после первой безопасной стратегии, общей для всех изначально заблокированных целей.
- `standard` — проход по группам до `--max-found` безопасных (при 0 — группа целиком).
- `force` — то же, но и для целей с успешным baseline (искать «лучше, чем сейчас»).
Покрытие между группами не наследуется: успешный `multisplit` не пропускает `fake+multisplit`.

### 2.5 Как читать вывод

```
[42/700] fake_ttl3_blob_iana
fixed: +5/14 ...      # сколько целей начало работать
broken: !0/19         # сколько ранее работавших сломалось — должно быть 0
* TOP 10 STRATEGIES (safe first, then by hosts fixed)
test: https_tls12 ipv4
nfqws2 --payload=tls_client_hello --lua-desync=...
```

- В TOP выше стоят стратегии с `broken=0`; пересечение «работает на всех» тоже только с `broken=0`.
- Лог `/tmp/zapret2/finder-results.log` (чистится каждый запуск, лимит 8 МиБ): `fixed=3/14 broken=0/19 --payload=...`.
- `UNRESOLVED` — DNS не разрешился, цель исключена (для своих доменов это ошибка запуска).

### 2.6 Применение найденной стратегии

```sh
# взять строку из /tmp/zapret2/finder-results.log (без 'nfqws2')
uci set zapret2.nfqws2.args='--payload=tls_client_hello --lua-desync=...'
uci commit zapret2 && /etc/init.d/zapret2 restart
```

В нашем продукте то же делает `blockcheckw-helper apply --target preset_youtube --script "<args>"` (он ещё и проверяет трафик и умеет откатиться).

### 2.7 Рецепты для роутера

```sh
# 256 МБ RAM: без combo, по 3 стратегии на группу
zapret2-finder --builtin --jobs 4 --timeout 5 --max-found 3 \
  --no-combo-multi --no-combo-faked --no-combo-hostfake

# быстрый ответ «есть ли вообще рабочий обход»
zapret2-finder --builtin --jobs 8 --timeout 3 --max-found 1 -s quick

# ночной полный прогон
zapret2-finder --builtin --jobs 8 --timeout 10 -r 3 -s force --curl-get 2>&1 | tee /tmp/finder_full.log
```

### 2.8 Troubleshooting finder

- `device verification failed` — утилита запущена не на RouteRich.
- 0 стратегий — проверить `--simulate`; чаще всего конфликтующие `--no-*` (например `--combo-only` + все `--no-combo-*`).
- LuCI рвёт сессию/роутер тормозит — уменьшить `--jobs` до 4–2.
- Остались `zapret2_finder_*` таблицы после `kill -9`:
  ```sh
  for t in $(nft list tables | grep zapret2_finder_ | awk '{print $3}'); do nft delete table inet $t; done
  ```
- DNS: nfqws2 перехватывает только TCP:443, DNS не трогает; NXDOMAIN у builtin-цели → UNRESOLVED.

## 3. ZeroBlock

### 3.1 Архитектура в двух словах

`клиент → nftables (fakeip/TPROXY/redirect) → sing-box/xray/… → прокси-секция → upstream`

- Ядро — sing-box; для xhttp/mKCP может подниматься Xray, для отдельных протоколов — TrustTunnel/OpenFlux/NaiveProxy/FPTN/Tor.
- Каждая routing-секция — свой набор прокси + правил; есть failover-секция и секция catch-all.
- DNS: dnsmasq → sing-box (fakeip), отдельные main/bootstrap пулы, DoH/DoT/DoQ/H3, DNS recovery.
- Метки: `0x10000` — TPROXY, `0x20000` — direct-исключения, `0x40000` — BitTorrent, `0x40000000` — `desync_mark` для zapret2.

Файлы:

```
/etc/config/zeroblock            # UCI
/etc/init.d/zeroblock            # init
/usr/bin/zeroblock               # демон
/etc/zeroblock/sing-box.d/       # пользовательские конфиги sing-box
/etc/zeroblock/xray.d/           # конфиги xray (xhttp/mKCP)
/etc/zeroblock/trusttunnel/      # toml на секцию
/etc/zeroblock/dns-main.json     # каталог Main DNS (active)
/etc/zeroblock/dns-bootstrap.json
/tmp/zeroblock/                  # runtime: rulesets, cache
/tmp/dnsmasq.d/zeroblock*.conf   # DNS hijack / nftset
```

Управление: `uci set zeroblock.<section>.<opt>=...; uci commit zeroblock; /etc/init.d/zeroblock reload` (для части изменений — `restart`).

### 3.2 Совместимость с zapret2 (важно для нашего продукта)

- ZeroBlock маркирует соединение к **upstream proxy endpoint** меткой `zeroblock.engine.desync_mark` (по умолчанию `0x40000000`).
- zapret2 (и наш `zapret2wizard`) пропускает пакеты с этой меткой: nft-правила вида `meta mark & 0x40000000 != 0` → accept, а nfqws2 запускается с `--fwmark=0x40000000`.
- У каждой секции есть `desync_bypass`:
  - `1` (по умолчанию) — endpoint маркируется, zapret2 его **не** обрабатывает;
  - `0` — не маркируется, zapret2 может применить обход к соединению с прокси-сервером (нужно, если сам прокси заблокирован DPI).
- Политика задаётся в LuCI «DPI bypass for proxy connection»; отдельной UCI-опции `desync_bypass_sections` нет; для Bootstrap — `zeroblock.engine.bootstrap_desync_bypass`.
- Метка должна совпадать у обеих сторон. Пример:

```sh
# прокси заблокирован DPI — разрешаем zapret2 обработать соединение к нему
uci set zeroblock.my_proxy.desync_bypass='0'
uci commit zeroblock && /etc/init.d/zeroblock reload

# сменить метку (и синхронизировать с zapret2!)
uci set zeroblock.engine.desync_mark='0x40000000'
```

- Защита от петли: ZeroBlock собирает snapshot адресов всех endpoint (секции, подписки, failover, цепочки, WG/AmneziaWG peers) и не заворачивает их обратно в туннель. Для секций с `desync_bypass=0` отдельный NFT-набор пропускает соединение без метки.
- Скрытая опция `zeroblock.engine.exclude_nft_endpoint` (точные host/IP через запятую) отключает оба механизма для выбранного endpoint. Применять только к тому, что действительно должно вернуться в ZeroBlock: для endpoint самой proxy-секции это создаст петлю.

### 3.3 Soft-матрицы (schema=1)

Два независимых файла и два UCI-флага:

```
/etc/zeroblock/soft_routing_matrix.json    → zeroblock.settings.soft_routing_matrix_enabled
/etc/zeroblock/soft_decision_matrix.json   → zeroblock.settings.soft_decision_matrix_enabled
```

- routing: `{"schema":1,"routing_rules":[...]}` — выбирает route (`singbox`/`xray`): `route`, `allow_routes`, `deny_routes`, `prefer_route`. Действует **первое совпавшее** правило.
- decision: `{"schema":1,"decision_rules":[...]}` — меняет модель прокси до выбора route: `drop_field`, `drop_block`, `drop_feature` + `subjects`.
- Общее: `match` = ровно один из `all` (AND) / `any` (OR); условия `{fact, eq}` или `{fact, in:[...]}`; bool-факты требуют boolean, не строку.
- После изменения — перезапуск sing-box; при выключенном флаге файлы и правила сохраняются.
- Soft matrix не применяется к raw sing-box/xray JSON, не оживляет route, который builtin уже запретил, и не ломает rebuild при битом файле (warning + ignore).

Валидация (частые причины «правило молча не работает»):

- оба массива в одном файле; лишний top-level key; `neq`/`not_in`; пустые `all`/`any`/`in`; `eq:"true"` вместо `eq:true`; неизвестный `fact`/`subject`; несовпадение `action_kind` и kind субъекта; пустые `allow_routes`/`deny_routes`.

Шаблон: VLESS+WS+TLS с `h2` ALPN → sing-box (сначала decision убирает ALPN, потом routing выбирает singbox):

```json
{
  "schema": 1,
  "decision_rules": [
    {
      "match": { "all": [
        { "fact": "proxy.protocol", "eq": "vless" },
        { "fact": "proxy.transport", "eq": "ws" },
        { "fact": "proxy.security", "eq": "tls" },
        { "fact": "proxy.tls.alpn", "in": ["h2", "h2,http/1.1", "http/1.1,h2"] }
      ] },
      "action_kind": "drop_field",
      "subjects": ["tls.alpn"]
    }
  ]
}
```

```json
{
  "schema": 1,
  "routing_rules": [
    {
      "match": { "all": [
        { "fact": "proxy.protocol", "eq": "vless" },
        { "fact": "proxy.transport", "eq": "ws" },
        { "fact": "proxy.security", "eq": "tls" }
      ] },
      "route": "singbox"
    }
  ]
}
```

Полезные факты: `proxy.protocol/transport/security`, `proxy.tls.*`, `proxy.reality.*`, `proxy.ws.*`, `proxy.grpc.*`, `proxy.xhttp.*`; субъекты: `tls.*`, `transport.*`, `vless.encryption.padding`.

## 4. Эталонная circular-связка Routerich

```
--out-range=-s34228
--in-range=-s5556 --lua-desync=circular:fails=2:time=60:retrans=3:nld=2:reset
--in-range=x
--payload=tls_client_hello
--lua-desync=multidisorder:pos=midsld:seqovl=2:seqovl_pattern=0x16030300:ip_id=rnd:strategy=1
--lua-desync=multisplit:pos=midsld:seqovl=681:seqovl_pattern=fake_default_tls:strategy=2
--lua-desync=multisplit:pos=1,sniext+1,host+1,midsld-2,midsld,midsld+2,endhost-1:seqovl=336:seqovl_pattern=fake_default_tls:ip_id=zero:strategy=3
--lua-desync=fake:blob=0x00000000:tcp_seq=-10000:repeats=3:strategy=4
--lua-desync=multisplit:pos=midsld:strategy=4
--lua-desync=tcpseg:pos=0,midsld:ip_id=rnd:strategy=5
--lua-desync=multisplit:pos=sniext+1:strategy=5
--lua-desync=hostfakesplit:host=www.google.com:tcp_md5:midhost=midsld:disorder_after:ip_id=zero:strategy=6
--lua-desync=multidisorder:pos=midsld:seqovl=sniext+1:seqovl_pattern=0x16030300:strategy=7
--lua-desync=fakeddisorder:pos=midsld:ip_autottl=-2,3-20:ip_id=zero:strategy=8
--lua-desync=luaexec:code=desync.patmod=tls_mod(fake_default_tls,rnd,dupsid,padencap,desync.reasm_data):strategy=9
--lua-desync=multisplit:pos=10,midsld:seqovl=#patmod:seqovl_pattern=patmod:strategy=9
```

Что здесь важно (и перенесено в наш `circular-builder.lua`):

- `nld=2` — состояние circular ключуется доменом 2-го уровня. У YouTube десятки `*.googlevideo.com`; без `nld` каждый хост начинает ротацию заново, с ним — общее состояние.
- `--payload` стоит **после** circular: оркестратор видит все протоколы и общее состояние хоста, а фильтр пейлоада действует только на стратегии.
- `retrans=3` — штатный порог детектора: одиночная потеря в Wi-Fi не считается блокировкой. `time=60` — окно накопления неудач; `reset` обрывает ожидание ретрансмиссий.
- `seqovl_pattern` заполняет перекрытие валидным началом TLS-записи (`0x16030300`) или fake-blob-ом: DPI собирает «правдоподобную» запись, реальный ClientHello едет следом.
- `seqovl` в этой связке использует **маркер** `sniext+1`. В manual v1.0.7 сказано, что `seqovl` — только число; на проверенной сборке RouteRich такая строка принимается и стратегия проходит, но на старых сборках маркер может игнорироваться — проверяйте `test`, а не только `apply`.
- `ip_id=rnd|zero` — возмущение IP ID, чтобы сборщик DPI не склеивал фрагменты предсказуемо. В нашей проверке стратегия `seqovl=681:seqovl_pattern=fake_default_tls:ip_id=rnd` сервис подняла, но трафик не подтвердила — держим её как кандидата корпуса, а не как гарантию.
- `hostfakesplit:host=...:tcp_md5:midhost=midsld:disorder_after` — фейк-хост + резка внутри SNI + обратный порядок хвоста.
- Девять стратегий — это «полная матрица»; наш продукт собирает 4 по одной технике на семейство из ранжированного отчёта сканера и включает связку только по результату проверки стабильности.

Проверка на RouteRich (наш прогон): `circular:nld=2` и `multidisorder:pos=midsld:seqovl=sniext+1:seqovl_pattern=0x16030300` применились и дали `all_ok`/HTTP 200; связка из 4 техник с `nld=2` — тоже `all_ok`, 3 движка, YouTube 200.

## 5. Чеклисты

**Перед поиском стратегий**

1. `blockcheckw-helper doctor` (или finder сам остановит службу).
2. Убедиться, что не запущены два обходчика одновременно (finder/zapret2/blockcheckw).
3. Для ZeroBlock: проверить `desync_bypass` секций, если прокси заблокирован.

**После применения**

1. Полная загрузка (не HEAD): ≥256 КБ, иначе обрез на 16 КБ выглядит как успех.
2. Свежие соединения (Ctrl+F5 / инкогнито).
3. Проверить, что circular реально в конфиге: `uci get zapret2wizard.BlockcheckW_YouTube.script | grep circular`.

**Диагностика**

- Нет обхода: mark-конфликт с ZeroBlock (`desync_mark`), flow offloading, права каталогов, второй движок на той же очереди.
- «Нашлось, но не работает»: проверять полной загрузкой, а не пробой; смотреть `broken` в finder-логе.
- «Правило soft matrix не работает»: сначала валидатор (лишние ключи, `neq`, пустые списки), потом перезапуск sing-box.
