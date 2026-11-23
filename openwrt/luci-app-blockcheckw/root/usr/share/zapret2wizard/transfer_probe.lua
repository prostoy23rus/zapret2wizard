-- Lua 5.1; no LuCI dependency. Transfer evidence is NOT playback proof.
-- capture(opts[, trusted_test_io]) -> facts; classify(facts[, policy]) -> result;
-- probe(opts[, policy[, trusted_test_io]]) -> result; attempts(primary, fallback).
-- opts: url, endpoint_id, attempt_id, role, path_mode, method (GET/HEAD),
-- range={start,finish}, timeout_sec (1..120), max_bytes (1..16777216).
-- policy: role (reachability/bounded_data/media), min_bytes (default 1),
-- sample_bytes (default 1048576), sample_seconds (default 1).
local M = {}
local HEADER_LIMIT, OUTPUT_LIMIT = 65536, 4096
local function number(value)
    if type(value) ~= "number" and type(value) ~= "string" then return nil end
    local n = tonumber(value)
    if not n or n ~= n or n < 0 or n == math.huge then return nil end
    return n
end
local function integer(value)
    local n = number(value)
    if n and n <= 9007199254740991 and n == math.floor(n) then return n end
end
local function decimal(value)
    if type(value) ~= "string" or not value:match("^%d+$") then return nil end
    return integer(value)
end
local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
local function quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local function copy(source)
    local out = {}; for k,v in pairs(source or {}) do out[k] = v end; return out
end

-- Select the final complete HTTP header block, never redirect/interim lengths.
-- Trailers cannot replace framing; invalid final headers fail closed.
function M.parse_headers(raw)
    if type(raw) ~= "string" then return { state = "missing" } end
    if #raw > HEADER_LIMIT then return { state = "truncated" } end
    local final, current
    for line in raw:gmatch("([^\n]*)\n") do
        line = line:gsub("\r$", "")
        local code = line:match("^HTTP/%d[%.%d]*%s+(%d%d%d)%s") or line:match("^HTTP/%d[%.%d]*%s+(%d%d%d)$")
        if code then
            current = { state = "incomplete", http_code = tonumber(code), fields = {} }
            final = current
        elseif current and line == "" then
            current.state = current.invalid and "invalid" or "valid"
            current = nil
        elseif current then
            local name, value = line:match("^([^:%s]+):%s*(.-)%s*$")
            if not name or name:find("[^!#$%%&'*+%.%^_\096|~%w-]") or
                value:find("[%z\1-\8\11\12\14-\31\127]") then
                current.invalid = true
            else
                name = name:lower()
                local values = current.fields[name] or {}
                values[#values+1] = value
                current.fields[name] = values
            end
        end
    end
    if not final then return { state = "missing" } end
    local fields = final.fields
    local function unique(name)
        local values = fields[name]; if not values then return nil, "absent" end
        local first = trim(values[1]):lower()
        for _,v in ipairs(values) do if trim(v):lower() ~= first then return nil, "conflicting" end end
        return first, "valid"
    end
    local lengths = fields["content-length"]
    final.content_length_state = "absent"
    if lengths then
        local expected
        final.content_length_state = "valid"
        for _,line in ipairs(lengths) do
            if trim(line) == "" or line:match("^%s*,") or line:match(",%s*$") or line:match(",%s*,") then
                final.content_length_state = "invalid"
            end
            for token in line:gmatch("[^,]+") do
                local n = decimal(trim(token))
                if not n then final.content_length_state = "invalid"
                elseif expected and expected ~= n then final.content_length_state = "conflicting"
                else expected = n end
            end
        end
        if final.content_length_state == "valid" then final.content_length = expected end
    end
    local range, rs = unique("content-range")
    final.content_range_state = rs
    if range then
        local a,b,total = range:match("^bytes (%d+)%-(%d+)/(%d+)$")
        if not a then a,b = range:match("^bytes (%d+)%-(%d+)/%*$") end
        local total_text = total
        a,b,total = decimal(a),decimal(b),decimal(total)
        if a and b and b >= a and (not total_text or total) and (not total or b < total) then
            final.content_range = { start = a, finish = b, total = total }
        else final.content_range_state = "invalid" end
    end
    final.content_encoding, final.content_encoding_state = unique("content-encoding")
    final.transfer_encoding, final.transfer_encoding_state = unique("transfer-encoding")
    final.content_type, final.content_type_state = unique("content-type")
    final.framing = final.content_length_state == "valid" and "content-length" or "close-delimited"
    if final.transfer_encoding then
        final.framing = final.transfer_encoding == "chunked" and "chunked" or "unknown"
        if lengths then final.framing = "unknown" end
    end
    final.fields = nil -- Never propagate redirect locations, cookies or unrelated headers.
    return final
end

function M.classify(facts, policy)
    facts, policy = facts or {}, policy or {}
    local r = copy(facts)
    local h = type(facts.headers) == "table" and facts.headers or M.parse_headers(facts.headers)
    r.headers = h
    r.curl_exit = integer(facts.curl_exit)
    if r.curl_exit and r.curl_exit > 255 then r.curl_exit = nil end
    r.bytes_received = integer(facts.bytes_received)
    r.bytes_known = r.bytes_received ~= nil
    r.elapsed_sec = number(facts.elapsed_sec)
    r.speed_bytes_per_sec = number(facts.speed_bytes_per_sec)
    r.connect_sec = number(facts.connect_sec)
    r.http_code = integer(facts.http_code)
    if not r.http_code or r.http_code < 100 or r.http_code > 599 then r.http_code = nil end
    r.http_reachable = r.http_code ~= nil and h.state == "valid" and h.http_code == r.http_code
    r.status_known = r.http_code ~= nil
    r.transfer_verified, r.policy_passed = false, false
    r.playback = "unknown"
    r.termination, r.completeness, r.completeness_basis = "unknown", "unknown", "none"
    r.sample_sufficient = false
    r.range_honored = r.http_code == 200 and facts.requested_range and "ignored" or "not_requested"
    local function finish(reason)
        r.reason = reason
        local role = policy.role or facts.role or "bounded_data"
        if role == "reachability" then
            r.policy_passed = r.http_reachable and r.curl_exit == 0 and
                (r.completeness == "complete" or r.completeness == "not_applicable")
        end
        return r
    end
    if r.curl_exit == nil then return finish(facts.capture_error or "exit_unknown") end
    if r.curl_exit ~= 0 then
        if r.curl_exit == 18 then r.termination = "partial"
        elseif r.curl_exit == 28 then r.termination = "timeout"
        elseif r.curl_exit == 63 then r.termination = "caller_limit"
        else r.termination = "transport_error" end
        r.completeness = "incomplete"
        return finish("curl_exit_" .. r.curl_exit)
    end
    if facts.capture_error then return finish(facts.capture_error) end
    local max_bytes = integer(facts.max_bytes)
    if max_bytes and r.bytes_known and r.bytes_received > max_bytes then
        r.termination, r.completeness = "caller_limit", "incomplete"
        return finish("byte_budget_exceeded")
    end
    if not r.http_reachable then return finish("headers_or_status_unknown") end
    if not r.bytes_known then return finish("bytes_unknown") end
    if h.content_length_state == "invalid" or h.content_length_state == "conflicting" or
        h.content_range_state == "invalid" or h.content_range_state == "conflicting" or
        h.content_encoding_state == "conflicting" or h.transfer_encoding_state == "conflicting" or
        h.content_type_state == "conflicting" then return finish("ambiguous_headers") end
    if facts.byte_domain ~= "wire" and facts.byte_domain ~= "encoded" and
        h.content_encoding and h.content_encoding ~= "identity" then return finish("encoding_domain_unknown") end
    local no_body = facts.method == "HEAD" or r.http_code == 204 or r.http_code == 304
    if no_body then
        if r.bytes_received ~= 0 then return finish("unexpected_body") end
        r.termination, r.completeness, r.completeness_basis = "completed", "not_applicable", "no-body"
        return finish("no_body")
    end
    if h.framing == "unknown" then return finish("ambiguous_framing") end
    local expected = h.content_length
    if r.http_code == 206 then
        local cr, req = h.content_range, facts.requested_range
        if not cr then return finish("content_range_required") end
        if h.content_type and h.content_type:match("^multipart/byteranges") then return finish("multipart_unsupported") end
        if req then
            local a,b = integer(req.start),integer(req.finish)
            if not a or not b or b < a then return finish("request_range_invalid") end
            local last = cr.total and math.min(b, cr.total - 1) or b
            if cr.start ~= a or cr.finish ~= last then return finish("returned_range_mismatch") end
            r.range_honored = "honored"
        else r.range_honored = "unsolicited" end
        local length = cr.finish - cr.start + 1
        if expected and expected ~= length then return finish("range_length_conflict") end
        expected, r.completeness_basis = length, "content-range"
    elseif expected then r.completeness_basis = "content-length"
    else r.completeness_basis = h.framing == "chunked" and "protocol-end" or "close-eof" end
    if expected and r.bytes_received ~= expected then
        r.termination, r.completeness = "partial", "incomplete"
        return finish("body_length_mismatch")
    end
    r.termination, r.completeness = "completed", "complete"
    if r.http_code < 200 or r.http_code >= 300 then return finish("http_error") end
    local min_bytes = integer(policy.min_bytes) or 1
    if r.bytes_received < math.max(1,min_bytes) then return finish("insufficient_data") end
    -- Only this finite response/interval is verified, not media authenticity.
    r.transfer_verified, r.policy_passed = true, true
    r.sample_sufficient = r.bytes_received >= (integer(policy.sample_bytes) or 1048576) and
        r.elapsed_sec ~= nil and r.elapsed_sec >= (number(policy.sample_seconds) or 1)
    return finish("transfer_complete")
end

local function read_file(path, limit)
    local f = io.open(path,"rb"); if not f then return nil,"headers_unreadable" end
    local ok,data = pcall(function() return f:read(limit + 1) end)
    f:close()
    if not ok or type(data) ~= "string" then return nil,"headers_unreadable" end
    if #data > limit then return nil,"headers_truncated" end
    return data
end
local function popen_read(command, limit)
    local ok,p = pcall(io.popen,command,"r")
    if not ok or not p then return nil,"spawn_failed" end
    local good,data = pcall(function() return p:read(limit + 1) end)
    pcall(function() p:close() end) -- Do not infer rc from Lua 5.1 pipe close.
    if not good or type(data) ~= "string" then return nil,"output_unreadable" end
    if #data > limit then return nil,"output_truncated" end
    return data
end

function M.capture(opts, injected)
    opts, injected = opts or {}, injected or {}
    local f = { endpoint_id = opts.endpoint_id, attempt_id = opts.attempt_id,
        role = opts.role, path_mode = opts.path_mode or "router", method = opts.method or "GET",
        requested_range = opts.range, byte_domain = "encoded" }
    local url = opts.url
    if type(url) ~= "string" or #url > 8192 or url:find("[%z\1-\32\127]") or
        not url:lower():match("^https?://[^/]+") then f.capture_error = "invalid_url"; return f end
    if f.method ~= "GET" and f.method ~= "HEAD" then f.capture_error = "invalid_method"; return f end
    local timeout = integer(opts.timeout_sec or 15)
    local budget = integer(opts.max_bytes or 4194304)
    if not timeout or timeout < 1 or timeout > 120 or not budget or budget < 1 or budget > 16777216 then
        f.capture_error = "invalid_budget"; return f
    end
    f.max_bytes = budget
    f.budget_enforcement = "curl-max-filesize-and-time-rate"
    local range_arg = ""
    if opts.range then
        local a,b = integer(opts.range.start),integer(opts.range.finish)
        if not a or not b or b < a or b-a+1 > budget then f.capture_error = "invalid_range"; return f end
        range_arg = " --range " .. a .. "-" .. b
    end
    local run = injected.run or popen_read
    local get_headers = injected.read_file or read_file
    local dir_ok,dir,err = pcall(run,"umask 077; mktemp -d /tmp/z2w-transfer.XXXXXX",128)
    if not dir_ok then f.capture_error = "tempdir_failed"; return f end
    dir = dir and dir:match("^(/tmp/z2w%-transfer%.[%w]+)\n?$")
    if not dir then f.capture_error = err or "tempdir_failed"; return f end
    local header_path = dir .. "/headers"
    -- File-size ulimit bounds scratch headers on old curl; never store bodies.
    -- Time + rate also bound unknown-length transfers on old curl versions whose
    -- max-filesize only checks a declared Content-Length (one curl read may overshoot).
    f.speed_cap_bytes_per_sec = math.max(1,math.floor(budget/timeout))
    local command = "(umask 077; ulimit -f 128 || exit 125; curl -q --globoff --silent --show-error" ..
        " --location --max-redirs 5 --proto '=http,https' --proto-redir '=http,https'" ..
        " --connect-timeout " .. math.min(timeout,10) .. " --max-time " .. timeout ..
        " --max-filesize " .. budget .. " --limit-rate " .. math.max(1,math.floor(budget/timeout)) ..
        " --header 'Accept-Encoding: identity' --dump-header " .. quote(header_path) ..
        " --output /dev/null" .. (f.method == "HEAD" and " --head" or "") .. range_arg ..
        " --write-out '\\nZ2W_METRICS %{http_code} %{size_download} %{time_total} %{speed_download} %{time_connect}\\n'" ..
        " -- " .. quote(url) .. " 2>/dev/null; rc=$?; printf 'Z2W_EXIT %s\\n' \"$rc\")"
    local ok,output,run_err = pcall(run,command,OUTPUT_LIMIT)
    local hok,headers,header_err = pcall(get_headers,header_path,HEADER_LIMIT)
    -- Only generated paths within the validated private directory are removed.
    local cleanup_ok,cleanup = pcall(run,"rm -f " .. quote(header_path) .. "; rmdir " .. quote(dir) ..
        " && printf 'Z2W_CLEAN\\n'",128)
    f.cleanup_ok = cleanup_ok and cleanup == "Z2W_CLEAN\n"
    if not ok then f.capture_error = "capture_failed"
    elseif not output then f.capture_error = run_err or "output_unreadable"
    else
        local code,bytes,elapsed,speed,connect = output:match(
            "^\nZ2W_METRICS (%d%d%d) ([%d%.]+) ([%d%.]+) ([%d%.]+) ([%d%.]+)\n")
        local rc = output:match("\nZ2W_EXIT (%d+)\n$")
        -- Malformed/missing metrics can still leave a trustworthy exit trailer.
        f.curl_exit = decimal(rc)
        f.http_code, f.bytes_received = decimal(code),integer(bytes)
        f.elapsed_sec, f.speed_bytes_per_sec, f.connect_sec = number(elapsed),number(speed),number(connect)
        local metrics_line = output:match("^(\nZ2W_METRICS [^\n]+\n)")
        if not rc or not code or output ~= metrics_line .. "Z2W_EXIT " .. rc .. "\n" then
            f.capture_error = "metrics_or_exit_unknown"
        end
    end
    if hok and headers then f.headers = M.parse_headers(headers)
    else f.capture_error = f.capture_error or (hok and header_err) or "headers_unreadable" end
    if not f.cleanup_ok then f.capture_error = f.capture_error or "cleanup_failed" end
    return f
end
function M.probe(opts, policy, injected) return M.classify(M.capture(opts,injected),policy) end
-- Aggregation only: never substitute fallback identity or verdict for primary.
function M.attempts(primary, fallback)
    return { primary = primary, fallback = fallback, success = primary and primary.policy_passed == true or false,
        transfer_verified = primary and primary.transfer_verified == true or false, playback = "unknown" }
end
return M
