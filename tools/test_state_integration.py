#!/usr/bin/env python3
"""Offline actual-production-function regressions; no router/network or helper startup.
Run under Linux/WSL: python3 tools/test_state_integration.py. Lua + dkjson required.
Only JSON adapter, UCI, apply/probe endpoints, restart and timing are mocked.
"""
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / 'openwrt/luci-app-blockcheckw/root/usr/bin/blockcheckw-helper'
LIFECYCLE = ROOT / 'openwrt/luci-app-blockcheckw/root/usr/share/zapret2wizard/lifecycle.sh'
SOURCE = HELPER.read_text()


def function(name):
    start = SOURCE.index(name + '() {')
    end = SOURCE.index('\n}\n', start) + 3
    return SOURCE[start:end]


def block(start, end):
    begin = SOURCE.index(start)
    return SOURCE[begin:SOURCE.index(end, begin)]


APPLY_STUB = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
p=pathlib.Path(os.environ['STATE']); s=json.loads(p.read_text()); a=sys.argv[1:]
target=a[a.index('--target')+1]
recipe=a[a.index('--script')+1] if '--script' in a else pathlib.Path(a[a.index('--file')+1]).read_text().strip()
s['attempts'].append(recipe)
accepted=recipe.startswith('--lua-desync=multisplit')
if os.environ.get('FAIL_REAPPLY') == '1' and s['attempts'].count(recipe)>1: accepted=False
if accepted: s['active']=recipe
p.write_text(json.dumps(s))
print(json.dumps(dict(success=accepted,accepted=accepted,all_ok=accepted,rolled_back=not accepted,
                     target=target,accepted_recipe=recipe.strip() if accepted else None,size_bytes=99)))
sys.exit(0 if accepted else 1)
'''


class StateIntegration(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='z2w-state-'); self.addCleanup(self.tmp.cleanup)
        self.work=Path(self.tmp.name)
        self.shim=self.work/'json-shim.lua'
        self.shim.write_text("package.preload['luci.jsonc']=function() local j=require('dkjson'); return {parse=j.decode,stringify=function(v) return j.encode(v) end} end\n")
        self.env=dict(os.environ, LUA_INIT='@'+str(self.shim), STATE=str(self.work/'state.json'))
        self.state={'attempts':[], 'active':'prior'}; self.save()
        self.fixture=self.work/'apply'; self.fixture.write_text(APPLY_STUB); self.fixture.chmod(0o755)

    def save(self): (self.work/'state.json').write_text(json.dumps(self.state))
    def current(self): return json.loads((self.work/'state.json').read_text())
    def shell(self, code, definitions='', env=None):
        script=definitions+'\nrun() {\n'+code+'\n}\nrun\n'
        r=subprocess.run(['busybox','sh','-c',script],cwd=self.work,env=env or self.env,text=True,capture_output=True,timeout=15)
        return r
    def ok(self, r): self.assertEqual(r.returncode,0,r.stdout+r.stderr)

    def test_canonical_acceptance_binds_identity_and_rejects_nested_flags(self):
        good=dict(success=True,accepted=True,all_ok=True,rolled_back=False,target='preset_discord',accepted_recipe='--B')
        defs=function('bcw_apply_accepted')
        for change in ({},{'accepted_recipe':'--A'},{'target':'preset_youtube'},{'rolled_back':True},{'all_ok':False},{'accepted':None}):
            value=dict(good,**change)
            r=self.shell('bcw_apply_accepted '+shlex.quote(json.dumps(value))+" preset_discord --B",defs)
            self.assertEqual(r.returncode==0,not change,value)
        r=self.shell("bcw_apply_accepted '{bad}' preset_discord --B",defs); self.assertNotEqual(r.returncode,0)
        r=self.shell('bcw_apply_accepted '+shlex.quote(json.dumps({'multi_domain':good}))+" preset_discord --B",defs)
        self.assertNotEqual(r.returncode,0)

    def autoapply(self, fail=False):
        self.env['FAIL_REAPPLY']='1' if fail else '0'
        a='--lua-desync=fake:a=1'; b='--lua-desync=multisplit:pos=1'
        (self.work/'scan.json').write_text(json.dumps({'strategies':[{'args':a},{'args':b}]}))
        circular=self.work/'circular.lua'; circular.write_text("print('--lua-desync=circular:strategy=1 --x:strategy=2')")
        production=block('        local apply_info=""','        local dns_err=')
        production=production.replace('/tmp/',str(self.work)+'/').replace('/etc/config/',str(self.work)+'/config/')
        definitions=function('bcw_apply_accepted')+r'''
cmd_apply() { "$fixture" "$@"; }
_strategy_pkg() { echo zapret2wizard; }
write_status() { :; }
cmd_stability() { echo '{"ok":3,"total":3}'; }
cmd_test() { echo '{"time_sec":"0.1","all_ok":true}'; }
domain_ip() { echo 1.2.3.4; }
mem() { printf '%s\n' "$*" >> "$memory"; }
wait_dpi_ready() { :; }
'''
        code='\n'.join([f'fixture={shlex.quote(str(self.fixture))}',f'memory={self.work}/memory',
          f'OUTPUT_SCAN={self.work}/scan.json OUTPUT_VANILLA={self.work}/vanilla OUTPUT_CIRCULAR={self.work}/circular LOG_FILE={self.work}/log',
          f'CIRCULAR_BUILDER={circular}', 'auto_apply=1 found_count=2 target=preset_discord domain=discord.com do_circular=force',
          production, 'printf "FINAL:%s:%s:%s\n" "$apply_ok" "$best_single" "$circular_used"'])
        r=self.shell(code,definitions); self.ok(r)
        return r,(self.work/'memory').read_text(),a,b

    def test_A_rejected_B_accepted_circular_rejected_restores_records_B(self):
        r,m,a,b=self.autoapply()
        self.assertEqual(self.current()['attempts'],[a,b,'--lua-desync=circular:strategy=1 --x:strategy=2 ',b])
        self.assertEqual(self.current()['active'],b)
        self.assertIn('put discord.com 1.2.3.4 '+b+' 1 ',m)
        self.assertNotIn('put discord.com 1.2.3.4 '+a,m)
        self.assertIn('FINAL:1:'+b+':0',r.stdout)

    def test_failed_B_restore_never_positive_memory_or_auto_applied(self):
        r,m,a,b=self.autoapply(True)
        self.assertNotIn('put ',m); self.assertIn('FINAL:0:'+b+':0',r.stdout)

    def evolution(self, fail=False):
        self.env['FAIL_REAPPLY']='1' if fail else '0'
        definitions=function('bcw_apply_accepted')+r'''
cmd_apply() { "$fixture" "$@"; }
cmd_test() { echo test >> "$testlog"; echo '{"size_bytes":42,"all_ok":true}'; }
_svc_start_bg() { :; }
sleep() { :; }
'''
        code='\n'.join([f'fixture={self.fixture} testlog={self.work}/tests report_run={self.work} verified={self.work}/verified',
         "target=preset_discord tests=3 pause=0 shortlist='A|--lua-desync=fake:a=1\nB|--lua-desync=multisplit:pos=1'",
         block('    local verified_lines="" applied=0 stable_count=0','    local stats\n'),
         'printf "FINAL:%s:%s\n" "$applied" "$best_args"'])
        r=self.shell(code,definitions)
        return r

    def test_evolution_never_tests_or_credits_rolled_back_A(self):
        r=self.evolution(); self.ok(r)
        self.assertEqual((self.work/'tests').read_text().splitlines(),['test']*3)
        verified=(self.work/'verified').read_text(); self.assertIn('A|0|0|0|0',verified); self.assertIn('B|1|42|3|3',verified)
        self.assertIn('FINAL:1:--lua-desync=multisplit:pos=1',r.stdout)

    def test_evolution_reapply_failure_stops_before_memory_update(self):
        r=self.evolution(True); self.assertNotEqual(r.returncode,0); self.assertNotIn('FINAL:1:',r.stdout)
        self.assertIn('память не обновлена',r.stdout)

    def test_report_scope_missing_duplicate_malformed_and_interrupted(self):
        definitions=function('bcw_report_copy')
        phase=self.work/'phase'; phase.mkdir(); dest=self.work/'dest'
        unrelated=self.work/'old_scan.json'; unrelated.write_text('{"strategies":["stale"]}')
        command=f'bcw_report_copy {phase} scan.json {dest}'
        self.assertNotEqual(self.shell(command,definitions).returncode,0); self.assertFalse(dest.exists())
        current=phase/'interrupted_scan.json'; current.write_text('{bad}')
        self.assertNotEqual(self.shell(command,definitions).returncode,0)
        current.write_text('{"strategies":[],"outcome":"censored"}')
        self.ok(self.shell(command,definitions)); self.assertEqual(dest.read_text(),current.read_text())
        (phase/'another_scan.json').write_text('{"strategies":[]}')
        self.assertNotEqual(self.shell(command,definitions).returncode,0)
        self.assertEqual(unrelated.read_text(),'{"strategies":["stale"]}')
        self.assertNotIn('/root/*_',SOURCE)

    def test_private_report_run_has_0700_and_does_not_prune_unrelated(self):
        # Redirect only the literal temp prefix; production creation logic is unchanged.
        definitions=block('bcw_report_run_create() (','bcw_report_copy() {').replace('/tmp/bcw-report.',str(self.work)+'/bcw-report.')
        r=self.shell('bcw_report_run_create',definitions); self.ok(r)
        run=Path(r.stdout.strip()); self.assertEqual(run.stat().st_mode & 0o777,0o700)
        self.assertEqual(sorted(p.name for p in run.iterdir()),['adaptive','evolve','probe'])

    def test_scanner_merge_preserves_canonical_outcomes(self):
        start=SOURCE.index('local scan_file = arg[1]\nlocal p_file = arg[2]')
        lua='local json = require("luci.jsonc")\n'+SOURCE[start:SOURCE.index('\nEOF',start)]
        for outcome in ['censored','not_blocked','broken','nothing_works','found']:
            scan=self.work/'merge.json'; scan.write_text(json.dumps({'strategies':[],'outcome':outcome,'reason':'retained','limit':'bounded'}))
            proc=subprocess.run(['lua','-',str(scan),'','',''],input=lua,env=self.env,text=True,capture_output=True,timeout=10)
            self.assertEqual(proc.returncode,0,proc.stderr)
            data=json.loads(scan.read_text()); self.assertEqual(data['outcome'],outcome); self.assertEqual(data['reason'],'retained')
            self.assertEqual(data['candidate_availability'],'not_found')

    def test_autosetup_eligibility_empty_generated_custom_disabled_and_query_failure(self):
        defaults=function('default_instagram_script')+function('autosetup_needed')
        stub=r'''
uci() {
 [ "$1" != -q ] || shift
 if [ "$1" = show ]; then [ "$MODE" != unreadable ] || return 1; [ "$MODE" = empty ] || echo "zapret2wizard.$SECTION=strategy"; return 0; fi
 case "$2" in
 *.script) if [ "$MODE" = custom ]; then echo custom; else default_instagram_script; fi ;;
 *.enabled) [ "$MODE" = disabled ] && echo 0 || echo 1 ;;
 *.port) echo 443 ;; *.protocol) echo tcp ;; *.hostlist) echo list_hosts_instagram ;; esac
}
'''
        for mode,section,rc in [('empty','',0),('generated','BlockcheckW_Instagram',0),('custom','BlockcheckW_Instagram',1),('disabled','BlockcheckW_Instagram',1),('generated','MyStrategy',1),('unreadable','',2)]:
            r=self.shell(f'MODE={mode} SECTION={section}; autosetup_needed',defaults+stub)
            self.assertEqual(r.returncode,rc,(mode,r.stdout,r.stderr))

    def test_autosetup_manual_skips_disabled_existing_target_and_reports_failure(self):
        definitions=function('cmd_autosetup')+r'''
uci() { [ "$1" != -q ] || shift; [ "$1" = show ] && echo 'zapret2wizard.BlockcheckW_YouTube=strategy'; }
ensure_all_hostlists() { :; }; _svc_start_bg() { :; }; sleep() { :; }
cmd_start() { printf '%s\n' "$*" >> "$calls"; echo '{"status":"done","auto_applied":true}' > "$STATUS_FILE"; }
'''
        r=self.shell(f'calls={self.work}/calls STATUS_FILE={self.work}/status; cmd_autosetup',definitions.replace('/tmp/bcw_autosetup.log',str(self.work)+'/setup.log'))
        self.ok(r); self.assertEqual(json.loads(r.stdout)['started'],1)
        self.assertIn('preset_discord',(self.work/'calls').read_text()); self.assertNotIn('preset_youtube',(self.work/'calls').read_text())

    def test_dns_optout_blocks_every_public_writer_and_preserves_custom(self):
        root=self.work/'root'; (root/'var/run').mkdir(parents=True)
        functions=['dns_doh_ensure','dns_pin_host','dns_fix_discord','dns_fix_instagram','dns_alt_ensure','cmd_gv_clear','cmd_gv_fix','cmd_optimize_dns']
        definitions=LIFECYCLE.read_text()+'\n'+''.join(function(n) for n in functions)+r'''
lifecycle_load() { :; }
uci() { [ "$1" != -q ] || shift; [ "$1" = get ] && [ "$2" = zapret2wizard.main.auto_dns ] && { echo 0; return; }; echo mutation >> "$mutations"; return 1; }
'''
        code=f'BCW_LIFECYCLE_ROOT={root} mutations={self.work}/mutations; '
        code+='; '.join(n+' example.com 1.2.3.4 || :' for n in functions)
        r=self.shell(code,definitions); self.ok(r)
        self.assertFalse((self.work/'mutations').exists()); self.assertFalse((root/'var/run/bcw_policy.lock').exists())
        self.assertNotIn('uci ',function('dns_doh_cloudflare_port'))

    def test_generated_profile_exclusions_and_package_first_install_flags(self):
        main=block('        # Create new strategy section','    sync_uci_commit')
        self.assertIn('uci add_list "$pkg.$sec_name.hostlist_exclude=list_hosts_user_exclude"',main)
        self.assertIn('"$pkg.$voice_sec_name.hostlist_exclude" list_hosts_user_exclude',main)
        for name in ['cmd_ensure_instagram','cmd_fix_ytapi','cmd_quic_mode_locked']:
            self.assertIn('hostlist_exclude',function(name)); self.assertIn('list_hosts_user_exclude',function(name))
        for path in ['packaging/build.py','packaging/build-apk.sh','packaging/build-ipk.sh']:
            self.assertIn('autosetup --if-needed',(ROOT/path).read_text())

if __name__=='__main__': unittest.main(verbosity=2)
