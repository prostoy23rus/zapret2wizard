# Baseline Zapret2Wizard 0.36.5

Зафиксированная точка после пакетной установки: .ipk на OpenWrt 24.10.5
и .apk на OpenWrt 25.12. Это основной baseline для ремонта.

## Что зафиксировано

| Параметр | Значение |
|---|---|
| Версия | 0.36.5 |
| Исходный тег | v0.36.5 |
| Исходный коммит | 557af5d |
| Тег baseline | v0.36.5-baseline |
| Ветка | stable/v0.36.5 |
| Снимок | /etc/zapret2wizard/baseline-0.36.5 |
| Предыдущие baseline | 0.36.3, 0.36.0 |

## Пакеты

| Пакет | Платформа | Проверка |
|---|---|---|
| luci-app-blockcheckw_0.36.5-1_aarch64_cortex-a53.ipk | 24.10.5 | чистая установка |
| zapret2wizard_0.36.5-r1_aarch64_cortex-a53.apk | 25.12 | upgrade/установка |

В релизе v0.36.5 есть SHA256SUMS. Checksums проверены:

```
luci-app-blockcheckw_0.36.5-1_aarch64_cortex-a53.ipk: OK
zapret2wizard_0.36.5-r1_aarch64_cortex-a53.apk: OK
```

## Эталонная диагностика

```
версия:       0.36.5
движки:       3
nft-таблица:  1
стратегий:    4
DNS:          ok
ping:         ok
```

Exact client probes после чистой установки .ipk на 24.10.5:

| Сервис | output | netns |
|---|---|---|
| YouTube | 200, 878109 | 200, 881027 |
| Discord | 200, 77711 | 200, 77739 |
| Instagram | 200, 390814 | 200, 390815 |

На домашнем 25.12 после .apk:

| Сервис | результат |
|---|---|
| YouTube | 200, 885359 |
| Discord | 200, 77739 |
| Instagram | 200, 390862 |

## Что вошло в baseline

- устойчивый Discord edge 162.159.136.232;
- postinst .ipk/.apk ждёт nfqws2/nft, применяет DNS-пины и проверяет DNS;
- lock для safe_dns_restart;
- checksums в релизе;
- чистые установки пакетов проверены.

## Ремонт

1. Проверить снимок:

```sh
cd /etc/zapret2wizard/baseline-0.36.5
sha256sum -c SHA256SUMS
```

2. Восстановить службу (Wi-Fi/WAN/DNS не трогаются):

```sh
sh /usr/share/zapret2wizard/baseline_restore.sh /etc/zapret2wizard/baseline-0.36.5
```

3. Проверить:

```sh
/usr/bin/blockcheckw-helper selftest
```

4. Если пакет повреждён — установить .ipk/.apk версии 0.36.5 из релиза,
   затем повторить restore.

## Правила

- baseline_restore не меняет сеть и DNS;
- старые baseline 0.36.3/0.36.0 сохранены на диске;
- новые эксперименты начинать только со снимка.