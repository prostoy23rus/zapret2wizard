-- Run from repository root: lua tools/test_transfer_probe.lua
local M = dofile("openwrt/luci-app-blockcheckw/root/usr/share/zapret2wizard/transfer_probe.lua")
local count = 0
local function eq(a,b,label)
    count = count + 1
    assert(a == b,(label or "assertion") .. ": expected " .. tostring(b) .. ", got " .. tostring(a))
end
local function header(code,extra)
    return "HTTP/1.1 " .. code .. " fixture\r\n" .. (extra or "") .. "\r\n"
end
local function facts(code,bytes,extra,rc)
    return {curl_exit=rc or 0,http_code=code,bytes_received=bytes,headers=header(code,extra),
        elapsed_sec=0.5,speed_bytes_per_sec=123.25,byte_domain="encoded",endpoint_id="primary",attempt_id="a"}
end
local function classify(f,p) return M.classify(f,p) end
local function verdict(f,complete,verified,reason)
    local r = classify(f)
    eq(r.completeness,complete,reason)
    eq(r.transfer_verified,verified,reason)
    eq(r.playback,"unknown")
    return r
end
local r = verdict(facts(200,980000,"Content-Length: 2097152\r\n",18),"incomplete",false,"partial")
eq(r.bytes_received,980000); eq(r.termination,"partial"); eq(r.http_reachable,true)
r = verdict(facts(200,1468006,"Content-Length: 1468006\r\n"),"complete",true,"short complete")
eq(r.sample_sufficient,false); eq(r.speed_bytes_per_sec,123.25)
local f = facts(200,5120,"Content-Length: 5120\r\n")
f.requested_range={start=0,finish=4194303}
r=verdict(f,"complete",true,"range ignored complete"); eq(r.range_honored,"ignored")
f.bytes_received=50; verdict(f,"incomplete",false,"range ignored partial")
f = facts(206,5120,"Content-Length: 5120\r\nContent-Range: bytes 0-5119/5120\r\n")
f.requested_range={start=0,finish=4194303}
r=verdict(f,"complete",true,"known short tail"); eq(r.range_honored,"honored"); eq(r.sample_sufficient,false)
f.headers=header(206,"Content-Range: bytes 0-5119/10000000\r\n")
verdict(f,"unknown",false,"arbitrary shortened interval")
f.headers=header(206,"Content-Range: bytes 1-5120/10000000\r\n")
verdict(f,"unknown",false,"wrong start")
f.headers=header(206,"Content-Range: bytes 0-4194303/*\r\n")
f.bytes_received=4194304
verdict(f,"complete",true,"unknown total exact range")
f.headers=header(206,"Content-Range: bytes 0-5119/5120\r\nContent-Length: 5119\r\n")
verdict(f,"unknown",false,"range length conflict")
f.headers=header(206,"Content-Length: 5120\r\n")
verdict(f,"unknown",false,"range missing")
f.headers=header(206,"Content-Range: bytes 0-5119/5120\r\nContent-Type: multipart/byteranges; boundary=x\r\n")
verdict(f,"unknown",false,"multipart")
for _,bad in ipairs({"bytes 3-2/5","bytes 0-5/5","bytes 0-5/0","bytes 0-5/nope","bytes 0-5/9999999999999999999999999","nonsense"}) do
    verdict(facts(206,6,"Content-Range: "..bad.."\r\n"),"unknown",false,"invalid range")
end
for _,code in ipairs({204,304}) do
    r=verdict(facts(code,0,"Content-Length: 999\r\n"),"not_applicable",false,"no body")
    eq(r.bytes_received,0)
end
f=facts(200,0,"Content-Length: 999\r\n"); f.method="HEAD"
verdict(f,"not_applicable",false,"HEAD representation length")
verdict(facts(204,1),"unknown",false,"unexpected body")
verdict(facts(200,0,"Content-Length: 0\r\n"),"complete",false,"empty object")
for _,code in ipairs({403,404,421}) do
    r=verdict(facts(code,2,"Content-Length: 2\r\n"),"complete",false,"error response")
    eq(r.http_reachable,true); eq(r.reason,"http_error")
    eq(classify(facts(code,2,"Content-Length: 2\r\n"),{role="reachability"}).policy_passed,true)
end
f=facts(200,1000,"Content-Length: 1000\r\n"); f.elapsed_sec=7.5; f.speed_bytes_per_sec=0.125
r=verdict(f,"complete",true,"slow complete"); eq(r.speed_bytes_per_sec,0.125)
f=facts(200,2000000,"Content-Length: 2000000\r\n"); f.elapsed_sec=2
r=verdict(f,"complete",true,"sample"); eq(r.sample_sufficient,true)
eq(classify(f,{min_bytes=3000000}).policy_passed,false)
verdict(facts(200,100,"Transfer-Encoding: chunked\r\n"),"complete",true,"chunked complete")
r=verdict(facts(200,100),"complete",true,"close EOF"); eq(r.completeness_basis,"close-eof")
for _,rc in ipairs({18,22,28,35,60,63,127}) do
    r=verdict(facts(200,4,"Content-Length: 4\r\n",rc),"incomplete",false,"nonzero "..rc)
    eq(r.curl_exit,rc)
end
for _,bad in ipairs({"-1","nonsense","4,5","4,,4","4,","","9007199254740992"}) do
    verdict(facts(200,4,"Content-Length: "..bad.."\r\n"),"unknown",false,"invalid length")
end
verdict(facts(200,4,"Content-Length: 4\r\nContent-Length: 5\r\n"),"unknown",false,"conflicting length")
verdict(facts(200,4,"Content-Length: 4, 4\r\nContent-Length: 4\r\n"),"complete",true,"identical length")
verdict(facts(200,4,"Content-Length: 4\r\nTransfer-Encoding: chunked\r\n"),"unknown",false,"conflicting framing")
verdict(facts(200,4,"Content-Range: bytes 0-3/4\r\nContent-Range: bytes 0-2/4\r\n"),"unknown",false,"conflicting range")
f=facts(200,4,"Content-Length: 4\r\nContent-Encoding: gzip\r\n"); f.byte_domain="decoded"
verdict(f,"unknown",false,"encoding mismatch"); f.byte_domain="encoded"
verdict(f,"complete",true,"encoded bytes same domain")
f.headers="HTTP/1.1 302 Found\r\nContent-Length: 10000\r\n\r\nHTTP/1.1 100 Continue\r\n\r\n"..header(200,"Content-Length: 4\r\n")
r=verdict(f,"complete",true,"final headers"); eq(r.headers.content_length,4)
f.headers=header(200,"Content-Length: 4\r\n").."Content-Length: 999\r\n\r\n"
verdict(f,"complete",true,"trailer cannot change framing")
f.headers="HTTP/1.1 200 OK\r\nContent-Length: 4\r\n"
verdict(f,"unknown",false,"incomplete header block")
f.headers=header(200," folded: bad\r\n"); verdict(f,"unknown",false,"invalid header")
f.headers=string.rep("x",65537); verdict(f,"unknown",false,"oversized headers")
f=facts(200,4,"Content-Length: 4\r\n"); f.curl_exit=nil
r=verdict(f,"unknown",false,"exit unknown"); eq(r.curl_exit,nil)
f.curl_exit=0; f.bytes_received=nil
r=verdict(f,"unknown",false,"bytes unknown"); eq(r.bytes_known,false)
f=facts(200,4,"Content-Length: 4\r\n"); f.speed_bytes_per_sec=math.huge; f.elapsed_sec=-1
r=verdict(f,"complete",true,"bad diagnostics"); eq(r.speed_bytes_per_sec,nil); eq(r.elapsed_sec,nil)

-- Fault-inject capture I/O, not a copied implementation. Every created directory
-- must reach cleanup even when run/read throw. No shell executes in this section.
local function capture_case(output,headers,options)
    options=options or {}; local calls={}
    local io_mock={run=function(command,limit)
        calls[#calls+1]=command
        if #calls==1 then
            if options.temp_throw then error("temp failure") end
            return options.temp or "/tmp/z2w-transfer.fixture\n"
        end
        if #calls==2 then
            if options.run_throw then error("spawn failure") end
            return output,options.run_error
        end
        return options.cleanup_bad and "" or "Z2W_CLEAN\n"
    end,read_file=function(path,limit)
        eq(path,"/tmp/z2w-transfer.fixture/headers"); eq(limit,65536)
        if options.read_throw then error("read failure") end
        return headers,options.header_error
    end}
    local opts={url=options.url or "https://example.invalid/it'$(evil);x",endpoint_id="primary",attempt_id="a",timeout_sec=5}
    local result=M.probe(opts,nil,io_mock)
    return result,calls
end
local metrics="\nZ2W_METRICS 200 4 0.500000 8.000 0.010\nZ2W_EXIT 0\n"
r,calls=capture_case(metrics,header(200,"Content-Length: 4\r\n"))
eq(r.transfer_verified,true); eq(r.curl_exit,0); eq(r.bytes_received,4); eq(r.cleanup_ok,true)
eq(r.endpoint_id,"primary"); eq(r.attempt_id,"a"); eq(#calls,3)
assert(calls[2]:find("'https://example.invalid/it'\\''$(evil);x'",1,true))
assert(calls[2]:find("--output /dev/null",1,true))
assert(calls[2]:find("--proto-redir '=http,https'",1,true))
assert(not calls[2]:find("--insecure",1,true)); assert(not calls[2]:find(" -k",1,true))
for _,out in ipairs({"","\nZ2W_METRICS 200 4 0.5 8 0.01\n","junk\nZ2W_EXIT 0\n","\nZ2W_METRICS 200 4 0.5 8 0.01\njunk\nZ2W_EXIT 0\n"}) do
    r=capture_case(out,header(200,"Content-Length: 4\r\n")); eq(r.transfer_verified,false); eq(r.completeness,"unknown")
end
r=capture_case("\nZ2W_METRICS 200 4 0.5 8 0.01\n",header(200,"Content-Length: 4\r\n"))
eq(r.bytes_received,4); eq(r.http_code,200); eq(r.curl_exit,nil); eq(r.transfer_verified,false)
r=capture_case(metrics,header(200,"Content-Length: 4\r\nSet-Cookie: secret\r\n"))
eq(r.headers.fields,nil)
r=capture_case(metrics,nil,{header_error="headers_unreadable"}); eq(r.reason,"headers_unreadable")
r,calls=capture_case(metrics,nil,{read_throw=true}); eq(r.transfer_verified,false); eq(#calls,3)
r,calls=capture_case(nil,nil,{run_throw=true}); eq(r.reason,"capture_failed"); eq(#calls,3)
r=capture_case(metrics,header(200,"Content-Length: 4\r\n"),{cleanup_bad=true}); eq(r.reason,"cleanup_failed")
r=capture_case(metrics,nil,{temp_throw=true}); eq(r.reason,"tempdir_failed")
r=capture_case(metrics,nil,{temp="/tmp/not-owned\n"}); eq(r.reason,"tempdir_failed")
r=capture_case(metrics:gsub("EXIT 0","EXIT 18"),header(200,"Content-Length: 10\r\n")); eq(r.termination,"partial")
for _,url in ipairs({"file:///etc/passwd","ftp://example.invalid","https://x\n--insecure","https://x\000bad","--help","https://"}) do
    local result=M.probe({url=url},nil,{run=function() error("must not spawn") end})
    eq(result.reason,"invalid_url")
end
f=facts(200,4,"Content-Length: 4\r\n"); f.max_bytes=3
r=verdict(f,"incomplete",false,"observed budget overflow"); eq(r.termination,"caller_limit"); eq(r.reason,"byte_budget_exceeded")
for _,opts in ipairs({{url="https://x",timeout_sec=0},{url="https://x",max_bytes=math.huge},{url="https://x",method="POST"},{url="https://x",range={start=5,finish=1}}}) do
    eq(M.probe(opts,nil,{run=function() error("must not spawn") end}).transfer_verified,false)
end
local primary=classify(facts(404,2,"Content-Length: 2\r\n"))
local fallback=classify(facts(200,4,"Content-Length: 4\r\n")); fallback.endpoint_id="fallback"
r=M.attempts(primary,fallback)
eq(r.success,false); eq(r.transfer_verified,false); eq(r.primary,primary); eq(r.fallback,fallback)
eq(r.primary.endpoint_id,"primary"); eq(r.fallback.endpoint_id,"fallback"); eq(r.playback,"unknown")
eq(M.attempts(primary,primary).success,false)
print("transfer_probe: "..count.." assertions passed (".._VERSION..")")
