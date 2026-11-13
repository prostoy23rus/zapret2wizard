# Baseline Zapret2Wizard 0.36.0

Это зафиксированная рабочая точка для ремонта. Новые изменения проверяются
рядом; baseline обновляется только после полной матрицы.

## Что зафиксировано

| Параметр | Значение |
|---|---|
| Версия | 0.36.0 |
| Исходный тег | v0.36.0 |
| Исходный коммит | 4bd8739 |
| Тег baseline | v0.36.0-baseline |
| Ветка | stable/v0.36.0 |
| Снимок на роутере | /etc/zapret2wizard/baseline-0.36.0 |
| Создать снимок | /usr/share/zapret2wizard/baseline_snapshot.sh |
| Восстановить | /usr/share/zapret2wizard/baseline_restore.sh |

## Эталонная диагностика успешной установки

У пользователя с пакетной установкой:

```
версия:            0.36.0
платформа:         aarch64
служба:            работает
движки nfqws2:     3
nft-таблица:       1
стратегий:         2
доменов:           1080
YouTube:           optimal, 200, 981742 байта
ya.ru:             302
```

Сообщения `procd: Failed to remove pidfile` нефатальны. Строка
`оставлены только YouTube и Discord` относится к старой конфигурации;
при включённом Instagram дальше видны его DNS-пины.

## Чем подтверждён baseline

- Домашний роутер 25.12 aarch64: YouTube/Discord/Instagram, 3 движка.
- Удалённый роутер 24.10.5 aarch64:
  - client_probe: YouTube 880597, Discord 77739, Instagram 390776 байт;
  - client_probe_netns: YouTube 984337, Discord 77711, Instagram 390589 байт.
- Пакетная установка пользователя: YouTube 200, 981742 байта.

Известный дефект: установка на 24.10.5 может временно сломать DNS;
после установки нужен контроль DNS/откат. Сам baseline на 24.10 рабочий.

## Снимок

Снимок включает `/etc/config/zapret2wizard`, `.last_good_config`,
helper, init, `main.js`, `version.json`, hostlists и `SHA256SUMS`.

Создавать только после успешной проверки:

```sh
sh /usr/share/zapret2wizard/baseline_snapshot.sh
```

## Ремонт из baseline

1. Проверить снимок:

```sh
ls /etc/zapret2wizard/baseline-0.36.0
cd /etc/zapret2wizard/baseline-0.36.0 && sha256sum -c SHA256SUMS
```

2. Восстановить службу (сеть и DNS не трогаются):

```sh
sh /usr/share/zapret2wizard/baseline_restore.sh /etc/zapret2wizard/baseline-0.36.0
```

3. Если helper/init повреждены — переустановить 0.36.0 из тега `v0.36.0`,
   затем повторить restore.

4. Проверить:

```sh
/usr/bin/blockcheckw-helper selftest
```

Ожидается 0.36.0, 3 движка, таблица 1, YouTube 200.

5. Если служба не поднимается — проверить WAN/DNS, затем:

```sh
/usr/bin/blockcheckw-helper restore_good
```

## Правила

- baseline_restore не меняет Wi-Fi, WAN, firewall и DNS-конфиг;
- не сохранять baseline на сломанном состоянии;
- новые эксперименты — только после копии текущего baseline;
- не перезаписывать baseline без полной проверки.