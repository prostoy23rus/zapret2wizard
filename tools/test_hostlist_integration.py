#!/usr/bin/env python3
"""Production functions; disposable paths and mocked service/UCI, no host effects."""
import json, os, shlex, subprocess, tempfile, unittest
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / 'openwrt/luci-app-blockcheckw/root/usr/bin/blockcheckw-helper'
MODULE = ROOT / 'openwrt/luci-app-blockcheckw/root/usr/share/zapret2wizard/hostlist_io.sh'
SHELLS = [['/bin/sh'], ['busybox', 'ash']]
class Integration(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='bcw-hl-integration-')
        self.root = Path(self.tmp.name)
        self.dest = self.root / 'user.txt'
        self.original = b'# exact original\nold.example\nunterminated.example'
        self.dest.write_bytes(self.original)
        text = HELPER.read_text()
        self.lib = self.root / 'functions.sh'
        self.lib.write_text(text[text.index('_hl_sanitize() {'):text.index('# Тестовый режим: source helper')])
        self.env = dict(os.environ, DEST=str(self.dest), ROOT=str(self.root), EN='0', RUNNING='inactive')
        (self.root / 'luci').mkdir()
        (self.root / 'luci/jsonc.lua').write_text(r'''local M={}
local function enc(x)
 if type(x)=='string' then return '"'..x:gsub('\\','\\\\'):gsub('"','\\"'):gsub('\n','\\n'):gsub('\r','\\r'):gsub('\t','\\t')..'"' end
 if type(x)~='table' then return tostring(x) end
 local a={} if #x>0 then for _,v in ipairs(x) do a[#a+1]=enc(v) end return '['..table.concat(a,',')..']' end
 for k,v in pairs(x) do a[#a+1]=enc(k)..':'..enc(v) end return '{'..table.concat(a,',')..'}'
end
M.stringify=enc return M
''')
        self.env['LUA_PATH'] = str(self.root / '?.lua') + ';;'
    def tearDown(self): self.tmp.cleanup()
    def run_sh(self, body, shell=None, stdin=''):
        prelude = '. "$1"; . "$2"; shift 2\n' + r'''
_hostlist_path() { case "$1" in user|builtin|general) echo "$DEST" ;; exclude) echo "$ROOT/exclude.txt" ;; youtube|discord|x|instagram|ytapi|twitch) echo "$ROOT/$1.txt" ;; esac; }
get_dpi_service_status() { echo "$RUNNING"; }
scan_busy() { [ "${SCAN_BUSY:-0}" = 1 ]; }
uci() {
 case "$*" in
  '-q show zapret2wizard') echo 'zapret2wizard.BlockcheckW_General=strategy' ;;
  '-q get zapret2wizard.BlockcheckW_General.hostlist') echo list_hosts_user ;;
  '-q get zapret2wizard.BlockcheckW_General.hostlist_exclude') echo list_hosts_user_exclude ;;
  '-q get zapret2wizard.list_hosts_user.path') echo "$DEST" ;;
  '-q get zapret2wizard.list_hosts_user_exclude.path') echo "$ROOT/exclude.txt" ;;
  '-q get zapret2wizard.BlockcheckW_General.enabled') echo "$EN" ;;
  *) return 1 ;;
 esac
}
timeout() { echo restart >> "$ROOT/restarts"; return "${INIT_RC:-0}"; }
wait_dpi_ready() { return "${READY_RC:-0}"; }
'''
        return subprocess.run((shell or ['/bin/sh']) + ['-c', prelude+body, 'fixture', str(self.lib), str(MODULE)], input=stdin, text=True, capture_output=True, env=self.env, timeout=10)
    def out(self, body, **kw):
        r=self.run_sh(body, **kw)
        try: return r, json.loads(r.stdout)
        except Exception: self.fail(repr(r))
    def test_empty_comments_nonempty_and_unterminated(self):
        for shell in SHELLS:
            for data,count in [('',0),('# comment\n \n',0),('A.example.\na.example\ninvalid!\nlast.example',2)]:
                with self.subTest(shell=shell,data=data):
                    r,o=self.out('cmd_write_hostlist user --no-restart',shell=shell,stdin=data)
                    self.assertEqual(r.returncode,0,r.stderr);self.assertTrue(o['saved']);self.assertEqual(o['count'],count)
                    self.assertEqual(o['restart'],'not_requested')
    def test_read_empty_and_absent_domains_are_json_arrays(self):
        for exists in [True,False]:
            if exists: self.dest.write_bytes(b"")
            elif self.dest.exists(): self.dest.unlink()
            r,o=self.out("cmd_read_hostlist user")
            self.assertEqual(r.returncode,0,r.stderr);self.assertEqual(o["domains"],[]);self.assertEqual(o["count"],0);self.assertEqual(o["exists"],exists)
    def test_add_remove_and_noops(self):
        for shell in SHELLS:
            self.dest.write_bytes(self.original)
            for command,field,count in [('cmd_add_hostlist_domain user New.example --no-restart','added',3),('cmd_add_hostlist_domain user New.example --no-restart','already_exists',3),('cmd_remove_hostlist_domain user new.example --no-restart','removed',2),('cmd_remove_hostlist_domain user new.example --no-restart','already_absent',2)]:
                r,o=self.out(command,shell=shell);self.assertEqual(r.returncode,0,r.stderr);self.assertTrue(o[field]);self.assertEqual(o['count'],count)
    def test_all_mutations_preserve_exact_bytes_on_rename_failure(self):
        for command in ['cmd_write_hostlist user new.example --no-restart','cmd_add_hostlist_domain user new.example --no-restart','cmd_remove_hostlist_domain user old.example --no-restart']:
            for shell in SHELLS:
                self.dest.write_bytes(self.original)
                r,o=self.out('mv() { return 1; }; '+command,shell=shell)
                self.assertNotEqual(r.returncode,0);self.assertFalse(o['saved']);self.assertEqual(self.dest.read_bytes(),self.original)
                self.assertFalse(Path(str(self.dest)+'.bcw-lock').exists())
        self.assertFalse((self.root/'restarts').exists())
    def test_staging_read_count_failures_preserve(self):
        for prefix in ['cat() { return 1; }; ', 'hostlist_io_count() { return 1; }; ', 'grep() { if [ \"$1\" = -qxF ]; then return 2; fi; command grep \"$@\"; }; ']:
            r,o=self.out(prefix+'cmd_write_hostlist user new.example --no-restart')
            self.assertNotEqual(r.returncode,0);self.assertFalse(o['saved']);self.assertEqual(self.dest.read_bytes(),self.original)
    def test_restart_failure_separate_from_saved(self):
        for init,ready,started in [('1','0',False),('0','1',True),('0','0',True)]:
            self.env.update(INIT_RC=init,READY_RC=ready)
            r,o=self.out('cmd_write_hostlist user new.example')
            self.assertTrue(o['saved']);self.assertEqual(o['restart_started'],started)
            self.assertEqual(o['restart_verified'],init==ready=='0');self.assertEqual(o['success'],init==ready=='0')
            self.assertEqual(self.dest.read_bytes(),b'new.example\n')
    def test_scan_busy_defers_restart_without_losing_save(self):
        self.env["SCAN_BUSY"]="1"
        r,o=self.out("cmd_write_hostlist user new.example")
        self.assertTrue(o["saved"]);self.assertFalse(o["success"]);self.assertEqual(o["restart"],"deferred_scanner_busy")
        self.assertFalse(o["restart_started"]);self.assertFalse((self.root/"restarts").exists())
        self.assertEqual(self.dest.read_bytes(),b"new.example\n")
    def test_revision_without_cksum_and_hash_failures_fail_closed(self):
        # Build a router-like command PATH that genuinely has no cksum applet.
        commands=self.root/'commands';commands.mkdir()
        import shutil
        for name in ['sha256sum','awk','cat','mkdir','rmdir','rm','mktemp','cp','mv','tr','sed','grep','lua']:
            executable=shutil.which(name)
            self.assertIsNotNone(executable,name)
            (commands/name).symlink_to(executable)
        self.env['PATH']=str(commands)
        for shell in [['/bin/sh'],['/usr/bin/busybox','ash']]:
            r,o=self.out('command -v cksum >/dev/null 2>&1 && exit 99; cmd_read_hostlist user',shell=shell)
            self.assertEqual(r.returncode,0,r.stderr);self.assertRegex(o['revision'],r'^[0-9a-f]{64}$')
            r,o=self.out('cmd_write_hostlist user new.example --no-restart',shell=shell)
            self.assertEqual(r.returncode,0,r.stderr);self.assertTrue(o['saved']);self.assertRegex(o['revision'],r'^[0-9a-f]{64}$')
            for prefix in ['sha256sum() { return 1; }; ', 'sha256sum() { echo malformed; }; ']:
                self.dest.write_bytes(self.original)
                r,o=self.out(prefix+'cmd_write_hostlist user changed.example',shell=shell)
                self.assertNotEqual(r.returncode,0);self.assertFalse(o['saved']);self.assertEqual(self.dest.read_bytes(),self.original)
                self.assertFalse((self.root/'restarts').exists())
            # A staging hash failure also cannot commit after successful old-file hashing.
            self.dest.write_bytes(self.original)
            prefix='sha256sum() { data=$(cat); case "$data" in *changed.example*) return 1 ;; *) printf "%s" "$data" | command sha256sum ;; esac; }; '
            r,o=self.out(prefix+'cmd_write_hostlist user changed.example',shell=shell)
            self.assertNotEqual(r.returncode,0);self.assertFalse(o['saved']);self.assertEqual(self.dest.read_bytes(),self.original)
    def test_read_and_stale_editor_guard(self):
        r,o=self.out('cmd_read_hostlist user');self.assertEqual(r.returncode,0,r.stderr);self.assertEqual(o['count'],2)
        revision=o['revision'];self.dest.write_bytes(b'concurrent.example\n')
        r,o=self.out('cmd_write_hostlist user --revision '+shlex.quote(revision)+' new.example --no-restart')
        self.assertEqual(o['error'],'stale_revision_reload');self.assertEqual(self.dest.read_bytes(),b'concurrent.example\n')
    def test_busy_symlink_gzip_missing_parent(self):
        lock=Path(str(self.dest)+'.bcw-lock');lock.mkdir()
        r,o=self.out('cmd_add_hostlist_domain user new.example --no-restart');self.assertEqual(o['error'],'hostlist_busy_retry');lock.rmdir()
        gz=Path(str(self.dest)+'.gz');gz.write_bytes(b'compressed')
        r,o=self.out('cmd_write_hostlist user --empty --no-restart');self.assertEqual(o['error'],'compressed_list_requires_manual_update');gz.unlink()
        self.dest.unlink();self.dest.symlink_to(self.root/'victim')
        r,o=self.out('cmd_write_hostlist user --empty --no-restart');self.assertEqual(o['error'],'invalid_path');self.dest.unlink()
        self.env['DEST']=str(self.root/'missing'/'user.txt')
        r,o=self.out('cmd_write_hostlist user --empty --no-restart');self.assertEqual(o['error'],'invalid_path');self.assertFalse((self.root/'missing').exists())
    def test_status_disabled_attached_running_and_excludes(self):
        (self.root/'exclude.txt').write_text('no.example\n')
        for en,running in [('0','running'),('1','inactive'),('1','running')]:
            self.env.update(EN=en,RUNNING=running)
            r,rows=self.out('_hl_info_json');self.assertEqual(r.returncode,0,r.stderr)
            for key in ['user','exclude']:
                o=next(x for x in rows if x['key']==key)
                self.assertTrue(o['exists']);self.assertTrue(o['attached']);self.assertEqual(o['enabled'],en=='1');self.assertEqual(o['service_running'],running=='running');self.assertFalse(o['runtime_verified'])
    def test_clear_ensure_slow_fast_and_direct_preserves_all_lists(self):
        source=HELPER.read_text()
        def take(start,end): return source[source.index(start):source.index(end,source.index(start))]
        ensure=take('ensure_all_hostlists() {','\nwrite_status() {')
        ready=take('_hostlists_ready() {','\n# Удалённые пресеты')
        preset=take('ensure_preset_hostlist() {','\n# Ревизия набора списков')
        add=take('_add_domains_if_missing() {','\n# One-time migration')
        fixture=add+preset+ready+ensure
        # Only literal absolute path rebasing; executed function bodies stay actual.
        fixture=fixture.replace('/etc/zapret2wizard',str(self.root/'etc')).replace('/usr/share/zapret2wizard',str(self.root/'share')).replace('/opt/zapret2',str(self.root/'opt'))
        self.lib.write_text(self.functions_for_seed()+fixture)
        ipset=self.root/'etc/ipset';ipset.mkdir(parents=True)
        share=self.root/'share/ipset';share.mkdir(parents=True)
        keys=['youtube','discord','x','instagram','twitch','ytapi','user','user_exclude']
        for key in keys:
            (ipset/('zapret_hosts_'+key+'.txt')).write_text('old.example\n')
            (share/('zapret_hosts_'+key+'.txt')).write_text('shipped.example\n')
        self.env['DEST']=str(ipset/'zapret_hosts_user.txt')
        body=r'''
purge_removed_presets() { :; }
ensure_firewall_quic_reject() { :; }
_uci_set_list_if_missing() { :; }
_uci_add_list_unique() { :; }
uci() { case "$*" in '-q get zapret2wizard.list_hosts_user_exclude') return 0 ;; esac; return 0; }
_hostlist_path() { case "$1" in exclude) echo "$ROOT/etc/ipset/zapret_hosts_user_exclude.txt" ;; *) echo "$ROOT/etc/ipset/zapret_hosts_$1.txt" ;; esac; }
HOSTLISTS_MARKER="$ROOT/etc/revision"
HOSTLISTS_REV=fixture
for target in youtube discord x instagram twitch ytapi user exclude; do
 cmd_write_hostlist "$target" --empty --no-restart || exit 1
done
ensure_all_hostlists || exit 2
_hostlists_ready || exit 3
ensure_all_hostlists || exit 4
for target in preset_youtube preset_discord preset_x preset_instagram preset_twitch preset_youtubei builtin general; do
 ensure_preset_hostlist "$target" || exit 5
done
cmd_read_hostlist user
cmd_read_hostlist exclude
'''
        for shell in SHELLS:
            r=self.run_sh(body,shell=shell)
            self.assertEqual(r.returncode,0,r.stderr)
            rows=[json.loads(line) for line in r.stdout.splitlines()]
            self.assertEqual([row['count'] for row in rows[-2:]],[0,0])
            self.assertEqual([row['domains'] for row in rows[-2:]],[[],[]])
            for key in keys: self.assertEqual((ipset/('zapret_hosts_'+key+'.txt')).read_bytes(),b'')
        # Slow-path neighboring case preserves nonempty custom bytes as well.
        for key in keys: (ipset/('zapret_hosts_'+key+'.txt')).write_bytes(b'# custom\nonly.mine\n')
        r=self.run_sh('HOSTLISTS_MARKER="$ROOT/etc/revision"; HOSTLISTS_REV=changed; purge_removed_presets() { :; }; ensure_firewall_quic_reject() { :; }; _uci_set_list_if_missing() { :; }; _uci_add_list_unique() { :; }; ensure_all_hostlists')
        self.assertEqual(r.returncode,0,r.stderr)
        for key in keys: self.assertEqual((ipset/('zapret_hosts_'+key+'.txt')).read_bytes(),b'# custom\nonly.mine\n')
    def functions_for_seed(self):
        source=HELPER.read_text()
        return source[source.index('_hl_sanitize() {'):source.index('# Тестовый режим: source helper')]
    def test_missing_lists_still_initialize_from_shipped_defaults(self):
        source=HELPER.read_text()
        start=source.index('ensure_preset_hostlist() {')
        preset=source[start:source.index('\n# Ревизия набора списков',start)]
        add=source[source.index('_add_domains_if_missing() {'):source.index('\n# One-time migration')]
        fixture=(add+preset).replace('/etc/zapret2wizard',str(self.root/'etc')).replace('/opt/zapret2',str(self.root/'opt'))
        self.lib.write_text(fixture)
        ipset=self.root/'etc/ipset';ipset.mkdir(parents=True)
        for shell in SHELLS:
            r=self.run_sh('_uci_set_list_if_missing() { :; }; ensure_preset_hostlist builtin; ensure_preset_hostlist preset_youtube',shell=shell)
            self.assertEqual(r.returncode,0,r.stderr)
            self.assertIn('rutracker.org',(ipset/'zapret_hosts_user.txt').read_text())
            self.assertIn('youtube.com',(ipset/'zapret_hosts_youtube.txt').read_text())
    def test_generator_empty_keeps_filter_missing_skips_profile(self):
        source=(ROOT/'openwrt/luci-app-blockcheckw/root/usr/share/zapret2wizard/uci2config').read_text()
        function=source[source.index('_process_strategy() {'):source.index('# Process luascripts and blobs')]
        empty=self.root/'empty.txt';empty.write_text('')
        stub=r'''
sanitize_value() { printf '%s' "$1"; }
validate_ports() { return 0; }
config_get_bool() { eval "$1=1"; }
config_get() {
 local val="$4"
 case "$2.$3" in fixture.hostlist) val=list_fixture ;; list_fixture.path) val="$LIST" ;; fixture.script) val='--comment=fixture' ;; esac
 eval "$1=\"\$val\""
}
config_list_foreach() { return 0; }
STRATEGY_NUM=0
NFQWS2_OPT=''
_process_strategy fixture
printf '%s\n' "$NFQWS2_OPT"
'''
        for exists in [True,False]:
            env=dict(self.env,LIST=str(empty if exists else self.root/'missing-list.txt'))
            r=subprocess.run(['/bin/sh','-c',function+stub],env=env,capture_output=True,text=True,timeout=5)
            self.assertEqual(r.returncode,0,r.stderr)
            if exists: self.assertIn('--hostlist='+str(empty),r.stdout);self.assertNotIn('--skip',r.stdout)
            else: self.assertIn('--skip',r.stdout)
    def test_engine_empty_hostlist_dry_run(self):
        empty=self.root/'empty.txt';empty.write_text('');self.root.chmod(0o755);empty.chmod(0o644)
        engine=ROOT/'openwrt/engine/nfqws2-linux-x86_64'
        r=subprocess.run([str(engine),'--dry-run','--qnum=64000','--debug=1','--filter-tcp=443','--hostlist='+str(empty)],capture_output=True,text=True,timeout=5)
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertNotIn('failed to register',r.stderr)
        print('ENGINE EMPTY DRY RUN:',(r.stdout+r.stderr).strip())
if __name__=='__main__': unittest.main(verbosity=2)
