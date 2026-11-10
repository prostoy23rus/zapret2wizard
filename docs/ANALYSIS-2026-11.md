# Анализ эталонных решений DPI-обхода и что из них взято в 0.19.0

Дата: 2026-11-10. Задача: сравнить `zapret2wizard` с девятью эталонными
проектами, выбрать рабочие техники и закрыть разрывы, не привязываясь к
сторонним службам (ZeroBlock, облачные API, телеметрия).

## Метод

* Прочитаны README, стратегии, init-скрипты, списки доменов и ключевые
  исходники каждого репозитория.
* Для `bol-van/zapret` дополнительно разобран `docs/manual.md` (zapret2
  v1.0.7): список Lua-desync функций, оркестраторы, маркеры, fooling.
* Для steer разобраны `spec-v2.md`, `ctl.md` и `explain`-команда, потому что
  именно steer, а не ZeroBlock, маршрутизирует трафик на роутере
  пользователя.
* Проверка идей — синтаксис `busybox ash`, shellcheck, unit-тест nft-движка
  в отдельном network namespace (вставка правила до `mark set`, IPv4/IPv6,
  очистка), сборка bundle 0.19.0.

## Сводная таблица

| Проект | Что это | Эталонное | Взято в 0.19.0 |
|---|---|---|---|
| `bol-van/zapret` | канонический zapret1/zapret2, `nfqws2` + Lua | полный набор desync-функций, `circular`, маркеры позиций, fooling | `circular` для YouTube, эталонные комбинации, `oob`/`tcpseg`/`syndata` в корпусе, blob’ы из файлов |
| `remittor/zapret-openwrt` | OpenWrt-пакет zapret1 + LuCI | `custom.d`-хуки, миграция конфига, DWC-проверка домена, per-daemon логи | идея пользовательских хуков и проверки домена (в `youtube_audit`), структура conffile |
| `StressOzz/Zapret-Manager` | панель + steer + автоподбор | Yv01–Yv35, `steer` исключения, `steer explain`, провайдерские рекомендации | родные исключения steer, Yv-связки в подборе, проверка решения |
| `Flowseal/zapret-discord-youtube` | Windows-набор `.bat` | `list-google.txt`, Yv01: `multisplit pos=1 seqovl=681` + `ip_id=zero` | точный Yv01-профиль, список доменов YouTube, fake QUIC как ориентир |
| `hufrea/byedpi` | C-прокси с desync | `--auto` (триггеры, кэш по IP, реконнект), `oob`/`disoob`/`tlsrec` | идея per-host fallback (circular), OOB в корпусе; `tlsrec` отмечен как пробел |
| `DPITrickster/ByeDPI-OpenWrt` | OpenWrt-обвязка byedpi | procd/respawn, `cmd_opts` как escape hatch, list-опции | `script` как escape hatch уже был; учтены list-опции и IPv6-ограничение |
| `IndeecFOX/zapret4rocket` | Entware/Keenetic-скрипт | проверка блока на 16 КБ, подбор по провайдеру, policy routing | 16-КБ тест (`tcp16`), провайдерский каталог; телеметрию не берём |
| `hyperion-cs/dpi-checkers` | Go- чекер DPI | cidr-whitelist, SNI-подмена, l4-25 (POST 64 КБ), «siberian», DNS hijack/DoH | классификация в `youtube_audit`/`doctor`; полный порт не делали |
| `Leadaxe/LxBox` | Android-клиент (sing-box fork) | TLS fragment/record_fragment, mixed-case SNI, urltest, DNS-группы | идеи health-check и mixed-case SNI; это не роутер, код не переносим |
| `splify2/steer` (контекст) | ядро маршрутизации | `zm_excl`, `domains_file`, `steer explain`, `reload` | основной backend прямого маршрута |

## Подробно по репозиториям

### 1. bol-van/zapret (zapret2, nfqws2)

Эталон синтаксиса и возможностей. В `manual.md` перечислены:

* фейки: `syndata`, `tls_client_hello_clone`, `fake`, `rst`;
* TCP-сегментация: `multisplit`, `multidisorder`,
  `multidisorder_legacy`, `fakedsplit`, `fakeddisorder`,
  `hostfakesplit`, `tcpseg`, `oob`;
* UDP: `udplen`, `dht_dn`; прочее: `synack`, `synack_split`;
* оркестраторы: `circular`, `repeater`, `condition`,
  `per_instance_condition`, `stopif`;
* маркеры `midsld`, `sniext`, `host`, `endhost`, `method`, `sld`;
* fooling `badsum`, `badseq`, `md5sig`, `datanoack`, `tcp_ts`, `tcp_seq`;
  ipid `zero`/`rnd`, `ip_autottl`.

Что было не так у нас: `circular` использовался, но его стратегии были
слабые (`pos=1,midsld`, `seqovl=1`), а эталонные `pos=1:seqovl=681` с
реальным ClientHello и `ip_id=zero` — нет. В корпусе была битая строка
`pos=1,slectv+1,mlds:0-2,acold,...` (мусор после патча), из-за которой
часть прогонов тратилась впустую.

Сделано: профиль YouTube по умолчанию собран из Yv-связок; в подбор
добавлено семейство «Reference RU 2026»; исправлена строка позиций;
`oob`/`tcpseg`/`syndata` остаются в корпусе.

Пробел: в zapret2 нет `tlsrec` и mixed-case SNI/Host (это есть в byedpi и
LxBox). Это кандидаты для отдельных Lua-функций, в 0.19.0 не реализованы.

### 2. remittor/zapret-openwrt

Пакет-эталон для OpenWrt: `config.default`, `def-cfg.sh`, `dwc.sh`,
`init.d.sh`, `sync_config.sh`, `update-pkg.sh`, `custom.d/50-script.sh`,
LuCI-страницы `service/settings/tools/diagnost/updater`.

Полезное:

* `custom.d` — пользовательские хуки, которые переживают обновление;
* `dwc.sh` — проверка домена через `curl --resolve` и диапазон байт
  (domain whitelist checker);
* аккуратная миграция конфига и синхронизация UCI ↔ conf.

Взято: идея проверки конкретного домена с подстановкой IP (логика
`youtube_audit`), отношение к конфигу как к conffile. Полный `custom.d` не
делали — в службе уже есть `script` и `route_extra`.

### 3. StressOzz/Zapret-Manager (и steer)

Самый важный проект для нашей задачи, потому что именно его `steer`
маршрутизирует трафик у пользователя.

* `Strategies.md` — v1–v10 (split2/seqovl, fake+multisplit, hostfakesplit,
  fake+fakeddisorder, игры, Discord);
* `Strategies_For_Youtube.md` и `files/StrYoutube` — Yv01–Yv35;
* `readme.md` — вкладки Steer: «Подключение», «Сервисы», «Устройства»,
  **«Исключения»**, «Настройки»; исключения всегда идут напрямую и главнее
  всех секций; `steer explain` показывает, куда пойдёт запрос;
* `docs/autobypass.md` — автоматический подбор.

Ключевое открытие: **не нужно патчить nft steer**. У steer есть родной
список исключений, который панель сама поддерживает. Наш прежний код лез в
чужие цепочки и снимал правила при reload; это работало нестабильно.

Взято: steer-native исключения (backend №1), Yv-связки, `steer explain` как
проверка, отказ от «голого» nft там, где есть steer.

### 4. Flowseal/zapret-discord-youtube

Набор `.bat` для Windows, но эталонный по подбору аргументов:

```
--filter-tcp=443 --hostlist=list-google.txt --ip-id=zero
--dpi-desync=multisplit --dpi-desync-split-seqovl=681
--dpi-desync-split-pos=1
--dpi-desync-split-seqovl-pattern=tls_clienthello_www_google_com.bin
```

Плюс `list-google.txt` (22 домена, включая `youtubei.googleapis.com`,
`jnn-pa.googleapis.com`, `youtube-ui.l.google.com`), fake QUIC initial для
UDP/443, отдельные профили Discord.

Взято: Yv01 один-в-один в синтаксисе zapret2, расширенный список доменов
YouTube, ориентир на fake QUIC. Не взято: WinDivert-часть.

### 5. hufrea/byedpi

Реализует `split`, `disorder`, `oob`, `disoob`, `fake`, `tlsrec`,
`tlsminor`, `mod-http`, `udp-fake`, `--auto` с триггерами
`t/o/r/s/c/n`, кэшем по IP и прозрачным реконнектом.

Ценность для нас — не код, а модель отказоустойчивости: успех = отсутствие
триггеров, перебор групп, запоминание результата для IP. Наш `circular`
делает похожее внутри одного профиля (счётчик неудач на host), а
`evolve`/каталог — между прогонами.

Взято: OOB-техника в корпус, идея per-host fallback. Пробел: `tlsrec` и
`disoob` в zapret2 отсутствуют; `--auto`-кэш по IP не реализован.

### 6. DPITrickster/ByeDPI-OpenWrt

Компактная procd-обвязка: `USE_PROCD=1`, respawn, `user nobody`,
`service_triggers` на config.change, `cmd_opts` как полный override, list и
boolean-опции, ожидание loopback. LuCI нет, IPv6 отдельно не выведен.

Взято: отношение к `script` как к escape hatch, list-опции, замечание про
IPv6. Не взято: сам ciadpi.

### 7. IndeecFOX/zapret4rocket

`z4r.sh` (61 КБ): определение провайдера, `Strats_Tryer`, проверка «16 КБ
блок», Keenetic policy routing, Entware init, рекомендации по провайдеру,
телеметрия в Google Forms.

Взято: 16-КБ тест (у нас `tcp16`), провайдерский каталог. Телеметрию и
внешние формы не берём — это сторонняя служба.

### 8. hyperion-cs/dpi-checkers

`dpi-ch` (Go) и браузерные чекеры. Классификация:

* cidr-whitelist: `max.ru/ya.ru/vk.ru` против `github/google` — «нет
  блокировки / только whitelist / нет интернета»;
* webhost: TLS-handshake, повтор с SNI `cf.com`/`google.com`, alive,
  l4-25 (POST 64 КБ), «siberian» (случайные SNI), throughput;
* DNS: leak, plain, DoH, hijacking, spoofing, bootstrap.

Ценность: готовый словарь состояний и порядок проверок. В 0.19.0 перенесена
только практическая часть — `youtube_audit` (веб/превью/API/CDN + маршрут) и
`doctor` (backend, правила, исключения). Полный порт Go-чекера не делали;
QUIC/STUN/WireGuard в dpi-checkers, вопреки ожиданию, отсутствуют.

### 9. Leadaxe/LxBox

Это **Android-клиент** на Flutter с форком sing-box, не роутер и не образ.
Эталонные техники: `tls.fragment`, `tls.record_fragment`, mixed-case SNI,
uTLS-отпечатки, REALITY/ECH, XHTTP, AmneziaWG 2.0, Hysteria2, TUIC,
AnyTLS; urltest/least_test/round_robin, DNS-группы, FakeIP, debug API.

Взято: идеи health-check и mixed-case SNI (последнее — как кандидат в Lua).
Код не переносим: другая платформа и ядро.

### 10. steer (splify2/steer) — контекст

`spec-v2.md`: списки `domains_file`/`prefixes_file`/`srs`, правила
`to`/`out`/`resolve`, порядок правил, `on_fail: direct`. `ctl.md`:
`steer explain <домен>`, `steer reload`, `status`, `apply`.

Именно это позволило сделать исключения без nft-хаков: пишем домены в
`exclude.lst`, правило `zm_excl` уже первое, `reload` перечитывает файлы.
Если `zm_excl` в spec нет — автоматический откат на nft.

## Эталонные варианты, выбранные для YouTube

1. **Yv01 (Flowseal)** — `multisplit:pos=1:seqovl=681` с реальным
   ClientHello `www.google.com`, `ip_id=zero`. Самый универсальный.
2. **Yv02** — `multisplit:pos=1,sniext+1:seqovl=1` (лёгкий, быстрый).
3. **Yv26** — `multidisorder` по
   `1,sniext+1,host+1,midsld-2,midsld,midsld+2,endhost-1`.
4. **Yv05** — `fake:0x0F0F0F0F:badsum` + `multisplit:pos=2,sld:seqovl=620`.
5. **Yv08/29** — `hostfakesplit:host=www.google.com:tcp_ts=-600000`.
6. **TCP MD5 + autottl** — `fake:tcp_md5:repeats=6`, `ip_autottl=-2,3-20`.
7. **QUIC** — reject с быстрым ICMP (наш `quic_mode auto`), fake QUIC
   initial — как альтернатива, если QUIC нужен.

Все они добавлены в корпус подбора и в профиль YouTube по умолчанию (через
`circular`, чтобы при деградации одной связки включалась следующая).

## Что добавлено уникального

* **Разделение «домены обхода» и «домены маршрута».** Раньше исключения
  строились по hostlist’ам стратегий: `list_hosts_youtube` содержит
  `google.com`, `googleapis.com`, `gstatic.com` — это выводило из туннеля
  весь Google, включая Gemini. Теперь `route/youtube.lst` — только путь
  YouTube, а Gemini остаётся в туннеле.
* **Починен сбор доменов.** `YTApi` использует hostlist `hl_ytapi`, а старый
  код брал только `list_hosts_*`, поэтому `youtubei.googleapis.com` вообще
  не исключался. Это одна из причин «YouTube работает, а приложение нет».
* **Вставка nft-правила до маркировки**, а не в начало цепочки: фильтры
  оркестратора сохраняются. Проверено в netns: правило стоит между
  `iifname` и `meta mark set`.
* **IPv6** для nft-исполнения: `bcw_route6`, `ip6 daddr`, AAAA-резолв.
* **Проверка решения steer** через `steer explain`, а не «правило есть —
  значит работает».
* **`youtube_audit`** — четыре точки (веб, превью, API, CDN) + маршрут, с
  конкретной подсказкой (`fix_ytapi`, `rescan_youtube`, `route_enable`).
* **Подбор не врёт**: steer временно выключается, иначе «рабочая» стратегия
  — это туннель, а не обход.
* **Сторож без полного `nft list ruleset` каждые 8 секунд** — меньше CPU на
  слабых роутерах.
* **Маршрут включается только явно.** `route_enabled` (галочка в карточке
  LuCI или `bypass enable`) — единственный способ его включить: `init`,
  hotplug и cron делают `bypass_sync sync` и уважают выключенное состояние.
  Старые установки со строкой `bypass_sync enable` в crontab переписываются
  на `sync` при первом же вызове, а обновление с 0.18.x (где переключателя
  не было) включает маршрут один раз, если остался старый блок в
  `exclude.lst` или `bypass_state.txt`.
* **Селектор backend в карточке LuCI** — авто / steer / nft. Переключение
  снимает ставший лишним блок из `exclude.lst` или nft-правила, чтобы не
  было двух источников правды; карточка остаётся доступной и при выключенном
  маршруте (`available` в `bypass status`), иначе галочку было бы не вернуть.

## Что осталось за рамками (честный roadmap)

| Пробел | Почему | Что нужно |
|---|---|---|
| `tlsrec` (разбиение ClientHello на TLS-записи) | в zapret2 нет готовой функции | отдельная Lua-функция + blob’ы |
| mixed-case SNI/Host | нет в zapret2 | Lua-модификация ClientHello/HTTP |
| per-IP кэш стратегий как в byedpi `--auto` | у нас кэш по ASN/сервису | таблица IP→genome, TTL |
| полный dpi-ch (cidr/siberian/DNS) | Go-бинарь, большой | порт ключевых проверок в shell |
| fake QUIC по умолчанию | реализован как `quic_mode=fake`; по умолчанию остаётся `auto` | включать после проверки на своём провайдере |

## Проверка

* `busybox ash -n` для helper, init, uci2config — без ошибок.
* Unit-тест в `unshare -n`: таблица `inet steer` с `prerouting_mark` и
  `ingress_mark`; проверено, что `bcw-route` стоит до `mark set`, IPv4 и
  IPv6 элементы на месте, `bypass disable` удаляет правила и наборы.
* Steer-тест: управляемый блок добавляется, чужая запись `mybank.ru`
  сохраняется, `disable` снимает только блок.
* Bundle 0.19.0 собирается, helper/config/version внутри; `.ipk` собирается
  из того же дерева (`packaging/build-ipk.sh`), `control`/`conffiles` на месте,
  `nfqws2` внутри.
* Тесты лежат в репозитории и гоняются в CI (job `openwrt-scripts`):
  `tools/test_route_engine.sh` (netns, `sudo unshare -n sh ...`),
  `tools/test_quic_mode.sh`, `tools/test_netcheck.sh`. Route-тест проверяет и
  гейт включения: `sync` при `route_enabled=0` ничего не применяет,
  `enable` пишет UCI и ставит блок, `disable keep` снимает блок, но не гасит
  переключатель.

## Ссылки

* https://github.com/bol-van/zapret
* https://github.com/remittor/zapret-openwrt
* https://github.com/StressOzz/Zapret-Manager
* https://github.com/Flowseal/zapret-discord-youtube
* https://github.com/hufrea/byedpi
* https://github.com/DPITrickster/ByeDPI-OpenWrt
* https://github.com/IndeecFOX/zapret4rocket
* https://github.com/hyperion-cs/dpi-checkers
* https://github.com/Leadaxe/LxBox
* https://github.com/splify2/steer
