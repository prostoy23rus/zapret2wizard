#!/usr/bin/lua
-- ============================================================
--  TSPU Classifier for zapret2wizard
--  Порт логики вердикта «КЛАСС ТСПУ» из saitkul/tspu-class-test v2.5
--  (AWK-блок tspu-test, стратегии 1-34, вердикты L0-/L0/L2/особый/аномалия).
--
--  Вход:
--    arg[1] = путь к scan.json сканера blockcheckw
--             (формат: {"strategies":[{"protocol":"HTTPS/TLS1.2","args":"..."}]})
--    arg[2] = путь к каталогу tspu_catalog.txt (34 строки, # = комментарий)
--
--  Выход (JSON одной строкой):
--    {
--      "ok": true,
--      "catalog": 34,
--      "tls12": {"stable": [1,4,...], "verdict": "L0- ...", "reco": 1, "reco_args": "--payload=..."},
--      "tls13": { ... },
--      "notes": ["..."]
--    }
--
--  Матчинг каталога по ТОЧНОМУ совпадению нормализованной строки args
--  с рабочими стратегиями скана. Строка каталога считается прошедшей
--  для протокола, если сканер нашёл её рабочей на этом протоколе.
-- ============================================================

local json = require("luci.jsonc")

local scan_file = arg[1]
local catalog_file = arg[2] or "/usr/share/zapret2wizard/tspu_catalog.txt"

local function fail(msg)
    print(json.stringify({ ok = false, error = msg }))
    os.exit(1)
end

local function norm(s)
    if not s then return "" end
    s = tostring(s):gsub("\r", "")
    s = s:gsub("%s+", " ")
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    return s
end

-- ---- 1. Каталог: номер -> args (первые 34 непустые не-комментарийные строки) ----
local lst = {}
local cf = io.open(catalog_file, "r")
if not cf then fail("catalog not found: " .. catalog_file) end
for line in cf:lines() do
    line = norm(line)
    if line ~= "" and line:sub(1, 1) ~= "#" then
        lst[#lst + 1] = line
        if #lst >= 34 then break end
    end
end
cf:close()
local n = #lst
if n < 10 then fail("catalog too short: " .. n .. " lines") end

-- ---- 2. Скан: протокол -> map[args] = true (только рабочие) ----
local passed = { tls12 = {}, tls13 = {} }
local sf = io.open(scan_file, "r")
if not sf then fail("scan file not found: " .. scan_file) end
local d = json.parse(sf:read("*a"))
sf:close()
if not d or type(d) ~= "table" then fail("scan parse failed") end

local strats = d.strategies
-- Формат A: плоский список {protocol, args} (scan/universal отчёты)
-- Формат B: protocols[] с вложенными strategies[] (полный scan отчёт)
if not strats and type(d.protocols) == "table" then
    strats = {}
    for _, pr in ipairs(d.protocols) do
        local pn = tostring(pr.protocol or "")
        for _, s in ipairs(pr.strategies or {}) do
            local a = (type(s) == "table" and s.args) or s
            if a then strats[#strats + 1] = { protocol = pn, args = a } end
        end
    end
end
if not strats then strats = {} end

for _, s in ipairs(strats) do
    if type(s) == "table" then
        local a = s.args or s
        local p = tostring(s.protocol or "")
        local key = nil
        if p:find("TLS1.2") then key = "tls12"
        elseif p:find("TLS1.3") then key = "tls13" end
        if key then passed[key][norm(a)] = true end
    else
        -- строка без протокола: считаем прошедшей на обеих версиях
        passed.tls12[norm(s)] = true
        passed.tls13[norm(s)] = true
    end
end

-- ---- 3. Матчинг каталога ----
local ok = { tls12 = {}, tls13 = {} }   -- ok[proto][k] = true, если прошла
local matched = 0
for k = 1, n do
    if passed.tls12[lst[k]] then ok.tls12[k] = true; matched = matched + 1 end
    if passed.tls13[lst[k]] then ok.tls13[k] = true; matched = matched + 1 end
end

-- ---- 4. Вердикт (порт AWK tspu-test) ----
local function in_list(k, list)
    for _, v in ipairs(list) do if v == k then return true end end
    return false
end

local PRI = { 1, 4, 6, 5, 22, 17, 2, 18, 19, 20, 21, 24, 25, 26, 27, 28, 29,
              30, 31, 11, 12, 13, 14, 15, 16, 33, 32, 34, 23, 7, 8, 9, 10, 3 }

local DIS_SET = { 1, 4, 6, 19 }
local SPL_SET = { 2, 5, 17, 18, 22, 23 }

local function classify(proto)
    local st, fl = {}, {}
    local dis, spl, fk, cb, cut = {}, {}, {}, {}, {}
    for k = 1, n do
        if ok[proto][k] then
            st[#st + 1] = k
            if k <= 6 or k == 17 or k == 18 or k == 19 or k == 22 or k == 23 then
                cut[#cut + 1] = k
            end
            if in_list(k, DIS_SET) then
                dis[#dis + 1] = k
            elseif in_list(k, SPL_SET) then
                spl[#spl + 1] = k
            elseif k >= 7 and k <= 10 then
                fk[#fk + 1] = k
            elseif k ~= 3 then
                cb[#cb + 1] = k
            end
        end
    end

    local verdict, notes = "", {}
    local function has(list, k)
        for _, v in ipairs(list) do if v == k then return true end end
        return false
    end

    if #st == 0 then
        verdict = "не определён (ни одна строка не прошла)"
    elseif #dis > 0 and #spl > 0 then
        verdict = "L0-: нарезка пробивает и без фейков, хватит простого разреза"
        if not has(spl, 2) and not has(spl, 17) then
            notes[#notes + 1] = "чистый multisplit (2) ТСПУ склеивает - прямому разрезу помогает seqovl (5)"
        end
    elseif #dis > 0 then
        verdict = "L0: обратный порядок пробивает, прямой ТСПУ склеивает - достаточно multidisorder"
    elseif #spl > 0 then
        verdict = "аномалия: прямой разрез пробивает, а обратный порядок ТСПУ собирает - опирайтесь на multisplit/seqovl"
        if not has(spl, 2) and not has(spl, 17) then
            notes[#notes + 1] = "прямой разрез - только с seqovl (5)"
        end
    elseif #cb > 0 then
        -- В исходном AWK ветка «новые механики» была недостижима: 32-34 всегда
        -- попадают в cb. Реализуем замысел автора: cb из ОДНИХ 32/33/34 = особый.
        local only_new = true
        for _, k in ipairs(cb) do
            if k ~= 32 and k ~= 33 and k ~= 34 then only_new = false break end
        end
        if only_new then
            verdict = "особый: прошли только новые механики (32-34: клон-фейк, send-эхо)"
        else
            verdict = "L2: нарезка проходит только вместе с фейком"
        end
    elseif #fk > 0 then
        verdict = "особый: ТСПУ верит голому фейку, но режет нарезку"
    elseif has(st, 3) then
        verdict = "особый: прошёл только разрез на границе SLD - используйте pos=sld"
    else
        verdict = "не определён"
    end

    -- Дополнительные заметки (порт NT-блока AWK)
    if #fk > 0 then
        notes[#notes + 1] = "ТСПУ ВЕРИТ фейковому ClientHello (решение принимается по фейку), сервер отбрасывает фейк по фулингу"
    end
    if #fk == 0 and #cb > 0 and (#dis > 0 or #spl > 0) then
        notes[#notes + 1] = "голые фейки (7-10) отсекаются: фейк полезен только вместе с нарезкой"
    end
    if has(st, 3) and #dis == 0 then
        notes[#notes + 1] = "разрез на границе SLD (3) проходит без внутреннего - годится pos=sld"
    end
    if #dis > 0 and not has(st, 3) then
        notes[#notes + 1] = "разрез на границе SLD (3) не проходит - работают разрезы внутри слова SLD (midsld) и ведущий байт (pos=1,...)"
    end
    if has(st, 17) then
        notes[#notes + 1] = "двухпакетный hello (17) прошла: ближе всего к браузерному поведению (kyber)"
    end
    local srd = {}
    if has(st, 18) then srd[#srd + 1] = "18" end
    if has(st, 19) then srd[#srd + 1] = "19" end
    if #srd > 0 then
        notes[#notes + 1] = "7-точечный шред прошёл (строки " .. table.concat(srd, ", ") .. "): разрезы по всем границам SNI сразу"
    end
    local bd = {}
    if has(st, 20) then bd[#bd + 1] = "20" end
    if has(st, 21) then bd[#bd + 1] = "21" end
    if #bd > 0 then
        notes[#notes + 1] = "badsum-пара внутри нарезки + 7-шред прошла (строки " .. table.concat(bd, ", ") .. ") - механика дробилки"
    end
    if has(st, 23) then
        notes[#notes + 1] = "payload=all прошла: режется и ответ сервера (двухсторонний десинк)"
    end
    local nsd = {}
    for kn = 24, 31 do
        if has(st, kn) then nsd[#nsd + 1] = tostring(kn) end
    end
    if #nsd > 0 then
        notes[#notes + 1] = "шумовая серия дробилки прошла (строки " .. table.concat(nsd, ", ") .. ")"
    end
    local cl = {}
    if has(st, 32) then cl[#cl + 1] = "32" end
    if has(st, 33) then cl[#cl + 1] = "33" end
    if #cl > 0 then
        notes[#notes + 1] = "клон-фейк прошёл (строки " .. table.concat(cl, ", ") .. "): сильный фулинг там, где стандартный фейк детектируется"
    end
    if has(st, 34) then
        notes[#notes + 1] = "send-эхо (34) прошла: копии hello дошли до сервера, а мёртвые сегменты стали шумом для DPI"
    end
    if #st == 0 then
        notes[#notes + 1] = "если первый прогон был зелёным, а живой поток умирал через 5-15 с - ТСПУ АДАПТИВНЫЙ: подождите 5-10 минут и повторите"
    end

    -- Рекомендация: первая прошедшая строка по приоритету
    local reco, reco_args = nil, nil
    for _, rk in ipairs(PRI) do
        if has(st, rk) then reco = rk; reco_args = lst[rk]; break end
    end

    return {
        stable = st,
        verdict = verdict,
        reco = reco,
        reco_args = reco_args,
        notes = notes
    }
end

local r12 = classify("tls12")
local r13 = classify("tls13")

print(json.stringify({
    ok = true,
    catalog = n,
    matched = matched,
    tls12 = r12,
    tls13 = r13
}))
