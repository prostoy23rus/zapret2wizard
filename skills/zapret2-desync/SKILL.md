---
name: zapret2-desync
description: Знания по zapret2/nfqws2 для обхода DPI: устройство профилей и инстансов, параметры desync-функций, выбор стратегии под провайдера, диагностика «служба работает, а обхода нет». Использовать при работе с пресетами стратегий, командой class, подбором и разбором инцидентов.
---

# zapret2 / nfqws2: стратегии обхода DPI

Источники: `bol-van/zapret2/docs/manual.md`, архив статей `llms-full.txt` (zapret.moe), гайд `zapret2-guide.pages.dev`. Локальные копии — `E:\deepseek\_refs`.

## 1. Как устроен движок

```
пакет → nftables (queue) → nfqws2 → conntrack → распознавание L7 → выбор профиля → инстансы Lua → вердикт
```

- **Профиль** — набор фильтров (`--filter-tcp`, `--filter-l3`, `--filter-l7`, `--hostlist`) и действий.
- **Инстанс** — один вызов `--lua-desync=func:args`. Порядок вызовов = порядок применения.
- **Внутрипрофильные фильтры** `--payload`, `--in-range`, `--out-range` действуют на все последующие инстансы до переопределения.
- Вердикты: `PASS` < `MODIFY` < `DROP` (агрегируются по максимуму).

Практический минимум для стратегии:

```
--payload=tls_client_hello --lua-desync=<техника>:<аргументы>
```

## 2. Техники

| Техника | Аргументы | Когда применять |
|---|---|---|
| `multisplit` | `pos`, `seqovl`, `seqovl_pattern`, `blob`, `nodrop` | ТСПУ не склеивает сегменты: нарезка по порядку |
| `multidisorder` | то же | ТСПУ не собирает сегменты в обратном порядке |
| `fakeddisorder` | `pos`, `seqovl`, `blob`, `nofake1..4`, `pattern` | Фейк + перестановка сегментов |
| `fakedsplit` | `pos`, `seqovl`, `blob` | Фейк с нарезкой, порядок сохраняется |
| `tcpseg` | `pos`, `seqovl` | Переразбиение на сегменты по MSS (выравнивание под MSS) |
| `hostfakesplit` | `host`, `midhost`, `disorder_after`, `blob` | Фейки вокруг SNI/Host + split внутри имени |
| `fake` | `blob`, `optional`, `tls_mod`, fooling | Поддельный пакет без нарезки: TTL, badsum, tcp_md5, tcp_ts |
| `rst` | `rstack`, fooling | Сбить состояние DPI сбросом |
| `syndata` | `blob`, `tcp_ts_up` | Данные в SYN |
| `wssize` | `wsize`, `scale`, `forced_cutoff` | Уменьшить окно, чтобы DPI не дождался полного ClientHello |
| `oob` | `char`, `byte`, `urp=b/e` | Срочные данные в handshake (требует `--in-range=-s1`) |
| `udplen` | `min`, `max`, `increment`, `pattern` | QUIC/Discord: изменить длину UDP |
| `drop` | — | Отбросить пакет |

**Fooling-опции** (работают как аргументы большинства техник): `ip_ttl`, `ip_autottl=delta,min-max`, `ip6_autottl`, `tcp_seq`, `tcp_ack`, `tcp_ts`, `tcp_ts_up`, `tcp_md5`, `tcp_flags_set/unset`, `ip6_hopbyhop*`, `ip6_destopt*`, `ip6_routing`, `ip6_ah`, `badsum`, `fool`.

**Позиции `pos`**: число; `sld`, `midsld`, `host`, `endhost`, `sniext`, арифметика `host+1`, `midsld-2`, `endhost-1`, списки через запятую `1,sniext+1,endhost-1`.

**Блобы**: `--blob=name:@file|0xHEX`; встроенные имена — `fake_default_tls`, `fake_default_http`.

## 3. Алгоритм выбора стратегии

1. `blockcheckw-helper doctor` — nftables, движок, 3 инстанса, flow offloading off, каталоги 755.
2. `blockcheckw-helper class` — какие семейства пропускает ТСПУ (9 базовых приёмов).
3. По результату выбрать семейство:
   - прошли только нарезки → `multisplit`/`multidisorder`;
   - прошли фейки без нарезки → `fake` + fooling (`ip_autottl`, `badsum`, `tcp_md5`);
   - прошли комбинации → `fakeddisorder`/`fakedsplit`;
   - ничего → вероятен блок по IP или отпечатку клиента.
4. Подбор (`Запустить поиск`) — кандидаты проверяются полной загрузкой до 256 КБ, применяется только стратегия с `all_ok`.
5. Финальная проверка — браузер в инкогнито (Ctrl+F5).

## 4. Класс ТСПУ → рекомендация

| Прошло | Класс | Стратегия |
|---|---|---|
| 1 (multidisorder) | не собирает сегменты в обратном порядке | минимальная: `multidisorder:pos=midsld` |
| 1–2 | не склеивает сегменты | `multisplit:pos=midsld` |
| 5–7 | нужны фейки вместе с нарезкой | `fakeddisorder:pos=midsld:tcp_md5` |
| 4, 8, 9 | реагирует на поддельные пакеты | `fake` + `ip_autottl` / `rst` |
| 0 | другой тип блока | проверить DNS, IP-блок, отпечаток клиента |

## 5. Грабли, из-за которых «служба работает, а обхода нет»

1. **Права каталогов.** `nfqws2` работает от `daemon`. `/etc/zapret2wizard` и `ipset` должны быть `755`, файлы `644`, иначе `file_open_test: Permission denied` и основной инстанс не стартует (`running (2/3)`).
2. **flow offloading.** Включённое ускорение уводит пакеты мимо nfqueue. Служба отключает его при старте; `doctor` показывает статус.
3. **Стоп на 16 КБ.** ТСПУ обрывает поток. Проверка обязана запрашивать больше (у нас 256 КБ у главной страницы), иначе обрезка выглядит как успех.
4. **Circular-стратегия** — многострочный файл; строки нужно склеивать, иначе применяются обрывки вида `--payload=tls_client_hello`.
5. **Своя служба мешает подбору** — на время сканирования её останавливают.
6. **Пробы ≠ реальность.** Дешёвая проба может пройти, а полная страница — нет. Применять только проверенное.

## 6. Проверка стратегий без риска

```sh
# синтаксис и доступность файлов под сброшенными привилегиями
nfqws2 --user=daemon --fwmark=0x40000000 \
  --lua-init=@/usr/share/zapret2wizard/lua/zapret-lib.lua \
  --lua-init=@/usr/share/zapret2wizard/lua/zapret-antidpi.lua \
  --lua-init=@/usr/share/zapret2wizard/lua/zapret-auto.lua \
  --qnum=300 --dry-run --payload=tls_client_hello --lua-desync=multisplit:pos=midsld
```

`--dry-run` не поднимает движок Lua, поэтому ловит ошибки опций, но не Lua-кода.
## 6. Circular-связка

- Собирается `circular-builder.lua` из отчёта сканера: до 4 техник разных семейств, порядок — ранг сканера.
- Аргументы: `circular:fails=2:time=15:retrans=3:nld=2:reset`. `nld=2` — состояние на домен 2-го уровня (иначе каждый `*.googlevideo.com` начинает ротацию заново); `retrans=3` — чтобы одиночная потеря в Wi-Fi не считалась блокировкой; `reset` обрывает ожидание ретрансмиссий.
- `--payload` указывать **после** `circular`: оркестратор видит все протоколы, фильтр действует только на стратегии.
- Включать связку только по результату проверки стабильности (служба делает 3 прогона). Детали и Routerich-техники — skill `routerich-guides`.
