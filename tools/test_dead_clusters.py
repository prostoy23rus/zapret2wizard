#!/usr/bin/env python3
"""Offline tests for the dead-cluster pure Lua logic (no network/nft)."""
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MODULE = ROOT / "openwrt/luci-app-blockcheckw/root/usr/share/zapret2wizard/dead_clusters.lua"
LUA = os.environ.get("LUA") or next((shutil.which(n) for n in ("lua5.4", "lua5.3", "lua") if shutil.which(n)), "lua")


def run(*args):
    return subprocess.run([LUA, str(MODULE), *args], capture_output=True, text=True, timeout=15)


class DeadClusters(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="bcw-dead-")
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)

    def write(self, name, lines):
        p = self.dir / name
        p.write_text("\n".join(lines) + ("\n" if lines else ""), encoding="utf-8")
        return p

    def build(self, dead, alive, max_elems=None):
        args = [str(self.write("dead.txt", dead)), str(self.write("alive.txt", alive))]
        if max_elems is not None:
            args.append(str(max_elems))
        p = run("build", *args)
        self.assertEqual(p.returncode, 0, p.stderr)
        values, elements = {}, []
        for line in p.stdout.splitlines():
            if line.startswith("element="):
                elements.append(line.split("=", 1)[1])
            elif "=" in line:
                k, v = line.split("=", 1)
                values[k] = int(v)
        return values, elements

    def test_parse_hosts_dedup_and_lowercase(self):
        html = ("<a>https://rr5---sn-gvnuxaxjvh-3ggz.googlevideo.com/x</a>"
                "<a>https://RR2---SN-ABC-1.googlevideo.com/</a>"
                "<span>rr5---sn-gvnuxaxjvh-3ggz.googlevideo.com</span>")
        p = run("hosts", str(self.write("page.html", [html])))
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stdout.splitlines(), [
            "rr5---sn-gvnuxaxjvh-3ggz.googlevideo.com",
            "rr2---sn-abc-1.googlevideo.com",
        ])

    def test_parse_hosts_ignores_other_domains(self):
        html = "https://www.youtube.com/ https://i.ytimg.com/x https://notgooglevideo.com/"
        p = run("hosts", str(self.write("page.html", [html])))
        self.assertEqual(p.stdout.strip(), "")

    def test_isolated_dead_ips_become_32(self):
        values, elements = self.build(["1.2.3.4", "5.6.7.8"], ["9.9.9.9"])
        self.assertEqual(sorted(elements), ["1.2.3.4", "5.6.7.8"])
        self.assertEqual((values["alive"], values["dead"], values["subnets"]), (1, 2, 0))

    def test_two_dead_and_zero_alive_make_24(self):
        values, elements = self.build(["1.2.3.4", "1.2.3.5"], ["9.9.9.9"])
        self.assertEqual(elements, ["1.2.3.0/24"])
        self.assertEqual((values["dead"], values["subnets"], values["singles"]), (2, 1, 0))

    def test_mixed_24_never_blocks_whole_subnet(self):
        values, elements = self.build(["1.2.3.4", "1.2.3.5"], ["1.2.3.6"])
        self.assertEqual(sorted(elements), ["1.2.3.4", "1.2.3.5"])
        self.assertEqual((values["subnets"], values["singles"]), (0, 2))

    def test_single_dead_in_mixed_24_stays_32(self):
        values, elements = self.build(["1.2.3.4"], ["1.2.3.5"])
        self.assertEqual(elements, ["1.2.3.4"])

    def test_duplicate_and_invalid_lines_ignored(self):
        values, elements = self.build(["1.2.3.4", "1.2.3.4", "bad", "1.2.3.999"], ["9.9.9.9"])
        self.assertEqual(elements, ["1.2.3.4"])
        self.assertEqual(values["dead"], 1)

    def test_cap_marks_capped_and_limits_elements(self):
        dead = ["10.0.%d.%d" % (i, j) for i in range(4) for j in (1, 2)]
        values, elements = self.build(dead, ["9.9.9.9"], max_elems=3)
        self.assertEqual(len(elements), 3)
        self.assertEqual(values["capped"], 1)

    def test_multiple_subnets_sorted(self):
        values, elements = self.build(["5.0.0.1", "5.0.0.2", "1.0.0.1", "1.0.0.2"], ["9.9.9.9"])
        self.assertEqual(elements, ["1.0.0.0/24", "5.0.0.0/24"])


if __name__ == "__main__":
    unittest.main()
