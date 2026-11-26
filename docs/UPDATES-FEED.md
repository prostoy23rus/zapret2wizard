# Репозиторий пакетов (feed)

CI автоматически публикует индексы пакетов в ветку **`feed`** при каждом теге `v*`.
Это позволяет обновлять Zapret2Wizard штатными средствами OpenWrt, а не скачиванием файлов вручную.

База: `https://raw.githubusercontent.com/prostoy23rus/zapret2wizard/feed`

Для apk указывается база `.../feed/apk` — apk сам добавляет каталог архитектуры;
для opkg путь включает архитектуру явно (`.../feed/opkg/<arch>`).

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

## OpenWrt 25.x / apk (подписанный индекс)

Сначала установите публичный ключ (один раз):
```sh
mkdir -p /etc/apk/keys
wget -O /etc/apk/keys/zapret2wizard-apk.pem \
  "https://raw.githubusercontent.com/prostoy23rus/zapret2wizard/main/release-keys/zapret2wizard-apk.pem"
```

Затем добавьте **прямую ссылку на подписанный `packages.adb`** (архитектура — из `DISTRIB_ARCH`):
```sh
ARCH=$(grep DISTRIB_ARCH /etc/openwrt_release | cut -d\' -f2)
echo "https://raw.githubusercontent.com/prostoy23rus/zapret2wizard/feed/apk/$ARCH/packages.adb" \
  >> /etc/apk/repositories
apk update
apk add --upgrade zapret2wizard
```

Почему не `--allow-untrusted`: индекс `packages.adb` подписан EC-ключом
(SHA256 публичного ключа: `3983f89f80d9168ec822c0721b72d48dd7d60b97103bd8eedb0e649431f5dbe1`), apk проверяет подпись индекса;
пакеты проверяются по хешам из индекса. Если ключ не установлен или feed
собран без секрета, apk потребует `--allow-untrusted`.

`.apk`-файлы в feed лежат под каноническими именами `<name>-<version>.apk`.

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

- APKINDEX/packages.adb подписывается при наличии секрета `APK_SIGN_KEY`; публичный ключ — `release-keys/zapret2wizard-apk.pem`;
- feed собирается только на теги, промежуточные push в `main` туда не попадают;
- одна версия на архитектуру: обновление идёт «вперёд», откат — вручную из релиза;
- перед обновлением службы с активным подбором дождитесь завершения (или остановите поиск).
