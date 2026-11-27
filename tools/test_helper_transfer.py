#!/usr/bin/env python3
"""Offline production heredoc/callpath regressions: real module, real stub-curl exits.
No helper startup, router, nft/netns mutation or external network. Requires Lua.
"""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / 'openwrt/luci-app-blockcheckw/root/usr/bin/blockcheckw-helper'
MODULE = ROOT / 'openwrt/luci-app-blockcheckw/root/usr/share/zapret2wizard/transfer_probe.lua'
PRESETS = ROOT / 'openwrt/luci-app-blockcheckw/root/usr/share/blockcheckw/zapret2_presets.json'
LUA = os.environ.get('LUA', 'lua')


def literal(v):
    if v is None: return 'nil'
    if v is True: return 'true'
    if v is False: return 'false'
    if isinstance(v, (int, float)): return str(v)
    if isinstance(v, list): return '{' + ','.join(literal(x) for x in v) + '}'
    if isinstance(v, dict): return '{' + ','.join('[' + literal(k) + ']=' + literal(x) for k, x in v.items()) + '}'
    return json.dumps(v, ensure_ascii=False)


# Only a JSON shim is mocked: production classifier, collection, policy and verdict run unchanged.
SHIM = r'''
local function enc(v)
 if v == nil then return 'null' end
 if type(v) == 'boolean' or type(v) == 'number' then return tostring(v) end
 if type(v) == 'string' then
  return '"' .. v:gsub('[%z\1-\31\\"]', function(c)
   if c == '"' then return '\\"' elseif c == '\\' then return '\\\\' end
   return string.format('\\u%04x', string.byte(c))
  end) .. '"'
 end
 local parts = {}; local array = #v > 0
 for k,x in pairs(v) do parts[#parts+1] = (array and '' or enc(tostring(k)) .. ':') .. enc(x) end
 return (array and '[' or '{') .. table.concat(parts, ',') .. (array and ']' or '}')
end
package.preload['luci.jsonc'] = function() return {parse=function() return PRESETS_DATA end,stringify=enc} end
local original_dofile = dofile
dofile = function(path) return original_dofile(MODULE_PATH) end
'''

STUB = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
url = args[-1]
fixtures = json.loads(os.environ['FIXTURES'])
f = next((v for k,v in fixtures.items() if k in url), fixtures.get('*', {}))
code = f.get('code', 200); size = f.get('size', 262144); rc = f.get('rc', 0)
length = f.get('length', size)
headers = 'HTTP/1.1 %s Fixture\r\nContent-Length: %s\r\n' % (code,length)
if code == 206:
 headers += 'Content-Range: bytes %s\r\n' % f.get('range','0-%s/%s' % (size-1,size))
headers += '\r\n'
pathlib.Path(args[args.index('--dump-header')+1]).write_text(headers)
with open(os.environ['CURL_LOG'],'a') as log: log.write(json.dumps(args)+'\n')
print('malformed' if f.get('malformed') else '\nZ2W_METRICS %s %s %s %s 0.05' % (code,size,f.get('time',2),f.get('speed',12345)))
sys.exit(rc)
'''


class Production(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = HELPER.read_text()
        cls.presets = json.loads(PRESETS.read_text())

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='z2w-helper-transfer-')
        self.addCleanup(self.tmp.cleanup)
        self.work = Path(self.tmp.name)
        (self.work / 'curl').write_text(STUB)
        (self.work / 'curl').chmod(0o755)
        # No network namespace is created: stub records exact route then execs curl.
        (self.work / 'ip').write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$IP_LOG"\nshift 3\nexec "$@"\n')
        (self.work / 'ip').chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.work)+':'+os.environ['PATH'],
                        CURL_LOG=str(self.work/'curl.log'), IP_LOG=str(self.work/'ip.log'))

    def heredoc(self, fn):
        section = self.source.split(fn+'() {',1)[1]
        return section.split("<< 'EOF'",1)[1].split('\n',1)[1].split('\nEOF',1)[0]

    def run_lua(self, fn, args, fixtures):
        self.env['FIXTURES'] = json.dumps(fixtures)
        code = 'PRESETS_DATA='+literal(self.presets)+'\nMODULE_PATH='+literal(str(MODULE))+'\n'
        code += 'arg='+literal(args)+'\n'+SHIM+'\n'+self.heredoc(fn)
        script = self.work/'run.lua'; script.write_text(code)
        p = subprocess.run([LUA,str(script)],env=self.env,capture_output=True,text=True,timeout=15)
        self.assertEqual(p.returncode,0,p.stderr)
        return json.loads(p.stdout)

    def check(self, f):
        return self.run_lua('cmd_test_impl',['preset_youtube','',str(PRESETS)],
                            {'www.youtube.com':f,'manifest.googlevideo.com':{'code':404,'size':1400},'*':{'size':5120}})

    def test_audit_partial200_exit18_and_timeout_now_fail(self):
        for rc in (18,28):
            r=self.check({'code':200,'size':980000,'length':2097152,'rc':rc})
            self.assertFalse(r['all_ok']); self.assertFalse(r['accessible'])
            self.assertEqual(r['endpoints'][0]['size_bytes'],980000)
            self.assertEqual(r['endpoints'][0]['evidence']['completeness'],'incomplete')

    def test_tiny200_is_complete_but_unverified_sample(self):
        r=self.check({'size':5120}); e=r['endpoints'][0]
        self.assertFalse(r['all_ok']); self.assertFalse(e['data_sample'])
        self.assertTrue(e['data_flow']); self.assertFalse(e['truncated'])
        self.assertEqual(e['evidence']['completeness'],'complete')
        self.assertEqual(e['stall_reason'],'insufficient_sample')

    def test_range_ignored_legitimate_short200_large_enough(self):
        r=self.check({'size':1468006,'time':8})
        self.assertTrue(r['all_ok']); self.assertEqual(r['playback'],'unknown')
        self.assertEqual(r['endpoints'][0]['evidence']['range_honored'],'ignored')
        self.assertEqual(r['budgetcap'],8388608)
        manifest=r['endpoints'][2]
        self.assertTrue(manifest['accessible']); self.assertFalse(manifest['data_flow'])
        self.assertEqual(manifest['role'],'reachability')

    def test_complete_one_mib_main_page_passes_youtube(self):
        # Главная страница YouTube не отдаёт Range и завершается штатно после
        # ~1 МБ HTML (close-delimited). Полная передача засчитывается от 256 КБ;
        # жёсткий порог 1.2 МиБ остаётся только для CDN/медиа (cmd_speedtest).
        for size in (980000,1048576):
            r=self.check({'size':size})
            self.assertTrue(r['all_ok']); self.assertFalse(r['endpoints'][0]['truncated'])
            self.assertEqual(r['endpoints'][0]['evidence']['completeness'],'complete')
            self.assertEqual(r['endpoints'][0]['verification_kind'],'page_sample')
            self.assertEqual(r['endpoints'][0]['data_sample_min_bytes'],262144)
            self.assertTrue(r['endpoints'][0]['data_sample'])
            s=self.run_lua('cmd_speedtest',['preset_youtube','',str(PRESETS)],{'*':{'size':size}})
            # 0.37.36: primary — полная страница www.youtube.com (порог 600 КБ),
            # побайтовый кап ловится клиентской объёмной пробой base.js.
            self.assertTrue(s['success']); self.assertTrue(s['attempts']['success'])

    def test_complete_under_256k_main_page_still_insufficient(self):
        r=self.check({'size':200000})
        self.assertFalse(r['all_ok'])
        self.assertEqual(r['endpoints'][0]['evidence']['completeness'],'complete')
        self.assertEqual(r['endpoints'][0]['stall_reason'],'insufficient_sample')
        self.assertFalse(r['endpoints'][0]['data_sample'])

    def test_valid206_and_short206(self):
        r=self.check({'code':206,'size':4194304,'range':'0-4194303/8000000'})
        self.assertTrue(r['all_ok'])
        short=self.check({'code':206,'size':5120,'range':'0-5119/5120'})
        self.assertFalse(short['all_ok']); self.assertFalse(short['endpoints'][0]['truncated'])

    def test_error_zero_and_empty_audit_fixtures(self):
        for f in ({'code':404,'size':1400},{'code':204,'size':0},{'code':200,'size':0}):
            r=self.check(f); self.assertFalse(r['all_ok'])
            s=self.run_lua('cmd_speedtest',['preset_youtube','',str(PRESETS)],{'*':f})
            self.assertFalse(s['success']); self.assertEqual(s['size_bytes'],f['size'])
            self.assertEqual(s['rating'],'unknown'); self.assertEqual(s['speed_kbs'],12)
            self.assertEqual(s['playback'],'unknown')

    def test_primary_failure_fallback_success_stays_failure(self):
        r=self.run_lua('cmd_speedtest',['preset_youtube','',str(PRESETS)],
                      {'www.youtube.com':{'rc':18,'size':980000,'length':2097152},'*':{'size':2097152}})
        self.assertFalse(r['success']); self.assertFalse(r['primary']['transfer_verified'])
        self.assertTrue(r['fallback']['transfer_verified']); self.assertEqual(r['size_bytes'],980000)
        self.assertIn('www.youtube.com',r['test_endpoint'])
        self.assertEqual(r['speed_cap_bytes_per_sec'],279620)

    def test_unknown_metrics_have_explicit_false_knownness(self):
        r=self.run_lua('cmd_speedtest',['preset_youtube','',str(PRESETS)],{'*':{'malformed':True}})
        for field in ('bytes_known','speed_known','elapsed_known','connect_known'):
            self.assertFalse(r[field],field)
        self.assertFalse(r['success'])
        self.assertEqual(r['size_bytes'],0)  # legacy placeholder, not measured zero
        zero=self.run_lua('cmd_speedtest',['preset_youtube','',str(PRESETS)],{'*':{'size':0,'speed':0,'time':0}})
        for field in ('bytes_known','speed_known','elapsed_known','connect_known'):
            self.assertTrue(zero[field],field)

    def test_all_fail_and_valid_primary(self):
        for rc,expected in ((28,False),(0,True)):
            r=self.run_lua('cmd_speedtest',['preset_youtube','',str(PRESETS)],{'*':{'rc':rc,'size':2097152}})
            self.assertEqual(r['success'],expected); self.assertEqual(r['rating'],'unknown')

    def test_output_netns_exact_route_adapter_and_4xx_reach_only(self):
        for mode in ('output','netns'):
            r=self.run_lua('transfer_client_probe',[mode,'youtubei.googleapis.com','192.0.2.10',
                       'https://youtubei.googleapis.com/',0,'1','bcwprobe'],{'*':{'code':404,'size':1400}})
            self.assertTrue(r['ok']); self.assertFalse(r['transfer_verified'])
            self.assertEqual(r['evidence']['path_mode'],mode)
            argv=json.loads((self.work/'curl.log').read_text().splitlines()[-1])
            self.assertIn('youtubei.googleapis.com:443:192.0.2.10',argv)
        self.assertIn('netns exec bcwprobe curl -q -4', (self.work/'ip.log').read_text())

    def test_apply_unknown_cannot_credit_scanner_trust(self):
        gate=self.source.split('    # Test connectivity with curl (Multi-Domain and Data Flow validation)',1)[1]
        gate=gate.split('    # Если трафик не подтвердился',1)[0]
        sh='''#!/bin/sh
cmd_test() { echo '{"all_ok":false,"verification_state":"unverified"}'; }
client_probe_netns() { echo '{"ok":false,"verification_state":"unknown"}'; return 1; }
client_probe_output() { echo '{"ok":false}'; return 1; }
sleep() { :; }
run_gate() {
 target="$1"; test_url=""
'''+gate+'''
printf '%s\\n' "$all_ok_val"
}
run_gate preset_youtubei
run_gate preset_youtube
'''
        script=self.work/'gate.sh'; script.write_text(sh)
        p=subprocess.run(['sh',str(script)],capture_output=True,text=True,timeout=5)
        self.assertEqual(p.returncode,0,p.stderr); self.assertEqual(p.stdout.splitlines(),['false','false'])
        self.assertNotIn('scanner-trust',gate)

    def test_delivery_includes_canonical_modules(self):
        install=(ROOT/'install.sh').read_text()
        for module in ('transfer_probe.lua','hostlist_io.sh'):
            self.assertIn('zapret2wizard/'+module,install)
            self.assertIn('transfer_probe.lua hostlist_io.sh',self.source)
        self.assertNotIn('1200)',self.heredoc('cmd_speedtest'))
        self.assertNotIn('60fps',self.heredoc('cmd_speedtest'))


if __name__ == '__main__': unittest.main(verbosity=2)
