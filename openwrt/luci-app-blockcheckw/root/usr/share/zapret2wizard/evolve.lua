-- evolve.lua — генератор и память «геномов» стратегий для Zapret2Wizard.
--
-- Геном = строка аргументов nfqws2, собранная из примитивов zapret2
-- (fake, multisplit, multidisorder, hostfakesplit, fakeddisorder, wssize, seqovl).
-- Служба не изобретает новые Lua-функции — она синтезирует НОВЫЕ КОМБИНАЦИИ
-- существующих примитивов и запоминает, какие из них работают у провайдера.
--
-- Режимы:
--   gen    <genomes.json> <provider> <corpus.txt> <domain> <count>
--   update <genomes.json> <provider> <candidates.json> <scan.json> <verified.json>
--
-- genomes.json: {"providers":{"<provider>":{"genomes":{"<id>":{"args":..,"ok":N,"fail":N,"best":B,"last":T}}}}}

local json = require("luci.jsonc")

local mode = arg[1] or ""

-- ---------------------------------------------------------------- утилиты -----

local function read_json(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    local ok, parsed = pcall(json.parse, data)
    if ok then return parsed end
    return nil
end

local function write_json(path, obj)
    local f = io.open(path, "w")
    if not f then return false end
    f:write(json.stringify(obj))
    f:close()
    return true
end

local function hash(s)
    local h = 5381
    for i = 1, #s do
        h = (h * 31 + s:byte(i)) % 2147483647
    end
    return string.format("%08x", math.floor(h))
end

local function split(s, sep)
    local out = {}
    for part in string.gmatch(s, "([^" .. sep .. "]+)") do out[#out + 1] = part end
    return out
end

local function now_ts()
    local t = os.time()
    return t
end

-- ------------------------------------------------------- пространство генов --

local POS = {
    "midsld",
    "1,midsld",
    "sld",
    "1,sniext+1,endhost-1",
    "8,12",
    "host+1,midsld",
    "midsld,1220",
}

local FAKE_STYLES = {
    "fake:blob=0x00000000:tcp_md5:repeats=%d",
    "fake:blob=0x00000000:badsum:repeats=%d",
    "fake:blob=fake_default_tls:tcp_md5:repeats=%d",
    "fake:blob=0x00000000:ip_autottl=-2,3-20:repeats=%d",
    "fake:blob=0x00000000:tcp_seq=-10000:tcp_ack=-66000:repeats=%d",
}

local HOSTS = { "vk.com", "gosuslugi.ru", "sber.ru", "yandex.ru", "ozon.ru", "mail.ru" }

-- Разбор генома на гены: префикс wssize, fake, split, hostfake.
local function parse_genome(args)
    local g = {}
    for tok in tostring(args):gmatch("%-%-lua%-desync=(%S+)") do
        if tok:find("^wssize") then
            g.prefix = tok
        elseif tok:find("^fake:") then
            g.fake = tok
        elseif tok:find("^fakeddisorder") or tok:find("^multisplit") or tok:find("^multidisorder") then
            g.split = tok
        elseif tok:find("^hostfakesplit") then
            g.hostfake = tok
        elseif tok:find("^rst") or tok:find("^syndata") then
            g.extra = tok
        end
    end
    return g
end

local function compose_genome(g)
    local parts = {}
    if g.prefix then parts[#parts + 1] = "--lua-desync=" .. g.prefix end
    if g.fake then parts[#parts + 1] = "--lua-desync=" .. g.fake end
    if g.split then parts[#parts + 1] = "--lua-desync=" .. g.split end
    if g.hostfake and not g.split then parts[#parts + 1] = "--lua-desync=" .. g.hostfake end
    if g.extra then parts[#parts + 1] = "--lua-desync=" .. g.extra end
    return "--payload=tls_client_hello " .. table.concat(parts, " ")
end

-- Случайный элемент набора. Объявлено ДО crossover: Lua резолвит имена
-- при компиляции, и вызов из функции, объявленной выше, уходил в глобал nil
-- (плавающая ошибка "attempt to call global 'random_of'").
local function random_of(t)
    return t[math.random(#t)]
end

-- Кроссовер: берём фейк у одного родителя, нарезку у другого.
local function crossover(a, b)
    local ga, gb = parse_genome(a), parse_genome(b)
    local child = {
        prefix = (math.random(1, 2) == 1) and (ga.prefix or gb.prefix) or (gb.prefix or ga.prefix),
        fake = (math.random(1, 2) == 1) and (ga.fake or gb.fake) or (gb.fake or ga.fake),
        split = (math.random(1, 2) == 1) and (gb.split or ga.split) or (ga.split or gb.split),
        hostfake = ga.hostfake or gb.hostfake,
        extra = (math.random(1, 3) == 1) and (ga.extra or gb.extra) or nil,
    }
    -- мутация: иногда меняем позицию или добавляем seqovl
    if child.split and math.random(1, 3) == 1 then
        local kind, rest = child.split:match("^([^:]+):(.*)$")
        if kind and rest then
            local pos = random_of(POS)
            child.split = kind .. ":pos=" .. pos .. ((math.random(1, 2) == 1) and ":seqovl=1" or "")
        end
    end
    if child.split then child.hostfake = nil end
    return compose_genome(child)
end


-- Собрать геном: необязательный wssize-префикс, fake и нарезка в разном порядке.
local function build_genome(rng)
    local parts = {}
    if rng < 0.25 then
        parts[#parts + 1] = "--lua-desync=wssize:wsize=1:scale=6"
    end

    local order = math.random(1, 3)
    local pos = random_of(POS)
    local seq = (math.random(1, 3) == 1) and ":seqovl=1" or ""
    local fake = nil
    if math.random(1, 2) == 1 then
        fake = string.format(random_of(FAKE_STYLES), math.random(2, 6))
    end

    local split
    local kind = math.random(1, 3)
    if kind == 1 then
        split = "multisplit:pos=" .. pos .. seq
    elseif kind == 2 then
        split = "multidisorder:pos=" .. pos .. seq
    else
        split = "fakeddisorder:pos=" .. pos .. (math.random(1, 2) == 1 and ":tcp_md5" or "")
    end

    if fake and order >= 2 then
        parts[#parts + 1] = "--lua-desync=" .. fake
        parts[#parts + 1] = "--lua-desync=" .. split
    elseif fake then
        parts[#parts + 1] = "--lua-desync=" .. split
        parts[#parts + 1] = "--lua-desync=" .. fake
    else
        -- без фейка: иногда добавляем hostfake как самостоятельную технику
        if math.random(1, 3) == 1 then
            parts[#parts + 1] = "--lua-desync=hostfakesplit:host=" .. random_of(HOSTS) .. ":tcp_ts=-600000"
        end
        parts[#parts + 1] = "--lua-desync=" .. split
    end

    return "--payload=tls_client_hello " .. table.concat(parts, " ")
end

-- -------------------------------------------------------------- режим gen ----

local function mode_gen()
    local genomes_path = arg[2]
    local provider = arg[3] or "default"
    local corpus_path = arg[4]
    local domain = arg[5]
    local count = tonumber(arg[6] or "16") or 16

    math.randomseed(now_ts() + (os.time() % 1000))

    local db = read_json(genomes_path) or { providers = {} }
    db.providers = db.providers or {}
    local prov = db.providers[provider] or { genomes = {} }
    db.providers[provider] = prov
    prov.genomes = prov.genomes or {}

    -- эксплуатация: лучшие известные геномы провайдера
    local known = {}
    for id, g in pairs(prov.genomes) do
        if g.args and (g.ok or 0) > 0 then
            known[#known + 1] = { id = id, args = g.args, score = (g.ok or 0) * 1000 + (g.stability or 0) * 2 + (g.best or 0) / 1024 }
        end
    end
    table.sort(known, function(a, b) return a.score > b.score end)

    local chosen, seen = {}, {}
    local exploit = math.min(#known, math.floor(count / 2))
    for i = 1, exploit do
        chosen[#chosen + 1] = known[i].args
        seen[known[i].args] = true
    end

    -- кроссовер: скрещиваем пары лучших геномов
    local crossed = 0
    if #known >= 2 then
        local pairs_n = math.min(#known - 1, math.floor(count / 3))
        for i = 1, pairs_n do
            local parent_a = known[i].args
            local parent_b = known[i + 1].args
            -- один кривой кроссовер не должен обнулять весь подбор
            local okc, child = pcall(crossover, parent_a, parent_b)
            if okc and child and not seen[child] then
                seen[child] = true
                chosen[#chosen + 1] = child
                crossed = crossed + 1
            end
        end
    end

    -- исследование: новые комбинации
    local guard = 0
    while #chosen < count and guard < count * 20 do
        guard = guard + 1
        local args = build_genome(math.random())
        if not seen[args] then
            seen[args] = true
            chosen[#chosen + 1] = args
        end
    end

    local candidates = {}
    local corpus = io.open(corpus_path, "w")
    for i, args in ipairs(chosen) do
        local id = hash(args)
        candidates[#candidates + 1] = { id = id, args = args }
        if corpus then
            corpus:write("curl_test_https_tls13 ipv4 ", domain, " : nfqws2 ", args, "\n")
        end
    end
    if corpus then corpus:close() end

    -- кандидаты кладём рядом с корпусом: helper читает <corpus>.candidates
    write_json(corpus_path .. ".candidates", candidates)
    print(json.stringify({ provider = provider, generated = #candidates, exploit = exploit, crossed = crossed }))
end

-- ----------------------------------------------------------- режим update ----

local function mode_update()
    local genomes_path = arg[2]
    local provider = arg[3] or "default"
    local candidates_path = arg[4]
    local scan_path = arg[5]
    local verified_path = arg[6]

    local db = read_json(genomes_path) or { providers = {} }
    db.providers = db.providers or {}
    local prov = db.providers[provider] or { genomes = {} }
    db.providers[provider] = prov
    prov.genomes = prov.genomes or {}

    local candidates = read_json(candidates_path) or {}
    local scan = read_json(scan_path) or {}
    -- verified_path: текстовый файл, по строке "id|ok|bytes"
    local verified_map = {}
    do
        local vf = io.open(verified_path, "r")
        if vf then
            for line in vf:lines() do
                local id, ok, bytes, runs, okruns = line:match("^(%x+)|([01])|(%d+)|(%d+)|(%d+)$")
                if id then
                    verified_map[id] = {
                        ok = (ok == "1"),
                        bytes = tonumber(bytes) or 0,
                        runs = tonumber(runs) or 1,
                        okruns = tonumber(okruns) or ((ok == "1") and 1 or 0),
                    }
                end
            end
            vf:close()
        end
    end

    -- какие args прошли пробу
    local scan_ok = {}
    for _, s in ipairs(scan.strategies or {}) do
        local a = (type(s) == "table" and s.args) or s
        if a then scan_ok[a] = true end
    end


    local touched, learned = 0, 0
    for _, c in ipairs(candidates) do
        local args = c.args
        if args then
            local g = prov.genomes[c.id]
            if not g then
                g = { args = args, ok = 0, fail = 0, best = 0, last = 0 }
                prov.genomes[c.id] = g
            end
            g.last = now_ts()
            g.scan_ok = scan_ok[args] and true or false
            local v = verified_map[c.id]
            if v then
                g.runs = (g.runs or 0) + (v.runs or 1)
                g.okruns = (g.okruns or 0) + (v.okruns or 0)
                if g.runs > 0 then
                    g.stability = math.floor(g.okruns * 100 / g.runs)
                end
                if v.ok then
                    g.ok = (g.ok or 0) + 1
                    if (v.bytes or 0) > (g.best or 0) then g.best = v.bytes end
                    learned = learned + 1
                else
                    g.fail = (g.fail or 0) + 1
                end
            elseif not scan_ok[args] then
                g.fail = (g.fail or 0) + 1
            end
            touched = touched + 1
        end
    end

    -- ограничим память: держим 200 лучших геномов провайдера
    local ids = {}
    for id in pairs(prov.genomes) do ids[#ids + 1] = id end
    if #ids > 200 then
        table.sort(ids, function(a, b)
            local ga, gb = prov.genomes[a], prov.genomes[b]
            return ((ga.ok or 0) * 1000 + (ga.stability or 0) * 2 + (ga.best or 0) / 1024) > ((gb.ok or 0) * 1000 + (gb.stability or 0) * 2 + (gb.best or 0) / 1024)
        end)
        for i = 201, #ids do prov.genomes[ids[i]] = nil end
    end

    write_json(genomes_path, db)
    print(json.stringify({ provider = provider, touched = touched, learned = learned, total = #ids }))
end


-- ------------------------------------------------ режим provider/shortlist ----

local function mode_provider()
    local status_path = arg[2] or "/tmp/blockcheckw_status.json"
    local st = read_json(status_path) or {}
    local isp = tostring(st.isp or st.provider or "")
    local bt = tostring(st.block_type or "unknown")
    if isp == "" or isp == "nil" or isp == "unknown" then
        isp = "auto"
    end
    -- ключ провайдера: только безопасные символы
    local key = (isp .. "_" .. bt):gsub("[^%w%-%._]", "_"):gsub("_+", "_")
    if #key > 80 then key = key:sub(1, 80) end
    print(key)
end

local function mode_shortlist()
    local candidates_path = arg[2]
    local scan_path = arg[3]
    local limit = tonumber(arg[4] or "3") or 3

    local candidates = read_json(candidates_path) or {}

    -- scan пишет либо JSON-отчёт, либо текстовый список рабочих args
    local ok = {}
    local scan = read_json(scan_path)
    if scan and scan.strategies then
        for _, s in ipairs(scan.strategies) do
            local a = (type(s) == "table" and s.args) or s
            if a then ok[a] = true end
        end
    else
        local f = io.open(scan_path, "r")
        if f then
            for line in f:lines() do
                local a = line:match("^(%-%-payload.*)$")
                if a then ok[a] = true end
            end
            f:close()
        end
    end

    local n = 0
    for _, c in ipairs(candidates) do
        if c.args and ok[c.args] then
            print(c.id .. "|" .. c.args)
            n = n + 1
            if n >= limit then break end
        end
    end
end

-- --------------------------------------------- режимы history и status -------

local function read_pairs(path)
    local out = {}
    local f = io.open(path, "r")
    if f then
        for line in f:lines() do
            local k, v = line:match("^([%w_]+)=(.*)$")
            if k then out[k] = v end
        end
        f:close()
    end
    return out
end

local function mode_history()
    local genomes_path = arg[2]
    local provider = arg[3] or "default"
    local stats_path = arg[4]

    local db = read_json(genomes_path) or { providers = {} }
    db.providers = db.providers or {}
    local prov = db.providers[provider] or { genomes = {} }
    db.providers[provider] = prov
    prov.history = prov.history or {}

    local st = read_pairs(stats_path)
    local n = 0
    for _ in pairs(prov.genomes) do n = n + 1 end

    prov.history[#prov.history + 1] = {
        ts = now_ts(),
        generated = tonumber(st.generated) or 0,
        crossed = tonumber(st.crossed) or 0,
        exploit = tonumber(st.exploit) or 0,
        stable = tonumber(st.stable) or 0,
        applied = st.applied or "",
        total = n,
    }

    -- храним 30 последних поколений
    while #prov.history > 30 do table.remove(prov.history, 1) end

    write_json(genomes_path, db)
    print(json.stringify({ ok = true, total = n, generations = #prov.history }))
end

local function is_running()
    local f = io.open("/tmp/bcw_evolve.running", "r")
    if not f then return false, 0 end
    local pid = tonumber(f:read("*a")) or 0
    f:close()
    if pid <= 0 then return false, 0 end
    local ok = os.execute("kill -0 " .. pid .. " 2>/dev/null")
    return ok == true or ok == 0, pid
end

local function mode_status()
    local genomes_path = arg[2]
    local provider = arg[3] or "default"

    local db = read_json(genomes_path) or { providers = {} }
    local prov = (db.providers or {})[provider] or { genomes = {}, history = {} }

    local running, pid = is_running()

    local top = {}
    for id, g in pairs(prov.genomes or {}) do
        if g.args then
            top[#top + 1] = {
                id = id,
                args = g.args,
                ok = g.ok or 0,
                fail = g.fail or 0,
                best = g.best or 0,
                stability = g.stability or 0,
                last = g.last or 0,
            }
        end
    end
    table.sort(top, function(a, b)
        return (a.ok * 1000 + a.stability * 2 + a.best / 1024) > (b.ok * 1000 + b.stability * 2 + b.best / 1024)
    end)

    local top_n = {}
    for i = 1, math.min(#top, 10) do top_n[i] = top[i] end

    local hist = prov.history or {}
    local hist_n = {}
    local start = math.max(1, #hist - 14)
    for i = start, #hist do hist_n[#hist_n + 1] = hist[i] end

    local last_run = 0
    if #hist > 0 then last_run = hist[#hist].ts end

    -- ближайший ночной запуск: 04:23 по местному времени
    local lt = os.date("*t")
    local next_run = os.time({ year = lt.year, month = lt.month, day = lt.day, hour = 4, min = 23, sec = 0 })
    if next_run <= now_ts() then next_run = next_run + 86400 end

    print(json.stringify({
        provider = provider,
        running = running,
        pid = pid,
        last_run = last_run,
        next_run = next_run,
        total_genomes = #top,
        history = hist_n,
        top = top_n,
    }))
end

-- ------------------------------------------- экспорт и импорт геномов --------

local function mode_export()
    local genomes_path = arg[2]
    local provider = arg[3] or "default"
    local min_ok = tonumber(arg[4] or "1") or 1

    local db = read_json(genomes_path) or { providers = {} }
    local prov = (db.providers or {})[provider] or { genomes = {} }

    local list = {}
    for _, g in pairs(prov.genomes or {}) do
        if g.args and (g.ok or 0) >= min_ok then
            list[#list + 1] = {
                args = g.args,
                ok = g.ok or 0,
                best = g.best or 0,
                stability = g.stability or 0,
            }
        end
    end
    table.sort(list, function(a, b)
        return (a.ok * 1000 + a.stability * 2 + a.best / 1024) > (b.ok * 1000 + b.stability * 2 + b.best / 1024)
    end)

    local asn = tostring(provider):match("(AS%d+)") or (arg[5] or "")
    print(json.stringify({
        schema = 1,
        generator = "zapret2wizard",
        asn = asn,
        provider = provider,
        exported_at = now_ts(),
        count = #list,
        genomes = list,
    }))
end

local function mode_import()
    local genomes_path = arg[2]
    local provider = arg[3] or "default"
    local src = arg[4]

    local incoming = read_json(src)
    if not incoming then
        print(json.stringify({ ok = false, error = "не удалось прочитать файл" }))
        return
    end

    local list = incoming.genomes or {}
    if type(list) ~= "table" then
        print(json.stringify({ ok = false, error = "нет поля genomes" }))
        return
    end

    local db = read_json(genomes_path) or { providers = {} }
    db.providers = db.providers or {}
    local prov = db.providers[provider] or { genomes = {} }
    db.providers[provider] = prov
    prov.genomes = prov.genomes or {}

    local imported, updated = 0, 0
    for _, g in ipairs(list) do
        local args = g.args
        if type(args) == "string" and #args > 10 then
            local id = hash(args)
            local cur = prov.genomes[id]
            if cur then
                cur.ok = math.max(cur.ok or 0, tonumber(g.ok) or 0)
                cur.best = math.max(cur.best or 0, tonumber(g.best) or 0)
                cur.stability = math.max(cur.stability or 0, tonumber(g.stability) or 0)
                cur.last = now_ts()
                updated = updated + 1
            else
                prov.genomes[id] = {
                    args = args,
                    ok = tonumber(g.ok) or 1,
                    fail = 0,
                    best = tonumber(g.best) or 0,
                    stability = tonumber(g.stability) or 0,
                    last = now_ts(),
                    imported_from = tostring(incoming.provider or "shared"),
                }
                imported = imported + 1
            end
        end
    end

    write_json(genomes_path, db)
    local total = 0
    for _ in pairs(prov.genomes) do total = total + 1 end
    print(json.stringify({ ok = true, imported = imported, updated = updated, total = total }))
end

-- ASN из строки провайдера ("AS25490 OJSC ..." -> "AS25490")
local function mode_asn()
    local status_path = arg[2] or "/tmp/blockcheckw_status.json"
    local st = read_json(status_path) or {}
    local isp = tostring(st.isp or "")
    local asn = isp:match("(AS%d+)")
    if not asn then
        asn = "AS0"
    end
    print(asn)
end

local function mode_args()
    local genomes_path = arg[2]
    local provider = arg[3] or "default"
    local id = arg[4]
    local db = read_json(genomes_path) or { providers = {} }
    local prov = (db.providers or {})[provider] or { genomes = {} }
    local g = (prov.genomes or {})[id]
    if not g or not g.args then
        print(json.stringify({ ok = false, error = "геном не найден" }))
        return
    end
    print(json.stringify({
        ok = true,
        id = id,
        args = g.args,
        ok_count = g.ok or 0,
        fail = g.fail or 0,
        best = g.best or 0,
        stability = g.stability or 0,
        last = g.last or 0,
    }))
end

if mode == "gen" then
    mode_gen()
elseif mode == "update" then
    mode_update()
elseif mode == "provider" then
    mode_provider()
elseif mode == "shortlist" then
    mode_shortlist()
elseif mode == "history" then
    mode_history()
elseif mode == "status" then
    mode_status()
elseif mode == "export" then
    mode_export()
elseif mode == "asn" then
    mode_asn()
elseif mode == "args" then
    mode_args()
elseif mode == "import" then
    mode_import()
else
    print("usage: evolve.lua gen|update|provider|shortlist|history|status|export|import|asn|args ...")
end
