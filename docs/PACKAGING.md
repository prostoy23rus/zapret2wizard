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
wget -O bcw.tgz "https://raw.githubusercontent.com/prostoy23rus/zapret2wizard/main/dist/zapret2wizard-0.18.9-aarch64_cortex-a53-bundle.tar.gz"
tar -xzf bcw.tgz
cd zapret2wizard-0.18.9-aarch64_cortex-a53
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
