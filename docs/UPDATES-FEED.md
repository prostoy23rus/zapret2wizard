# Репозиторий пакетов (feed)

CI автоматически публикует индексы пакетов в ветку **`feed`** при каждом теге `v*`.
Это позволяет обновлять Zapret2Wizard штатными средствами OpenWrt, а не скачиванием файлов вручную.

База: `https://raw.githubusercontent.com/prostoy23rus/zapret2wizard/feed`

Архитектуры: `aarch64_cortex-a53`, `arm_cortex-a7`, `x86_64` (те же, что в релизах).

## OpenWrt 24.10 и старше (opkg)

```sh
ARCH=$(opkg print-architecture | awk '{print $2}' | grep -v -E "all|noarch" | head -1)
echo "src/gz zapret2wizard https://raw.githubusercontent.com/prostoy23rus/zapret2wizard/feed/opkg/$ARCH" \
  >> /etc/opkg/customfeeds.conf
opkg update
opkg install luci-app-blockcheckw     # первая установка
opkg upgrade luci-app-blockcheckw     # обновление
```

## OpenWrt 25.x / apk

```sh
ARCH=$(apk --print-arch)
echo "https://raw.githubusercontent.com/prostoy23rus/zapret2wizard/feed/apk/$ARCH" \
  >> /etc/apk/repositories
apk update
apk add --allow-untrusted --upgrade zapret2wizard   # первая установка/обновление
# или: apk upgrade --allow-untrusted zapret2wizard
```

Почему `--allow-untrusted`: индекс и пакеты пока **не подписаны**. Это следующий шаг;
пока целостность проверяется по `SHA256SUMS` в ветке `feed` и релизным артефактам.
Ставьте feed только если понимаете разницу между «скачал с GitHub» и «доверяю ключу».

## Проверка и откат

```sh
sha256sum -c <(wget -qO- https://raw.githubusercontent.com/prostoy23rus/zapret2wizard/feed/SHA256SUMS) 2>/dev/null || true
blockcheckw-helper info
blockcheckw-helper test preset_youtube
```

Если обновление не подошло — переустановите пакет/бандл нужной версии со страницы релиза
или верните конфигурацию через «История»/`.last_good_config` (она сохраняется).

## Как это устроено

- `.github/workflows/build.yml`, job `feed`: после сборки пакетов на тег генерирует
  `opkg/<arch>/Packages` и `apk/<arch>/APKINDEX.tar.gz` скриптом `packaging/build-feed.py`;
- индексы и пакеты пушатся в ветку `feed` (force-push, там только артефакты);
- `SHA256SUMS` и `index.json` лежат в корне ветки;
- архитектура и версия определяются из имён артефактов, ничего вручную заполнять не нужно.

## Ограничения

- пакеты не подписаны (см. выше);
- feed собирается только на теги, промежуточные push в `main` туда не попадают;
- одна версия на архитектуру: обновление идёт «вперёд», откат — вручную из релиза;
- перед обновлением службы с активным подбором дождитесь завершения (или остановите поиск).
