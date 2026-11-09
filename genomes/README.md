# Каталог геномов

Готовые рабочие комбинации техник по провайдерам (ASN).

- `AS<номер>.json` — геномы для конкретного провайдера, формат совместим с экспортом из вкладки «Эволюция».
- `index.json` — сводка: какие ASN есть, сколько геномов, когда обновлено.

## Забрать геномы для своего провайдера

```sh
blockcheckw-helper catalog_fetch            # ASN определится сам
blockcheckw-helper catalog_fetch AS25490    # или вручную
```

Или кнопка «🌐 Каталог по ASN» на вкладке «Эволюция».

## Поделиться своими

1. Вкладка «Эволюция» → «⬇ Экспорт геномов» (файл `bcw-genomes-<ASN>.json`).
2. Положите его в `genomes/AS<ваш ASN>.json`.
3. Обновите `index.json` (можно не вручную — принимается и просто файл).
4. Сделайте Pull Request в репозиторий.

Импорт сливает геномы по хешу аргументов: дубли не появляются, берутся лучшие
показатели `ok` / `best` / `stability`.

## Что внутри

```json
{
  "schema": 1,
  "generator": "zapret2wizard",
  "asn": "AS25490",
  "provider": "AS25490 OJSC Southern Telecommunications Company, Krasnodar Krai, RU",
  "count": 3,
  "genomes": [
    {"args": "--payload=tls_client_hello --lua-desync=...", "ok": 6, "stability": 100, "best": 872411}
  ]
}
```
