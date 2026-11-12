-- Память стратегий: L1 домен, L2 /24, L3 статистика рецептов, бан-маска.
local json = require("luci.jsonc")
local FILE = "/etc/zapret2wizard/strategy_memory.json"
local TTL = 7 * 24 * 3600
local BAN_TTL = 7 * 24 * 3600
local a = { ... }
local cmd = a[1] or "stats"

local function load()
    local d = { domains = {}, subnets = {}, recipes = {}, banned = {} }
    local f = io.open(FILE, "r")
    if f then
        local ok, parsed = pcall(json.parse, f:read("*a"))
        f:close()
        if ok and type(parsed) == "table" then
            d.domains = parsed.domains or {}
            d.subnets = parsed.subnets or {}
            d.recipes = parsed.recipes or {}
            d.banned = parsed.banned or {}
        end
    end
    return d
end

local function save(d)
    local f = io.open(FILE, "w")
    if not f then return false end
    f:write(json.stringify(d))
    f:close()
    return true
end

local function normalize(s)
    s = tostring(s or ""):gsub("%s+", " ")
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    return s
end

local function h(s)
    local x = 5381
    s = normalize(s)
    for i = 1, #s do x = (x * 33 + s:byte(i)) % 2147483647 end
    return "h" .. tostring(x)
end

local function ip24(ip)
    if not ip then return nil end
    local p = ip:match("^(%d+%.%d+%.%d+)%.")
    return p and (p .. ".0/24") or nil
end

local function now() return os.time() end
local function fresh(e)
    return e and e.ts and (now() - e.ts) <= TTL
end

local function out(t) print(json.stringify(t)) end

if cmd == "stats" then
    local d = load()
    local nd, ns, nr, nb = 0, 0, 0, 0
    for _ in pairs(d.domains) do nd = nd + 1 end
    for _ in pairs(d.subnets) do ns = ns + 1 end
    for _ in pairs(d.recipes) do nr = nr + 1 end
    for _, list in pairs(d.banned) do nb = nb + #list end
    out({ domains = nd, subnets = ns, recipes = nr, banned = nb, ttl = TTL })
elseif cmd == "get" then
    local dom, ip = a[2] or "", a[3] or ""
    local d = load()
    local e = d.domains[dom]
    if fresh(e) and e.verified and e.recipe and e.recipe ~= "" then
        out({ recipe = e.recipe, source = "L1", ts = e.ts })
        return
    end
    local net = ip24(ip)
    local s = net and d.subnets[net] or nil
    if fresh(s) and s.recipe and s.recipe ~= "" then
        out({ recipe = s.recipe, source = "L2", ts = s.ts, net = net })
        return
    end
    out({})
elseif cmd == "put" then
    local dom, ip, recipe, ok = a[2] or "", a[3] or "", a[4] or "", a[5] or "1"
    local ms = tonumber(a[6]) or 0
    if dom == "" or recipe == "" then out({ ok = false, error = "domain/recipe required" }) return end
    local d = load()
    local net = ip24(ip)
    d.domains[dom] = { recipe = recipe, ts = now(), ip = ip, net = net, verified = (ok == "1"), fails = 0 }
    if net then d.subnets[net] = { recipe = recipe, ts = now() } end
    local key = h(recipe)
    if ok == "1" and d.banned[dom] then
        local kept = {}
        for _, v in ipairs(d.banned[dom]) do
            local vh = (type(v) == "table") and v.h or v
            if vh ~= key then table.insert(kept, v) end
        end
        d.banned[dom] = kept
    end
    local r = d.recipes[key] or { args = normalize(recipe), ok = 0, fail = 0 }
    if ok == "1" then r.ok = (r.ok or 0) + 1 else r.fail = (r.fail or 0) + 1 end
    if ms > 0 then
        if r.ewma and r.ewma > 0 then r.ewma = math.floor(0.3 * ms + 0.7 * r.ewma) else r.ewma = math.floor(ms) end
    end
    r.ts = now()
    d.recipes[key] = r
    out({ ok = save(d), source = net and "L1+L2" or "L1" })
elseif cmd == "ban" then
    local dom, recipe = a[2] or "", a[3] or ""
    local reason = a[4] or ""
    if dom == "" or recipe == "" then out({ ok = false }) return end
    local d = load()
    local list = d.banned[dom] or {}
    local kh = h(recipe)
    local kept = {}
    local prev = nil
    for _, v in ipairs(list) do
        local vh = (type(v) == "table") and v.h or v
        if vh == kh then prev = v else table.insert(kept, v) end
    end
    local fails = 1
    if type(prev) == "table" and prev.fails then fails = (prev.fails or 1) + 1 end
    table.insert(kept, 1, { h = kh, ts = now(), reason = reason, args = normalize(recipe), fails = fails })
    while #kept > 32 do table.remove(kept) end
    d.banned[dom] = kept
    local key = h(recipe)
    local r = d.recipes[key] or { args = normalize(recipe), ok = 0, fail = 0 }
    r.fail = (r.fail or 0) + 1
    r.ts = now()
    d.recipes[key] = r
    out({ ok = save(d), banned = #list })
elseif cmd == "fail" then
    local dom = a[2] or ""
    local d = load()
    local e = d.domains[dom]
    if not e or not e.recipe then out({ stale = false, tracked = false }) return end
    e.fails = (e.fails or 0) + 1
    local stale = false
    if e.fails >= 2 then
        e.verified = false
        e.fails = 0
        stale = true
        if e.net and d.subnets[e.net] then d.subnets[e.net] = nil end
    end
    d.domains[dom] = e
    save(d)
    out({ stale = stale, tracked = true, fails = e.fails })
elseif cmd == "filter" then
    local file, dom = a[2] or "", a[3] or ""
    local d = load()
    local banned = {}
    for _, item in ipairs(d.banned[dom] or {}) do
        local kh = (type(item) == "table") and item.h or item
        local ts = (type(item) == "table") and (item.ts or 0) or 0
        local active = (ts == 0) or ((now() - ts) <= BAN_TTL)
        if kh and active then banned[kh] = true end
    end
    local removed = 0
    local f = io.open(file, "r")
    if not f then out({ removed = 0 }); return end
    local lines = {}
    for line in f:lines() do
        local args = line:match(": nfqws2%s+(.+)$")
        if args and banned[h(args)] then
            removed = removed + 1
        else
            table.insert(lines, line)
        end
    end
    f:close()
    if removed > 0 then
        local o = io.open(file, "w")
        if o then o:write(table.concat(lines, "\n") .. "\n"); o:close() end
    end
    out({ removed = removed })
elseif cmd == "forget" then
    local dom = a[2] or ""
    local d = load()
    local e = d.domains[dom]
    if e and e.net and d.subnets[e.net] then d.subnets[e.net] = nil end
    d.domains[dom] = nil
    save(d)
    out({ ok = true, domain = dom })
elseif cmd == "rank" then
    local file = a[2] or ""
    local d = load()
    local f = io.open(file, "r")
    if not f then out({ ranked = 0 }); return end
    local comments, items = {}, {}
    local idx = 0
    for line in f:lines() do
        idx = idx + 1
        local args = line:match(": nfqws2%s+(.+)$")
        if args then
            local r = d.recipes[h(args)]
            local ok = (r and r.ok) or 0
            local fail = (r and r.fail) or 0
            -- Laplace-успех, умноженный на скоростной вес: EWMA 300 мс и
            -- быстрее — полный вес, 3000 мс — примерно 0.67.
            local base = (ok + 1) / (ok + fail + 2)
            local ewma = (r and r.ewma) or 0
            local speed = 1
            if ewma > 0 then
                speed = 1000 / math.max(ewma, 100)
                if speed > 1 then speed = 1 end
            end
            local score = base * (0.5 + 0.5 * speed)
            table.insert(items, { line = line, score = score, idx = idx })
        else
            table.insert(comments, line)
        end
    end
    f:close()
    table.sort(items, function(x, y)
        if math.abs(x.score - y.score) > 1e-9 then return x.score > y.score end
        return x.idx < y.idx
    end)
    local o = io.open(file, "w")
    if o then
        for _, c in ipairs(comments) do o:write(c .. "\n") end
        for _, it in ipairs(items) do o:write(it.line .. "\n") end
        o:close()
    end
    out({ ranked = #items })
elseif cmd == "ewma_filter" then
    local file, max_ms = a[2] or "", tonumber(a[3]) or 3000
    local d = load()
    local f = io.open(file, "r")
    if not f then out({ removed = 0 }); return end
    local kept, removed = {}, 0
    for line in f:lines() do
        local args = line:match(": nfqws2%s+(.+)$")
        local drop = false
        if args then
            local r = d.recipes[h(args)]
            if r and r.ewma and r.ewma > 0 and ((r.ok or 0) + (r.fail or 0)) >= 2 and r.ewma > max_ms then
                drop = true
                removed = removed + 1
            end
        end
        if not drop then table.insert(kept, line) end
    end
    f:close()
    if removed > 0 then
        local o = io.open(file, "w")
        if o then o:write(table.concat(kept, "\n") .. "\n"); o:close() end
    end
    out({ removed = removed, max_ms = max_ms })
elseif cmd == "clear" then
    os.remove(FILE)
    out({ ok = true })
elseif cmd == "dump" then
    out(load())
else
    out({ error = "unknown command" })
end
