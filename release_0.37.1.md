# Release 0.37.1 — Hotfix: страница не открывалась

**Дата:** 2026-11-21  
**Приоритет:** КРИТИЧЕСКИЙ (0.37.0 ломала интерфейс)

## Что было сломано

После 0.37.0 страница Zapret2Wizard в LuCI не открывалась:

```
ReferenceError
startTspuClass is not defined
```

Причина: функции карточки «Класс ТСПУ» (`fmtTspuResult`, `loadTspuReport`,
`startTspuClass`, `loadCanaryStatus`, `toggleCanary`) были вставлены внутри
тела функции `pluralRu()`, а не в области видимости `render()`. DOM-кнопки
карточки ссылались на эти функции, `render()` падал на этапе построения UI,
LuCI показывал вечную «Загрузка страницы...».

Исправление: блок функций перенесён в область видимости `render()` (рядом с
DOM-блоком карточки). Проверено парсером acorn — все 5 функций теперь прямые
потомки `render`.

## Второй найденный разрыв: самообновление

`cmd_update` обновлял только 6 файлов. При обновлении через кнопку
«Проверка обновлений» не обновлялись:

- `/etc/init.d/zapret2wizard` — не приезжали modprobe veth (0.36.33) и хуки канарейки
- `/usr/share/zapret2wizard/tspu_catalog.txt` — каталог 34 стратегий
- `/usr/share/zapret2wizard/tspu_classifier.lua` — логика классификатора

Теперь updater скачивает и ставит эти файлы с проверками целостности, и сразу
делает `modprobe veth`.

## Проверено на живом роутере

Routerich AX3000 v1 / RouteRich 25.12.6 (192.168.1.1):

- страница открывается, `hasErrorBanner: false`, в консоли нет ReferenceError
- карточка «Класс ТСПУ» присутствует в DOM
- `blockcheckw-helper canary_status` — отвечает
- `tspu_class` запускается, сканер загружает 34 стратегии из каталога
- lua-синтаксис классификатора на роутере — OK

## Обновление

Кнопка «Проверка обновлений» в LuCI → Обновить, или:

```sh
wget -O /tmp/u.sh https://raw.githubusercontent.com/prostoy23rus/zapret2wizard/main/install.sh && sh /tmp/u.sh
```

После обновления: Ctrl+F5 в браузере (сброс кэша main.js).
