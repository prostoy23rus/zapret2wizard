# Сборка и установка пакетов

Проект собирается в два формата:

| Формат | Для чего | Ограничения |
|---|---|---|
| `dist/zapret2wizard-<ver>-<arch>-bundle.tar.gz` | **универсальный**: OpenWrt 21–25, opkg и apk, офлайн | нужен `tar` и `sh` (есть всегда) |
| `dist/luci-app-blockcheckw_<ver>-1_<arch>.ipk` | штатный opkg | не ставится на прошивки с «abpkg» (например RouteRich) |

Оба содержат **всё внутри**: LuCI-приложение, helper, сканер `blockcheckw`,
движок `nfqws2`, конфиг, init-скрипт, Lua-модули, fake-блобы и списки доменов.
Интернет при установке не нужен.

## Автономный бандл (рекомендуется)

```sh
cd /tmp
# ссылку на bundle берите со страницы последнего релиза
wget -O bcw.tgz "https://github.com/prostoy23rus/zapret2wizard/releases/latest/download/zapret2wizard-<версия>-<арх>-bundle.tar.gz"
tar -xzf bcw.tgz
cd zapret2wizard-*
sh install.sh
```

Скрипт распаковывает payload, копирует файлы, чинит права, создаёт симлинки,
включает автозапуск, перезапускает службу и печатает результат `doctor`.
Существующий `/etc/config/zapret2wizard` со стратегиями **не перетирается**.

## Сборка бандла

```powershell
python packaging\build.py --arch aarch64_cortex-a53 `
  --engine openwrt\engine\nfqws2-linux-arm64 `
  --scanner ..\deepseek\build\blockcheckw-aarch64 --out dist
```

## Сборка .ipk (штатный opkg)

Выполняется в Linux (WSL), нужен `ar` из binutils:

```bash
bash packaging/build-ipk.sh aarch64_cortex-a53 \
  openwrt/engine/nfqws2-linux-arm64 \
  /mnt/e/deepseek/build/blockcheckw-aarch64 dist
```

Установка на роутере:

```sh
opkg install --force-overwrite /tmp/luci-app-blockcheckw_<ver>-1_<arch>.ipk
```

## Архитектуры

Движки лежат в `openwrt/engine/` для `arm64`, `arm`, `x86_64`, `mips`,
`mipsel`, `mips64`, `riscv64`, `ppc`. Сканер `blockcheckw` собирается из
исходников — см. `docs/BUILD-AARCH64.md`; готовый бинарник нужен под каждую
архитектуру отдельно (для aarch64 он собирается в WSL).

## Пакет .apk (OpenWrt 25.x)

Формат apk v3 нельзя собрать вручную — его создаёт `apk mkpkg` из apk-tools 3.
В прошивке этого applet-а нет, поэтому сборка идёт на хосте:

```sh
# 1. собрать apk-tools 3 (один раз)
git clone -q --depth 1 --branch v3.0.5 https://github.com/alpinelinux/apk-tools.git
cd apk-tools && make -j4     # нужны gcc, zlib1g-dev, libssl-dev, libzstd-dev, lua5.3

# 2. собрать пакет из готового бандла
APK_BIN=$PWD/src/apk LD_LIBRARY_PATH=$PWD/src \
  sh packaging/build-apk.sh \
    --bundle dist/zapret2wizard-<версия>-<арх>-bundle.tar.gz --out dist
```

Установка:

```sh
scp -O dist/zapret2wizard_<версия>-r1_<арх>.apk root@РОУТЕР:/tmp/
ssh root@РОУТЕР 'apk add --allow-untrusted /tmp/zapret2wizard_<версия>-r1_<арх>.apk'
```

`/etc/config/zapret2wizard` объявлен conffiles: при обновлении сохраняется как `.apk-new`, стратегии не теряются.

## Проверка совместимости (preflight)

`packaging/preflight.sh` запускается установщиком бандла и проверяет прошивку,
архитектуру, nftables и nfqueue, procd/ubus, RAM (>= 60 МБ), место (>= 3 МБ),
curl/wget, apk/opkg и чужие движки DPI (свои не считаются). Фатальные проблемы
останавливают установку, предупреждения — нет.

## CI

`.github/workflows/build.yml` собирает `blockcheckw` под 6 архитектур
(aarch64, armv7, x86_64, mips, mipsel, riscv64), затем бандл и `.apk` для каждой,
артефакты прикрепляются к релизу.

## Сборка под mips / mipsel / mips64 / riscv64

Для этих целей в Rust stable **нет готового `rust-std`** (`component 'rust-std' ... is unavailable`),
поэтому обычный `cargo build --target` не работает. Варианты:

```sh
# 1. через cross (Docker)
cargo install cross
cross build --release --target mips-unknown-linux-musl
cross build --release --target mipsel-unknown-linux-musl
cross build --release --target riscv64gc-unknown-linux-musl

# 2. через свой musl-toolchain (как в docs/BUILD-AARCH64.md)
```

Готовые бинарники для этих архитектур в CI не собираются автоматически: матрица
workflow ограничена aarch64/armv7/x86_64, где `rust-std` доступен. Движки `nfqws2`
для всех восьми архитектур лежат в `openwrt/engine/`.
