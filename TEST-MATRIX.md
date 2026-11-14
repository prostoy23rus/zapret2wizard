# Матрица проверок 0.36.5

Проверки выполнены на реальных роутерах после чистых пакетных установок.
Тестовые данные не заменяют проверки на других провайдерах.

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

- `arm_cortex-a7` и `x86_64` на реальном железе;
- второй провайдер;
- чистый `.apk` на роутере без уже установленных зависимостей;
- IPv6-сеть (сейчас baseline рассчитан на IPv4-only).
