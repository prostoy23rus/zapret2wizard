# Baseline Zapret2Wizard 0.36.3

Зафиксированная рабочая точка после чистых установок на OpenWrt 24.10.5
и 25.12. Это новый baseline для ремонта.

## Что зафиксировано

| Параметр | Значение |
|---|---|
| Версия | 0.36.3 |
| Исходный тег | v0.36.3 |
| Исходный коммит | 01516e7 |
| Тег baseline | v0.36.3-baseline |
| Ветка | stable/v0.36.3 |
| Снимок | /etc/zapret2wizard/baseline-0.36.3 |
| Предыдущий baseline | 0.36.0 (v0.36.0-baseline) |

## Эталонная диагностика

```
версия:            0.36.3
платформа:         aarch64
служба:            работает
движки nfqws2:     3
nft-таблица:       1
стратегий:         4
lua-модулей:       7
fake-блобов:       56
доменов:           1079-1080
YouTube:           optimal, 200
ya.ru:             302
```

## Чистая установка

### Домашний роутер, OpenWrt 25.12, aarch64

- установка с нуля без service/config: успешно;
- DNS и интернет работают;
- client_probe: YouTube 985020, Discord 77739, Instagram 390814 байт;
- PC: YouTube играет, Discord 200;
- netns: не проверен (нет kmod-veth) — output-проверки достаточно.

### Удалённый роутер, OpenWrt 24.10.5, aarch64

- чистая установка: успешно;
- client_probe: YouTube 982681, Discord 77711, Instagram 390548 байт;
- client_probe_netns: YouTube 881573, Discord 77739, Instagram 390397 байт;
- все три сервиса — HTTP 200.

## Что исправлено до baseline

- цикл restart `ensure_ytapi` при старте;
- ожидание готовности nfqws2/nft в установщике;
- проверка DNS и откат конфигурации при сбое;
- lock для одновременных `safe_dns_restart`;
- явные DNS-пины Discord/Instagram до финальной проверки.

## Ремонт

1. Проверить снимок:

```sh
cd /etc/zapret2wizard/baseline-0.36.3
sha256sum -c SHA256SUMS
```

2. Восстановить службу (Wi-Fi/WAN/DNS не трогаются):

```sh
sh /usr/share/zapret2wizard/baseline_restore.sh /etc/zapret2wizard/baseline-0.36.3
```

3. Проверить:

```sh
/usr/bin/blockcheckw-helper selftest
```

Ожидается 0.36.3, 3 движка, таблица 1, YouTube 200.

4. Если helper/init повреждены — переустановить из тега `v0.36.3`,
   затем повторить restore.

## Правила

- baseline_restore не меняет Wi-Fi, WAN, firewall и DNS-конфиг;
- не создавать baseline на сломанном состоянии;
- новые эксперименты — только после снимка;
- предыдущий baseline 0.36.0 остаётся на диске и в тегах.