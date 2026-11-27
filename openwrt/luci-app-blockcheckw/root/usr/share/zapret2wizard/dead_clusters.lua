-- dead_clusters.lua: pure helpers for the googlevideo dead-cluster module.
-- No LuCI dependencies: parse hosts from HTML and build nft elements.
local M = {}

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function is_ipv4(s)
    local a, b, c, d = tostring(s or ""):match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not a then return false end
    for _, n in ipairs({ a, b, c, d }) do
        n = tonumber(n)
        if not n or n > 255 then return false end
    end
    return true
end

-- YouTube watch HTML -> unique googlevideo sn hosts (rrN---sn-...).
function M.parse_hosts(text)
    local seen, out = {}, {}
    -- Lua patterns cannot make a capture group optional; match a full token
    -- and keep only real sn hosts (rrN---sn-... or sn-...).
    for h in tostring(text or ""):lower():gmatch("([%w%-]+%.googlevideo%.com)") do
        if (h:match("^rr%d+%-%-%-sn%-[%w%-]+%.googlevideo%.com$") or h:match("^sn%-[%w%-]+%.googlevideo%.com$")) and not seen[h] then
            seen[h] = true
            out[#out + 1] = h
        end
    end
    return out
end

function M.read_list(path)
    local out, f = {}, io.open(path, "r")
    if not f then return out end
    for line in f:lines() do
        line = trim(line)
        if is_ipv4(line) then out[#out + 1] = line end
    end
    f:close()
    return out
end

-- A /24 is blocked only when it has >=2 dead IPs and 0 alive IPs.
-- All other dead IPs are blocked as /32. Freeze is decided by the caller
-- (this function has no side effects and never invents liveness).
function M.build(dead, alive, max_elements)
    max_elements = tonumber(max_elements) or 512
    local seen_d, dl = {}, {}
    for _, ip in ipairs(dead or {}) do
        if not seen_d[ip] then seen_d[ip] = true; dl[#dl + 1] = ip end
    end
    local seen_a, al = {}, {}
    for _, ip in ipairs(alive or {}) do
        if not seen_a[ip] then seen_a[ip] = true; al[#al + 1] = ip end
    end

    local dead_by24, alive_by24 = {}, {}
    for _, ip in ipairs(dl) do
        local net = ip:match("^(%d+%.%d+%.%d+)%.")
        dead_by24[net] = (dead_by24[net] or 0) + 1
    end
    for _, ip in ipairs(al) do
        local net = ip:match("^(%d+%.%d+%.%d+)%.")
        alive_by24[net] = (alive_by24[net] or 0) + 1
    end

    local subnets, singles = {}, {}
    for net, count in pairs(dead_by24) do
        if count >= 2 and (alive_by24[net] or 0) == 0 then
            subnets[#subnets + 1] = net .. ".0/24"
        end
    end
    table.sort(subnets)
    for _, ip in ipairs(dl) do
        local net = ip:match("^(%d+%.%d+%.%d+)%.")
        if not (dead_by24[net] >= 2 and (alive_by24[net] or 0) == 0) then
            singles[#singles + 1] = ip
        end
    end
    table.sort(singles)

    local elements, capped = {}, 0
    for _, e in ipairs(subnets) do
        if #elements < max_elements then elements[#elements + 1] = e else capped = 1 end
    end
    for _, e in ipairs(singles) do
        if #elements < max_elements then elements[#elements + 1] = e else capped = 1 end
    end
    return elements, {
        alive = #al, dead = #dl,
        subnets = #subnets, singles = #singles,
        elements = #elements, capped = capped,
    }
end

-- CLI: hosts <html-file> | build <dead-file> <alive-file> [max-elements]
local mode = arg and arg[1] or ""
if mode == "hosts" then
    local f = io.open(arg[2] or "", "r")
    local text = f and f:read("*a") or ""
    if f then f:close() end
    for _, h in ipairs(M.parse_hosts(text)) do print(h) end
elseif mode == "build" then
    local dead = M.read_list(arg[2] or "")
    local alive = M.read_list(arg[3] or "")
    local elements, s = M.build(dead, alive, arg[4])
    print("alive=" .. tostring(s.alive))
    print("dead=" .. tostring(s.dead))
    print("subnets=" .. tostring(s.subnets))
    print("singles=" .. tostring(s.singles))
    print("elements=" .. tostring(s.elements))
    print("capped=" .. tostring(s.capped))
    for _, e in ipairs(elements) do print("element=" .. e) end
else
    io.stderr:write("usage: dead_clusters.lua hosts <file> | build <dead> <alive> [max]\n")
    os.exit(1)
end
