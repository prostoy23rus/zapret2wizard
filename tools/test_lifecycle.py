#!/usr/bin/env python3
"""Offline production-shell regressions. Commands are mocks; all data is disposable."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest

REPO = Path(__file__).resolve().parents[1]
PAYLOAD = REPO / "openwrt/luci-app-blockcheckw/root"
MODULE = PAYLOAD / "usr/share/zapret2wizard/lifecycle.sh"
HELPER = PAYLOAD / "usr/bin/blockcheckw-helper"
MOCK = r'''#!/usr/bin/python3
import json, os, pathlib, shutil, sys
root = pathlib.Path(os.environ["BCW_LIFECYCLE_ROOT"])
assert str(root).startswith("/tmp/") and root.is_dir(), root
file = root / "state.json"
s = json.loads(file.read_text())
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
s["log"].append([name] + args)
rc = 0
out = ""
def remove(p):
    if p.is_dir() and not p.is_symlink(): shutil.rmtree(p)
    elif p.exists() or p.is_symlink(): p.unlink()
if name == "nft":
    if s.get("nft_fail"): rc = 1
    elif args == ["list", "tables"]: out = "\n".join("table inet " + x for x in s["tables"])
    elif args[:3] == ["list", "table", "inet"]: rc = int(args[3] not in s["tables"])
    elif args[:3] == ["delete", "table", "inet"]:
        if s.get("nft_delete_fail"): rc = 1
        elif args[3] in s["tables"]: s["tables"].remove(args[3])
        else: rc = 1
    else: rc = 2
elif name == "uci":
    args = [a for a in args if a != "-q"]
    action, key = args[:2]
    if action == "show":
        if s.get("query_fail") or s.get("uci_read_fail"): rc = 1
        else: out = "\n".join(k + "=value" for k in s["uci"] if k.startswith(key + "."))
    elif action == "add_list":
        key, value = key.split("=", 1)
        s["uci"].setdefault(key, []).append(value)
    elif action == "get":
        if key not in s["uci"]: rc = 1
        else:
            out = s["uci"][key]
            if isinstance(out, list): out = " ".join(out)
    elif s.get("uci_fail"): rc = 1
    elif action == "del_list":
        key, value = key.split("=", 1)
        s["uci"][key].remove(value)
    elif action == "delete":
        for item in list(s["uci"]):
            if item == key or item.startswith(key + "."): del s["uci"][item]
    elif action != "commit": rc = 2
elif name in ("zapret2wizard", "firewall", "dnsmasq", "cron"):
    if s.get("init_fail") == args[0]: rc = 1
    elif name == "zapret2wizard":
        if args[0] == "stop":
            if not s.get("keep_supervision"): s["supervision"] = False
            if not s.get("keep_engine"): remove(root / "proc/101")
        elif args[0] == "disable":
            if not s.get("keep_link"): remove(root / "etc/rc.d/S99zapret2wizard")
        elif args[0] in ("start", "restart"):
            s["supervision"] = True
            if not s.get("no_ready"):
                p = root / "proc/101"; p.mkdir(parents=True, exist_ok=True)
                (p / "comm").write_text("nfqws2\n")
                (p / "cmdline").write_bytes(b"/usr/bin/nfqws2\0--qnum=300\0")
                if "zapret2wizard" not in s["tables"]: s["tables"].append("zapret2wizard")
elif name == "blockcheckw-helper": pass
elif name == "ubus":
    if s.get("ubus_fail"): rc = 1
    else: out = json.dumps({"zapret2wizard": {"instances": {"main": {"running": True}} if s["supervision"] else {}}})
elif name == "jsonfilter":
    try:
        d = json.load(sys.stdin)
        if args[-1] == "@": out = json.dumps(d)
        else: out = "\n".join(json.dumps(x) for x in d.get("zapret2wizard", {}).get("instances", {}).values())
    except Exception: rc = 1
elif name in ("apk", "opkg"):
    if args[0] in ("info", "list-installed"):
        if s.get("query_fail"): rc = 1
        elif s["package"] == name: out = ("zapret2wizard" if name == "apk" else "luci-app-blockcheckw - 1")
    elif args in (["del", "zapret2wizard"], ["del", "luci-app-blockcheckw"], ["remove", "luci-app-blockcheckw"]):
        if s.get("package_fail"): rc = 1
        elif not s.get("package_stays"):
            s["package"] = ""
            # Simulate old packages removing unmarked user files and owner itself.
            for p in ("usr/share/zapret2wizard", "etc/zapret2wizard", "etc/config/zapret2wizard"):
                remove(root / p)
    else: rc = 2
else: rc = 2
file.write_text(json.dumps(s))
if out: print(out)
sys.exit(rc)
'''


class Lifecycle(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="bcw-lifecycle-")
        self.root = Path(self.temp.name)
        self.bin = self.root / "mocks"
        for p in ("mocks", "etc/init.d", "etc/config", "etc/zapret2wizard/ipset", "etc/rc.d", "etc/crontabs", "usr/bin", "usr/share/zapret2wizard", "tmp", "var/run", "proc/101", "proc/202", "opt/zapret2/nfq2"):
            (self.root / p).mkdir(parents=True, exist_ok=True)
        mock = self.bin / "mock"; mock.write_text(MOCK); mock.chmod(0o755)
        for cmd in ("nft", "uci", "apk", "opkg", "ubus", "jsonfilter"):
            (self.bin / cmd).symlink_to(mock)
        for cmd in ("zapret2wizard", "firewall", "dnsmasq", "cron"):
            (self.root / "etc/init.d" / cmd).symlink_to(mock)
        (self.root / "usr/bin/blockcheckw-helper").symlink_to(mock)
        shutil.copyfile(MODULE, self.root / "usr/share/zapret2wizard/lifecycle.sh")
        (self.root / "etc/config/zapret2wizard").write_text("user strategy\n")
        (self.root / "etc/zapret2wizard/ipset/user.txt").write_text("custom.example\n")
        (self.root / "etc/rc.d/S99zapret2wizard").symlink_to("../init.d/zapret2wizard")
        quic = (PAYLOAD / "usr/share/zapret2wizard/quic_reject.sh").read_text()
        (self.root / "etc/bcw_quic_reject.sh").write_text(quic.split("<<'EOS'\n", 1)[1].split("\nEOS", 1)[0] + "\n")
        (self.root / "etc/zapret2wizard/dns-owned").write_text("address|/instagram.com/1.2.3.4\nserver|/googlevideo.com/127.0.0.1#5053\n")
        (self.root / "etc/crontabs/root").write_text("* * * * * /vendor/watchdog\n* * * * * /usr/bin/blockcheckw-helper health_tick # bcw-health\n* * * * * /usr/bin/blockcheckw-helper evolve_nightly\n* * * * * /other/task # watchdog\n")
        for pid, q in ((101, 300), (202, 400)):
            (self.root / f"proc/{pid}/comm").write_text("nfqws2\n")
            (self.root / f"proc/{pid}/cmdline").write_bytes(f"/usr/bin/nfqws2\0--qnum={q}\0".encode())
        self.state = dict(log=[], package="", supervision=True, tables=["zapret2wizard", "bcw_quic", "foreign"], uci={
            "dhcp.@dnsmasq[0]": "dnsmasq",
            "dhcp.@dnsmasq[0].server": ["/googlevideo.com/127.0.0.1#5053", "/googlevideo.com/9.9.9.9", "/foreign.example/127.0.0.1#5053", "/x.com/127.0.0.1#50530"],
            "dhcp.@dnsmasq[0].address": ["/googlevideo.com/1.2.3.4", "/instagram.com/1.2.3.4", "/foreign.example/5.6.7.8"],
            "firewall.bcw_quic": "include", "firewall.bcw_quic.path": "/etc/bcw_quic_reject.sh",
            "firewall.reject_quic": "rule", "firewall.reject_quic.name": "Reject-QUIC", "firewall.reject_quic.proto": "udp", "firewall.reject_quic.dest_port": "443", "firewall.reject_quic.target": "REJECT",
            "firewall.foreign": "rule"})
        self.save()
        self.env = dict(os.environ, BCW_LIFECYCLE_ROOT=str(self.root), PATH=str(self.bin) + ":" + os.environ["PATH"])

    def tearDown(self):
        self.temp.cleanup()

    def save(self):
        (self.root / "state.json").write_text(json.dumps(self.state))

    def state_now(self):
        return json.loads((self.root / "state.json").read_text())

    def run_shell(self, action, helper=False, shell=None):
        source = HELPER if helper else MODULE
        script = ("BCW_LIB_ONLY=1; " if helper else "") + '. "$1"; PATH="$2"; ' + action
        return subprocess.run((shell or ["sh"]) + ["-c", script, "test", str(source), self.env["PATH"]], env=self.env, text=True, capture_output=True, timeout=35)

    def assert_ok(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_stop_uses_init_preserves_boot_and_foreign_engine(self):
        self.assert_ok(self.run_shell("cmd_service stop", helper=True))
        state = self.state_now()
        self.assertFalse(state["supervision"])
        self.assertIn(["zapret2wizard", "stop"], state["log"])
        self.assertNotIn(["zapret2wizard", "disable"], state["log"])
        self.assertTrue((self.root / "etc/rc.d/S99zapret2wizard").exists())
        self.assertTrue((self.root / "proc/202").exists())
        self.assertEqual(state["tables"], ["foreign"])
        self.assertEqual(state["uci"]["dhcp.@dnsmasq[0].address"], ["/googlevideo.com/1.2.3.4", "/foreign.example/5.6.7.8"])
        self.assertTrue((self.root / "var/run/bcw_service.stopped").exists())

    def test_stop_refuses_lingering_supervision(self):
        self.state["keep_supervision"] = True; self.save()
        r = self.run_shell("cmd_service stop", helper=True)
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse(json.loads(r.stdout)["ok"])

    def test_stop_failure_is_not_success(self):
        self.state["init_fail"] = "stop"; self.save()
        r = self.run_shell("cmd_service stop", helper=True)
        self.assertNotEqual(r.returncode, 0); self.assertFalse(json.loads(r.stdout)["ok"])

    def test_stop_unknown_procd_is_failure(self):
        self.state["ubus_fail"] = True; self.save()
        self.assertNotEqual(self.run_shell("bcw_lifecycle_service stop").returncode, 0)

    def test_start_is_ready_and_not_throttled(self):
        (self.root / "var/run/bcw_service.stopped").touch()
        r = self.run_shell("cmd_service start", helper=True)
        self.assert_ok(r); self.assertEqual(json.loads(r.stdout)["service"], "running")
        self.assertFalse((self.root / "var/run/bcw_service.stopped").exists())

    def test_start_without_readiness_fails(self):
        self.state["no_ready"] = True; self.state["tables"] = []; self.save()
        shutil.rmtree(self.root / "proc/101")
        r = self.run_shell("cmd_service start", helper=True)
        self.assertNotEqual(r.returncode, 0); self.assertFalse(json.loads(r.stdout)["ok"])

    def test_internal_stop_preserves_quic_canary_and_dns(self):
        for key in ("BCW_INTERNAL_STOP", "BCW_ENGINE_ONLY"):
            r = self.run_shell(f"{key}=1 bcw_lifecycle_stop_effects")
            self.assert_ok(r)
            state = self.state_now()
            self.assertIn("bcw_quic", state["tables"])
            self.assertIn("firewall.bcw_quic", state["uci"])
            self.assertFalse(any(x[:2] == ["blockcheckw-helper", "canary_stop"] for x in state["log"]))
            self.assertFalse((self.root / "var/run/bcw_service.stopped").exists())

    def test_cleanup_precise_and_idempotent(self):
        self.assert_ok(self.run_shell("bcw_lifecycle_cleanup; bcw_lifecycle_cleanup"))
        state = self.state_now()
        self.assertEqual(state["tables"], ["foreign"])
        self.assertEqual(state["uci"]["dhcp.@dnsmasq[0].address"], ["/googlevideo.com/1.2.3.4", "/foreign.example/5.6.7.8"])
        self.assertEqual(len(state["uci"]["dhcp.@dnsmasq[0].server"]), 3)
        self.assertIn("firewall.foreign", state["uci"])
        self.assertEqual((self.root / "etc/crontabs/root").read_text(), "* * * * * /vendor/watchdog\n* * * * * /other/task # watchdog\n")
        self.assertFalse((self.root / "etc/bcw_quic_reject.sh").exists())

    def test_cleanup_failure_propagates(self):
        for flag in ("uci_fail", "nft_fail", "nft_delete_fail"):
            self.state[flag] = True; self.save()
            self.assertNotEqual(self.run_shell("cleanup_leftovers", helper=True).returncode, 0)
            del self.state[flag]

    def test_foreign_same_named_firewall_preserved(self):
        self.state["uci"]["firewall.bcw_quic.path"] = "/foreign/include.sh"
        self.state["uci"]["firewall.reject_quic.name"] = "Foreign QUIC"; self.save()
        self.assertNotEqual(self.run_shell("bcw_lifecycle_cleanup").returncode, 0)
        self.assertEqual(self.state_now()["uci"]["firewall.bcw_quic.path"], "/foreign/include.sh")

    def test_remove_bundle_preserves_user_data_and_foreign_binary(self):
        (self.root / "opt/zapret2/nfq2/nfqws2").write_text("foreign")
        self.assert_ok(self.run_shell("bcw_lifecycle_remove"))
        self.assertFalse((self.root / "etc/init.d/zapret2wizard").exists())
        self.assertFalse((self.root / "usr/share/zapret2wizard").exists())
        self.assertEqual((self.root / "etc/config/zapret2wizard").read_text(), "user strategy\n")
        self.assertTrue((self.root / "etc/zapret2wizard/ipset/user.txt").exists())
        self.assertEqual((self.root / "opt/zapret2/nfq2/nfqws2").read_text(), "foreign")
        self.assertTrue((self.root / "proc/202").exists())

    def test_remove_package_apk(self):
        self.check_package("apk")

    def test_remove_package_opkg(self):
        self.check_package("opkg")

    def check_package(self, manager):
        self.state["package"] = manager; self.save()
        self.assert_ok(self.run_shell("bcw_lifecycle_remove"))
        state = self.state_now()
        self.assertEqual(state["package"], "")
        self.assertIn([manager, "del" if manager == "apk" else "remove", "zapret2wizard" if manager == "apk" else "luci-app-blockcheckw"], state["log"])
        self.assertEqual((self.root / "etc/config/zapret2wizard").read_text(), "user strategy\n")
        self.assertTrue((self.root / "etc/zapret2wizard/ipset/user.txt").exists())

    def test_remove_package_failure_preserves_owner(self):
        self.state.update(package="apk", package_fail=True); self.save()
        self.assertNotEqual(self.run_shell("bcw_lifecycle_remove").returncode, 0)
        self.assertTrue((self.root / "usr/share/zapret2wizard").exists())

    def test_remove_package_still_registered_fails(self):
        self.state.update(package="opkg", package_stays=True); self.save()
        self.assertNotEqual(self.run_shell("bcw_lifecycle_remove").returncode, 0)
        self.assertTrue((self.root / "usr/share/zapret2wizard").exists())

    def test_failed_query_never_treated_as_bundle(self):
        self.state["query_fail"] = True; self.save()
        self.assertNotEqual(self.run_shell("bcw_lifecycle_remove").returncode, 0)
        self.assertTrue((self.root / "etc/init.d/zapret2wizard").exists())

    def test_remove_refuses_active_scanner_and_autostart_leftover(self):
        (self.root / "proc/202/comm").write_text("blockcheckw\n")
        self.assertNotEqual(self.run_shell("bcw_lifecycle_remove").returncode, 0)
        (self.root / "proc/202/comm").write_text("nfqws2\n")
        self.state["keep_link"] = True; self.save()
        self.assertNotEqual(self.run_shell("bcw_lifecycle_remove").returncode, 0)
        self.assertTrue((self.root / "usr/share/zapret2wizard").exists())

    def test_async_ack_not_success_terminal_survives_self_removal(self):
        self.state["package"] = "apk"; self.save()
        result = self.run_shell("bcw_lifecycle_remove_begin")
        self.assert_ok(result)
        ack = json.loads(result.stdout)
        self.assertTrue(ack["started"]); self.assertFalse(ack["success"])
        for _ in range(200):
            status = json.loads((self.root / "tmp/blockcheckw_uninstall.json").read_text())
            if status["status"] != "running": break
            time.sleep(.05)
        self.assertEqual(status["operation"], ack["operation"])
        self.assertEqual(status["status"], "done", status)
        self.assertTrue(status["success"])
        self.assertFalse((self.root / "usr/share/zapret2wizard").exists())

    def test_async_failure_terminal_never_success(self):
        self.state["init_fail"] = "stop"; self.save()
        self.assert_ok(self.run_shell("bcw_lifecycle_remove_begin"))
        for _ in range(200):
            status = json.loads((self.root / "tmp/blockcheckw_uninstall.json").read_text())
            if status["status"] != "running": break
            time.sleep(.05)
        self.assertEqual(status["status"], "error"); self.assertFalse(status["success"])

    def test_busybox_owner_cleanup(self):
        if not shutil.which("busybox"): self.skipTest("busybox unavailable")
        self.assert_ok(self.run_shell("bcw_lifecycle_cleanup", shell=["busybox", "ash"]))

    def test_unknown_user_pins_and_preexisting_identical_not_adopted(self):
        journal = self.root / "etc/zapret2wizard/dns-owned"
        journal.unlink()
        before = self.state_now()["uci"]["dhcp.@dnsmasq[0].address"]
        self.assert_ok(self.run_shell('bcw_lifecycle_policy_run dns bcw_lifecycle_dns_add address /googlevideo.com/1.2.3.4'))
        self.assertFalse(journal.exists())
        self.assert_ok(self.run_shell("bcw_lifecycle_cleanup"))
        self.assertEqual(self.state_now()["uci"]["dhcp.@dnsmasq[0].address"], before)

    def test_added_pin_journaled_and_only_added_value_removed(self):
        self.assert_ok(self.run_shell('bcw_lifecycle_policy_run dns bcw_lifecycle_dns_add address /new.example/192.0.2.1'))
        self.assertIn("/new.example/192.0.2.1", self.state_now()["uci"]["dhcp.@dnsmasq[0].address"])
        self.assert_ok(self.run_shell("bcw_lifecycle_cleanup"))
        self.assertNotIn("/new.example/192.0.2.1", self.state_now()["uci"]["dhcp.@dnsmasq[0].address"])
        self.assertIn("/googlevideo.com/1.2.3.4", self.state_now()["uci"]["dhcp.@dnsmasq[0].address"])

    def test_uci_inspection_failure_never_cleanup_success(self):
        self.state["uci_read_fail"] = True; self.save()
        self.assertNotEqual(self.run_shell("bcw_lifecycle_cleanup").returncode, 0)
        self.assertNotEqual(self.run_shell('uci() { return 1; }; bcw_lifecycle_cleanup').returncode, 0)

    def test_foreign_include_without_uci_is_preserved(self):
        del self.state["uci"]["firewall.bcw_quic"]
        del self.state["uci"]["firewall.bcw_quic.path"]
        self.save()
        include = self.root / "etc/bcw_quic_reject.sh"
        include.write_text("foreign-user-maintained")
        self.assertNotEqual(self.run_shell("bcw_lifecycle_quic_remove").returncode, 0)
        self.assertEqual(include.read_text(), "foreign-user-maintained")

    def test_legacy_generated_include_can_be_removed(self):
        del self.state["uci"]["firewall.bcw_quic"]
        del self.state["uci"]["firewall.bcw_quic.path"]
        self.save()
        include = self.root / "etc/bcw_quic_reject.sh"
        quic = (PAYLOAD / "usr/share/zapret2wizard/quic_reject.sh").read_text()
        include.write_text(quic.split("<<'EOS'\n", 1)[1].split("\nEOS", 1)[0] + "\n")
        self.assert_ok(self.run_shell("bcw_lifecycle_quic_remove"))
        self.assertFalse(include.exists())

    def test_auto_foreign_conflict_action_refused(self):
        r = self.run_shell('cmd_conflicts_resolve --auto --action disable', helper=True)
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse(json.loads(r.stdout)["success"])

    def test_policy_after_terminal_stop_refused(self):
        self.assert_ok(self.run_shell("bcw_lifecycle_service stop"))
        for action in ("dns_pin_host new.example 192.0.2.1", "cmd_quic_mode reject", "cmd_canary_start"):
            self.assertNotEqual(self.run_shell(action, helper=True).returncode, 0)
        self.assertEqual(self.state_now()["tables"], ["foreign"])

    def test_policy_inflight_finishes_before_stop_cleanup(self):
        script = '. "$1"; late() { touch "$BCW_LIFECYCLE_ROOT/admitted"; while [ ! -e "$BCW_LIFECYCLE_ROOT/release" ]; do sleep .02; done; bcw_lifecycle_dns_add address /late.example/192.0.2.1; }; bcw_lifecycle_policy_run dns late'
        worker = subprocess.Popen(["sh", "-c", script, "test", str(MODULE)], env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        for _ in range(100):
            if (self.root / "admitted").exists(): break
            time.sleep(.02)
        self.assertTrue((self.root / "admitted").exists())
        stopped = subprocess.Popen(["sh", "-c", '. "$1"; bcw_lifecycle_service stop', "test", str(MODULE)], env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        time.sleep(.1)
        self.assertIsNone(stopped.poll(), "Stop acknowledged before admitted writer completed")
        (self.root / "release").touch()
        out, err = worker.communicate(timeout=10); self.assertEqual(worker.returncode, 0, out + err)
        out, err = stopped.communicate(timeout=10); self.assertEqual(stopped.returncode, 0, out + err)
        self.assertNotIn("/late.example/192.0.2.1", self.state_now()["uci"]["dhcp.@dnsmasq[0].address"])

    def test_removal_preparation_fences_concurrent_start(self):
        self.assert_ok(self.run_shell("bcw_lifecycle_prepare_remove"))
        self.assertNotEqual(self.run_shell("bcw_lifecycle_service start").returncode, 0)
        self.assertTrue((self.root / "var/run/bcw_service.removing").exists())

    def test_normal_init_start_preserves_foreign_and_configured_strategy(self):
        source = (PAYLOAD / "etc/init.d/zapret2wizard").read_text()
        import re
        source = re.sub(r"/(etc|usr|opt|tmp|var|proc|lib|sbin)/", lambda m: str(self.root) + m[0], source)
        source = source.replace('${BCW_LIFECYCLE_ROOT:-}' + str(self.root), '${BCW_LIFECYCLE_ROOT:-}')
        init = self.root / "init-source"
        init.write_text(source)
        quic = self.root / "usr/share/zapret2wizard/quic_reject.sh"
        quic.write_text("#!/bin/sh\nexit 0\n")
        self.state["uci"].update({"zapret2wizard.main.enabled":"1", "zapret2wizard.main.canary":"0", "zapret2wizard.main.quic_mode":"allow", "foreign.main.enabled":"1"})
        self.save()
        (self.root / "usr/bin/nfqws2").write_text("engine fixture never executed")
        (self.root / "usr/bin/nfqws2").chmod(0o755)
        (self.root / "etc/zapret2wizard/config").write_text("NFQWS2_OPT='--lua-desync=original:marker=keep'\nQNUM=300\n")
        script = r'''extra_command() { :; }; . "$1"
logger() { :; }; modprobe() { :; }; guard_conflicts() { :; }
prepare_environment() { :; }; apply_nft_firewall() { return 0; }
PROCD_INSTANCES=""
procd_open_instance() { PROCD_INSTANCES="$PROCD_INSTANCES $1"; }; procd_set_param() { :; }; procd_close_instance() { :; }
procd_append_param() { printf '%s\n' "$*" >> "$BCW_LIFECYCLE_ROOT/commands"; }
start_service || exit 1
[ "$PROCD_INSTANCES" = " main" ] || exit 42
[ ! -d "$BCW_LIFECYCLE_ROOT/var/run/bcw_policy.lock" ] || exit 43'''
        before = self.state_now()["uci"].copy()
        result = subprocess.run(["sh", "-c", script, "test", str(init)], env=self.env, text=True, capture_output=True, timeout=15)
        self.assert_ok(result)
        self.assertEqual(self.state_now()["uci"], before)
        self.assertIn("original:marker=keep", (self.root / "commands").read_text())
        self.assertTrue((self.root / "proc/202").exists())
        self.assertIn("foreign", self.state_now()["tables"])
        self.assertFalse(any(x[0] == "blockcheckw-helper" for x in self.state_now()["log"]))
        # Auto must survive Stop deleting runtime-only legacy QUIC state.
        state = self.state_now()
        state["uci"]["zapret2wizard.main.quic_mode"] = "auto"
        state["uci"]["zapret2wizard.BlockcheckW_YouTube"] = "strategy"
        state["uci"]["zapret2wizard.BlockcheckW_YouTube.enabled"] = "1"
        for key in list(state["uci"]):
            if key.startswith("firewall.reject_quic"): del state["uci"][key]
        self.state = state; self.save()
        quic.write_text('#!/bin/sh\nprintf "%s" "$1" > "$BCW_LIFECYCLE_ROOT/quic-action"\n')
        result = subprocess.run(["sh", "-c", script, "test", str(init)], env=self.env, text=True, capture_output=True, timeout=15)
        self.assert_ok(result)
        self.assertEqual((self.root / "quic-action").read_text(), "apply")
        self.assert_ok(self.run_shell("bcw_lifecycle_service stop"))
        result = subprocess.run(["sh", "-c", script, "test", str(init)], env=self.env, text=True, capture_output=True, timeout=15)
        self.assert_ok(result)
        self.assertEqual((self.root / "quic-action").read_text(), "apply")
        for mode, expected in (("allow", "remove"), ("reject", "apply")):
            state = self.state_now(); state["uci"]["zapret2wizard.main.quic_mode"] = mode
            self.state = state; self.save()
            result = subprocess.run(["sh", "-c", script, "test", str(init)], env=self.env, text=True, capture_output=True, timeout=15)
            self.assert_ok(result)
            self.assertEqual((self.root / "quic-action").read_text(), expected)
        state = self.state_now(); state["uci"]["zapret2wizard.main.quic_mode"] = "auto"
        self.state = state; self.save()
        state = self.state_now(); state["uci"]["zapret2wizard.BlockcheckW_YouTube.enabled"] = "0"
        self.state = state; self.save()
        result = subprocess.run(["sh", "-c", script, "test", str(init)], env=self.env, text=True, capture_output=True, timeout=15)
        self.assert_ok(result)
        self.assertEqual((self.root / "quic-action").read_text(), "remove")
        # Configured policy must be applied before any instance is registered.
        quic.write_text("#!/bin/sh\nexit 7\n")
        failed = subprocess.run(["sh", "-c", script, "test", str(init)], env=self.env, text=True, capture_output=True, timeout=15)
        self.assertNotEqual(failed.returncode, 0)
        self.assertFalse((self.root / "var/run/bcw_policy.lock").exists())
        for shell in (["sh"], ["busybox", "ash"]):
            if not shutil.which(shell[0]): continue
            quic.write_text("#!/bin/sh\nexit 0\n")
            trap_script = script.replace("start_service || exit 1", "trap 'echo caller-trap > \"$BCW_LIFECYCLE_ROOT/caller-trap\"' EXIT; start_service || exit 1")
            result = subprocess.run(shell + ["-c", trap_script, "test", str(init)], env=self.env, text=True, capture_output=True, timeout=15)
            self.assert_ok(result)
            self.assertEqual((self.root / "caller-trap").read_text().strip(), "caller-trap")

    def test_failed_preparation_clears_fence_and_allows_start_retry(self):
        self.state["init_fail"] = "stop"; self.save()
        self.assertNotEqual(self.run_shell("bcw_lifecycle_remove").returncode, 0)
        self.assertFalse((self.root / "var/run/bcw_service.removing").exists())
        state = self.state_now(); state.pop("init_fail"); self.state = state; self.save()
        self.assert_ok(self.run_shell("bcw_lifecycle_service start"))

    def test_ensure_hostlists_while_stopped_never_creates_firewall(self):
        import re
        source = HELPER.read_text()
        self.assertNotIn("ensure_firewall_quic_reject", source)
        source = re.sub(r"/(etc|usr|opt|tmp|var|proc|lib|sbin)/", lambda m: str(self.root) + m[0], source)
        source = source.replace('${BCW_LIFECYCLE_ROOT:-}' + str(self.root), '${BCW_LIFECYCLE_ROOT:-}')
        helper = self.root / "hostlist-helper"; helper.write_text(source)
        state = self.state_now()
        for key in list(state["uci"]):
            if key.startswith("firewall.reject_quic") or key.startswith("firewall.bcw_quic"): del state["uci"][key]
        state["uci"]["zapret2wizard.list_hosts_user_exclude"] = "list"
        state["uci"]["zapret2wizard.main.quic_mode"] = "allow"
        state["tables"] = ["foreign"]; state["supervision"] = False
        self.state = state; self.save()
        (self.root / "var/run/bcw_service.stopped").touch()
        include = self.root / "etc/bcw_quic_reject.sh"; include.unlink()
        for target in ("youtube", "discord", "x", "instagram", "twitch", "user", "user_exclude"):
            (self.root / f"etc/zapret2wizard/ipset/zapret_hosts_{target}.txt").write_text("example.test\n")
        script = r'''BCW_LIB_ONLY=1; . "$1"; PATH="$2"
purge_removed_presets() { :; }
ensure_preset_hostlist() { :; }
cmd_info() { echo '{"success":true}'; }
# Slow and fast provisioning paths both run while Stop intent is present.
HOSTLISTS_MARKER="$BCW_LIFECYCLE_ROOT/etc/zapret2wizard/hostlists-rev"
cmd_ensure_hostlists
_hostlists_ready || exit 7
cmd_ensure_hostlists'''
        for shell in (["sh"], ["busybox", "ash"]):
            result = subprocess.run(shell + ["-c", script, "fixture", str(helper), self.env["PATH"]], env=self.env, text=True, capture_output=True, timeout=15)
            self.assert_ok(result)
        after = self.state_now()
        self.assertEqual(after["uci"], state["uci"])
        self.assertEqual(after["tables"], ["foreign"])
        self.assertFalse(include.exists())
        self.assertTrue((self.root / "var/run/bcw_service.stopped").exists())
        self.assertFalse(any(x[0] in ("nft", "firewall", "zapret2wizard") for x in after["log"]))
        self.assertFalse(any(x[0] == "uci" and any("firewall" in arg for arg in x[1:]) for x in after["log"]))

    def test_invalid_root_refused(self):
        self.env["BCW_LIFECYCLE_ROOT"] = "/"
        self.assertNotEqual(self.run_shell("bcw_lifecycle_remove").returncode, 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
