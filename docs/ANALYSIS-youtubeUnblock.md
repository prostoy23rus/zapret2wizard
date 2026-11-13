# Разбор youtubeUnblock и векторы для Zapret2Wizard

Источник: https://github.com/Waujito/youtubeUnblock (GPLv3, C, userspace NFQUEUE + опциональный kernel-модуль).

## 1. Что делает проект

Узкоспециализированный обход SNI-детекта YouTube: перехватывает TCP/443 и UDP/443 через netfilter queue, находит TLS ClientHello, режет или подменяет его до того, как TSPU увидит SNI, и отправляет фейковые пакеты с невалидными для получателя параметрами. Есть userspace-версия и kernel-модуль (kyoutubeUnblock).

Ключевая идея: не менять полезную нагрузку, а менять порядок, разбиение и валидность пакетов, чтобы DPI не смог собрать ClientHello, а сервер смог.

## 2. Механики youtubeUnblock

| Механика | Флаги | Суть |
|---|---|---|
| Fake ClientHello | --fake-sni, --fake-sni-seq-len, --fake-sni-type | перед настоящим CH отправляется фейковый (default SNI=www.google.com / custom / random), иногда несколько |
| Инвалидация фейка | --faking-strategy=randseq,ttl,tcp_check,pastseq,md5sum,timestamp | фейк должен дойти до DPI, но не до сервера: битая контрольная сумма, неверный TCP MD5, старый TSVal, TTL, seq из прошлого |
| TCP-фрагментация | --frag=tcp, --frag-sni-pos, --frag-middle-sni, --frag-sni-reverse, --frag-sni-faked | CH режется на части; порядок может быть обратным; фрагменты могут заполняться нулями |
| IP-фрагментация | --frag=ip | то же на уровне IP (только IPv4) |
| Повтор оригинала | --frag-origin-retries | после фрагментов отправить оригинал ещё N раз |
| Задержка 2-го фрагмента | --seg2delay | разнести части по времени |
| Window size | --fk-winsize | подменить TCP window, чтобы ответ сервера тоже фрагментировался |
| SYN fake | --synfake, --synfake-len | фейковый payload в SYN (аналог syndata из zapret) |
| UDP/QUIC | --udp-mode=drop/fake, --udp-fake-seq-len, --udp-fake-len, --udp-faking-strategy=checksum/ttl, --quic-drop, --udp-filter-quic=parse | дроп или фейк QUIC; в режиме parse расшифровывает QUIC Initial и матчит SNI |
| STUN | --udp-stun-filter | не трогать голосовые STUN-пакеты |
| Секции по SNI | --sni-domains, --exclude-domains, --fbegin | разные стратегии для разных доменов |
| Conntrack | --use-conntrack, --tcp-match-connpackets, --connbytes-limit | обрабатывать только первые пакеты соединения |

## 3. Что уже есть в Zapret2Wizard

Наш движок — nfqws2 + Lua-десинк, поэтому почти все примитивы уже доступны:

| Примитив | У нас | Где |
|---|---|---|
| fake + blob/hex | да | корпус fake:blob=... |
| fake с bad checksum | да | fake:badsum |
| fake с неверным TCP MD5 | да | fake:tcp_md5 |
| fake с tcp_seq/tcp_ack | да | fake:tcp_seq=-10000:tcp_ack=-66000 |
| fake с TCP Timestamp | да | hostfakesplit:...:tcp_ts=-600000 |
| split/multisplit | да | multisplit:pos=... |
| disorder | да | multidisorder:pos=... |
| fakedsplit / fakeddisorder | да | корпус/пресеты |
| hostfakesplit (fake SNI) | да | host=gosuslugi.ru и др. |
| wssize | да | wssize:wsize=1:scale=6 |
| TTL/autottl | да | ttl, autottl |
| syndata | да, но слабо | --lua-desync=syndata --payload=tls_client_hello без blob/tls_mod |
| oob | да, но слабо | oob:urp=midsld без char/byte |
| ipfrag / ipfrag_disorder | есть в Lua, нет в корпусе | :ipfrag:ipfrag_pos_tcp=... |
| delay (send) | есть | send:delay=<ms> |
| секции по сервисам | да | BlockcheckW_* |
| лимит пакетов на соединение | да, лучше youtubeUnblock | nft ct original packets 1-25 (TCP), 1-5 (UDP) |
| IPv6 | **нет**: nft-правила только meta nfproto ipv4, filter_l3=ipv4 | — |

## 4. Векторы, которые стоит забрать

### P0. IPv6-обход

youtubeUnblock умеет IPv6 (кроме IP-фрагментации), у нас queue-правила только IPv4 и в стратегиях filter_l3=ipv4. На сетях с IPv6 (мобильные операторы, часть провайдеров) YouTube пойдёт по IPv6 мимо обхода.

Что сделать: добавить в nft-снимок правила meta nfproto ipv6, filter_l3=ipv6 в профили и проверку ip -6 route в doctor.

### P0. IP-фрагментация (ipfrag)

В Lua есть ipfrag2 и ipfrag_disorder, но в корпусе нет ни одного кандидата. Это дешёвый и неохваченный вектор: DPI, который собирает TCP, но не IP, ломается на фрагментах.

Примеры кандидатов (проверить синтаксис на роутере):

```
--payload=tls_client_hello --lua-desync=multisplit:pos=midsld:ipfrag:ipfrag_pos_tcp=32
--payload=tls_client_hello --lua-desync=multisplit:pos=midsld:ipfrag:ipfrag_pos_tcp=32:ipfrag_disorder
--payload=tls_client_hello --lua-desync=send:ipfrag:ipfrag_pos_tcp=32
```

### P1. SYN fake с настоящим TLS ClientHello

Сейчас syndata в корпусе отправляет 16 нулевых байт (дефолт), а не фейковый CH. youtubeUnblock шлёт fake CH с SNI и ограничивает длину под MTU.

```
--lua-desync=syndata:blob=fake_default_tls:tls_mod=sni=www.google.com
--payload=tls_client_hello --lua-desync=multisplit:pos=1,midsld
```

### P1. OOB с явным char/urp

Наш кандидат oob:urp=midsld не задаёт OOB-байт. В Lua есть char, byte, urp=b/e. Стоит добавить:

```
--in-range=-s1 --lua-desync=oob:urp=b:char=0x00
--in-range=-s1 --lua-desync=oob:urp=e:byte=0
```

### P1. Обратный порядок фрагментов и задержка

frag-sni-reverse и seg2delay у youtubeUnblock. У нас multidisorder умеет порядок позиций, но в корпусе нет обратного (pos=midsld,1), а send:delay есть, но не для второго фрагмента.

```
--payload=tls_client_hello --lua-desync=multidisorder:pos=midsld,1
--payload=tls_client_hello --lua-desync=multisplit:pos=midsld:send:delay=50
```

(второе — приближение, а не точный seg2delay).

### P2. QUIC по SNI, а не глобально

youtubeUnblock расшифровывает QUIC Initial и матчит SNI. У нас QUIC-режим глобальный: reject/fake всех UDP/443. Это может ломать другие QUIC-приложения. В Lua есть bquic_tvb/QUIC-функции — можно попробовать SNI-aware fake только для целевых доменов. Задача сложная, но полезная для тихого режима.

### P2. GSO/fat packets

youtubeUnblock имеет --no-gso и умеет обрабатывать GSO. Стоит проверить, корректно ли nfqws2 режет GSO-пакеты на нашем роутере (большой ClientHello, TSO на WAN). Если нет — отключать GSO на интерфейсе или добавить reconstruct-режим.

## 5. Что копировать не нужно

- Kernel-модуль: своя сборка под каждое ядро, высокая цена поддержки; у нас уже есть лимит пакетов через conntrack.
- Жёсткий список доменов YouTube: у нас мультисервисные hostlist'ы.
- --synfake для всех сайтов: автор сам предупреждает, что это глобально; нам нужен только per-target.
- Глобальный --quic-drop: у нас уже есть режимы auto/allow/reject/fake, глобальный drop ломает Discord/игры.

## 6. План проверки на домашнем роутере

1. Добавить 2-3 ipfrag-кандидата в корпус и прогнать скан YouTube/Twitch.
2. Сравнить all_ok/стабильность с текущими лучшими стратегиями.
3. Проверить syndata:blob=fake_default_tls и oob:urp=b:char=0.
4. Для IPv6: включить v6 на тестовом интерфейсе (или проверить на сети с v6), добавить правила и убедиться, что аудит идёт по v6.
5. Замерить CPU: ipfrag/syndata — rawsend, нагрузка выше; следить за load average.

## 7. Итог

youtubeUnblock ценен не ещё одним списком стратегий, а дисциплиной инвалидации фейков и IP-фрагментацией. У нас уже покрыты fake/split/disorder/TTL/TS/seq/MD5/wssize, но ipfrag, полноценный syndata, OOB-варианты и IPv6 остаются неиспользованными. Самые дешёвые и перспективные шаги — ipfrag в корпус и IPv6-правила; самый сложный — QUIC SNI-aware.
