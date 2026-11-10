-- QUIC Version Negotiation probe: определяет, проходит ли UDP/443 до YouTube.
-- Отправляем long-header пакет с зарезервированной версией; сервер отвечает
-- Version Negotiation, если QUIC-путь открыт. TLS/QUIC-клиент не нужен.
local nixio = require("nixio")
local ips = arg[1] or ""
local function probe(ip)
    local s = nixio.socket("inet", "dgram")
    if not s then return false end
    s:setopt("socket", "rcvtimeo", 2)
    local pkt = string.char(0xC0) .. string.char(0x0a, 0x0a, 0x0a, 0x0a)
        .. string.char(8) .. string.rep("A", 8)
        .. string.char(8) .. string.rep("B", 8)
        .. string.rep("\0", 1200)
    local ok = s:sendto(pkt, ip, 443)
    local resp = false
    if ok then
        local d = s:recvfrom(1500)
        resp = d ~= nil
    end
    s:close()
    return resp
end
for ip in ips:gmatch("%S+") do
    if probe(ip) then os.exit(0) end
end
os.exit(1)
