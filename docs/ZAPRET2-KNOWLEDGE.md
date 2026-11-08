# Справочник по zapret2 (краткая выжимка)

Скилл с рабочими правилами: [`skills/zapret2-desync/SKILL.md`](../skills/zapret2-desync/SKILL.md).

## Источники

| Что | Ссылка |
|---|---|
| Официальное руководство zapret2 | <https://raw.githubusercontent.com/bol-van/zapret2/refs/heads/master/docs/manual.md> |
| Архив статей (llms-full) | <https://jzesawgjsz.zapret.moe/llms-full.txt> |
| Гайд по настройке | <https://zapret2-guide.pages.dev/> |
| Тест «класс ТСПУ» | <https://github.com/saitkul/tspu-class-test> |

## Что взято из руководства и применено в пресетах

| Приём | Аргументы | В пресетах с версии |
|---|---|---|
| `tcpseg` | `pos=midsld:seqovl=1`, `pos=1,sniext+1` | 0.18.25 |
| `fakedsplit` | `pos=midsld:seqovl=1` | 0.18.25 |
| `hostfakesplit` + `midhost` | `host=vk.com:midhost=midsld` | 0.18.25 |
| `rst` + `rstack` | `rst:rstack:ip_autottl=-2,3-20` | 0.18.25 |
| `syndata` + `tcp_ts_up` | `syndata:blob=fake_default_tls:tcp_ts_up` | 0.18.25 |
| `multidisorder` + `seqovl` | `pos=host+1,midsld:seqovl=1` | 0.18.25 |
| `multidisorder:pos=sld` | — | 0.18.23 |
| Чистый `fake` | `fake:blob=fake_default_tls:tcp_md5:repeats=6` | 0.18.23 |

## Правила, которые нельзя нарушать

1. Применять только стратегию, прошедшую полную загрузку (до 256 КБ), а не короткую пробу.
2. На время подбора останавливать службу — иначе её правила искажают результат.
3. `nfqws2` работает от `daemon`: каталоги `755`, файлы списков `644`.
4. `flow offloading` выключен, иначе пакеты идут мимо nfqueue.
5. Circular-стратегия — многострочный файл, строки склеивать перед применением.
6. Перед публикацией новой стратегии проверять `nfqws2 --dry-run`.

## Диагностика

```sh
blockcheckw-helper doctor     # окружение и движки
blockcheckw-helper selftest   # живая проверка сервиса
blockcheckw-helper class      # какие семейства desync пропускает ТСПУ
```
