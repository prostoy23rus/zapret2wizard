# Прямой маршрут: YouTube и другие сервисы мимо туннеля

Это замена «исключениям ZeroBlock» для роутеров, где маршрутизацией
занимается **steer** (Zapret Manager), mihomo, sing-box, v2rayA или свой
nft-скрипт. Никаких сторонних служб и API: только локальные списки,
локальный dnsmasq и родные механизмы оркестратора.

## Зачем это нужно

`zapret2wizard` обходит DPI только для трафика **без метки туннеля**. Если
steer заворачивает `youtube.com` в `zm_vpn`, обход простаивает: пакеты уже
помечены и ушли в туннель. Хуже того, часть запросов идёт напрямую, часть
через туннель — YouTube видит разные IP и теряет регион, а Shorts/превью
грузятся рывками.

Правильная схема: **домены, которые обслуживает служба, идут напрямую**,
их режет zapret; остальное (Gemini, банки, геоблок) остаётся в туннеле.

## Два исполнения

### 1. steer — родные исключения (основной путь)

steer уже умеет то, что нужно: вкладка **«Исключения»**, файл
`/etc/zm-steer/user/exclude.lst`, правило `zm_excl` стоит первым в
`/etc/steer/spec.json` и ведёт в `zm_direct`.

Служба добавляет в этот файл управляемый блок:

```
# >>> zapret2wizard direct (managed)
youtube.com
googlevideo.com
youtubei.googleapis.com
...
# <<< zapret2wizard direct (managed)
```

Почему домены, а не IP:

* работают и IPv4, и IPv6, и QUIC, и клиенты с DoH;
* не нужно угадывать CDN-адреса `googlevideo`;
* перезапуск steer и `reload` firewall ничего не ломают — список лежит в
  пользовательском файле, а не в nft-таблице;
* правки пользователя (банки, госуслуги) сохраняются: блок снимается по
  маркерам, остальные строки не трогаются;
* выключение запоминается: `bypass disable` пишет `route_enabled=0`, и
  `init`/hotplug/cron (они вызывают `bypass_sync sync`) больше не возвращают
  правила — маршрут включается только явной командой или галочкой.
  Исключение одно: при обновлении с 0.18.x, где переключателя не было,
  маршрут включается один раз автоматически, если остался хоть один признак
  старого поведения — nft-правила `bcw-bypass`, старая cron-строка
  `bypass_sync enable`, файл `bypass_state.txt` или наш блок в
  `exclude.lst`; иначе исключения пропали бы молча;

После записи служба делает `steer reload` в фоне и проверяет решение через
`steer explain <домен>` (ожидается `zm_direct`). Результат виден в
`bypass status` (`"verified":true`).

### 2. nft-оркестратор — return до маркировки (запасной путь)

Если steer нет или в его spec нет `zm_excl`, служба ищет таблицы, где есть
`mark set`, и в base-цепочке (`hook prerouting`/`ingress`) ставит правило
**перед первой маркировкой**:

```
ip  daddr @bcw_route4 counter return comment "bcw-route"
ip6 daddr @bcw_route6 counter return comment "bcw-route"
```

Не в начало цепочки, а именно перед `mark set` — поэтому фильтры
интерфейсов и адресов, которые оркестратор ставит раньше, продолжают
работать. Наборы заполняются адресами из локального dnsmasq (A + AAAA) и
статическими IP/CIDR из `user.lst`.

Сторож проверяет только свои цепочки (не весь ruleset), пересматривает
цели раз в 10 минут и пересобирает правила, если оркестратор пересоздал
таблицу.

## Команды

```sh
blockcheckw-helper bypass enable      # применить (backend определится сам)
blockcheckw-helper bypass status      # backend, домены, правила, счётчики
blockcheckw-helper bypass domains     # что именно идёт напрямую
blockcheckw-helper bypass verify      # steer explain / покрытие nft-наборов
blockcheckw-helper bypass rebuild     # пересобрать IP-кэш и правила
blockcheckw-helper bypass disable     # вернуть домены в туннель
blockcheckw-helper bypass backend auto|steer|nft   # принудительно выбрать backend

blockcheckw-helper youtube_audit      # веб + превью + API + CDN + маршрут
blockcheckw-helper route explain www.youtube.com   # решение steer
```

То же из LuCI: карточка **«Обход туннелей»** на главной. Для steer она
показывает «доменов напрямую» и результат проверки, для nft — правила/IP.
Кнопка **«Проверить YouTube»** на карточке запускает `youtube_audit`.

## Настройки (UCI)

```sh
uci set zapret2wizard.main.route_enabled=1      # включает маршрут (по умолчанию 0)
uci set zapret2wizard.main.route_backend=auto   # auto | steer | nft
uci set zapret2wizard.main.route_services='youtube discord'
uci set zapret2wizard.main.route_steer_ips=0    # 1 — добавить и IP в exclude.pfx
uci set zapret2wizard.main.route_extra='example.com 1.2.3.0/24'
uci commit zapret2wizard
```

* `route_enabled=0` по умолчанию: маршрут правит чужой `exclude.lst` и
  nft-таблицы, поэтому сам не включается ни при старте, ни по cron. Галочка в
  карточке LuCI делает то же, что `bypass enable`.
* `route_backend=auto` — steer, если он есть и в spec есть `zm_excl`,
  иначе nft.
* `route_services` — какие сервисы выводить. По умолчанию определяется по
  включённым стратегиям (`BlockcheckW_YouTube`, `YTApi`, Discord и т.д.).
  `none` — только `user.lst`.
* `route_steer_ips=1` — дополнительно закрепить IP в `exclude.pfx`. Нужно
  только упрямым приложениям, которые ходят по IP/DoH; по умолчанию
  выключено, чтобы не задеть соседние сервисы на общих адресах Google.
* `route_extra` — добавить домены/IP без редактирования файлов.

Свои домены и подсети — `/etc/zapret2wizard/route/user.lst`
(по одному в строке, `#` — комментарий, поддомены включаются сами).

## Что где лежит

| Путь | Назначение |
|---|---|
| `/etc/zapret2wizard/route/*.lst` | встроенные списки сервисов (перезаписываются при обновлении) |
| `/etc/zapret2wizard/route/user.lst` | ваши домены/IP (не перезаписывается) |
| `/etc/zapret2wizard/route_domains.txt` | итоговый список после фильтра исключений |
| `/etc/zapret2wizard/route_state.txt` | цепочки, куда поставлены nft-правила |
| `/etc/zapret2wizard/route_backend` | `steer`, `nft` или `none` |
| `/etc/zm-steer/user/exclude.lst` | родной список исключений steer (наш блок внутри) |
| `/tmp/bcw_route.log` | журнал применения |
| `/tmp/bcw_route_verify.json` | последний результат проверки |

## Откат

```sh
blockcheckw-helper bypass disable
```

Снимает управляемый блок из `exclude.lst`/`exclude.pfx`, удаляет nft-правила
и наборы, возвращает домены в туннель. Резервная копия файла steer —
`exclude.lst.bcw.bak` (создаётся один раз).

## Ограничения

* steer может перегенерировать `spec.json` из панели. Список
  `exclude.lst` при этом сохраняется, а сторож переприменяет блок, если
  файл изменили. Если панель убрала само правило `zm_excl` — служба
  переключится на nft-исполнение.
* Домены в `srs`-списках steer по IP не разворачиваются; для YouTube это не
  нужно, там обычные домены.
* `route_steer_ips=1` может вывести из туннеля соседний сервис на общем
  адресе Google. Включайте осознанно.
* Возврат в туннель уже открытых вкладок — перезагрузка страницы или
  `bypass disable/enable`; conntrack служба не чистит намеренно, чтобы не
  рвать просмотр.
