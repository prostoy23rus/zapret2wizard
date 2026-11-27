#!/usr/bin/env python3
"""Actual Lua module + curl against disposable loopback/stub executables only.
Run: python3 tools/test_transfer_probe.py. LUA=/path/to/lua5.1 selects runtime.
No helper, router, UCI, external network, or system modifications.
"""
import contextlib
import gzip
import http.server
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
MODULE = ROOT / "openwrt/luci-app-blockcheckw/root/usr/share/zapret2wizard/transfer_probe.lua"
LUA = os.environ.get("LUA", "lua")


def literal(value):
    if value is None:
        return "nil"
    if isinstance(value, dict):
        return "{" + ",".join("[" + literal(k) + "]=" + literal(v) for k, v in value.items()) + "}"
    if isinstance(value, (int, float)):
        return str(value)
    return json.dumps(value)


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def handle(self):
        # Expected client aborts for explicit body/header budgets.
        with contextlib.suppress(BrokenPipeError, ConnectionResetError):
            super().handle()

    def do_HEAD(self):
        self.send_response(200)
        self.send_header("Content-Length", "1234")
        self.end_headers()

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/redirect":
            self.send_response(302)
            self.send_header("Location", "/short")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if path == "/timeout":
            self.send_response(200)
            self.send_header("Content-Length", "100")
            self.end_headers()
            time.sleep(1.3)
            return
        if path in ("/chunked", "/badchunk"):
            self.send_response(200)
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            self.wfile.write(b"4\r\ndata\r\n" + (b"0\r\n\r\n" if path == "/chunked" else b""))
            self.wfile.flush()
            self.close_connection = True
            return
        if path == "/cut":
            # issue #7: announced 2 MiB, but the "DPI" cuts the flow at 1 MiB.
            self.send_response(200)
            self.send_header("Content-Length", "2097152")
            self.end_headers()
            chunk = b"x" * 65536
            for _ in range(16):
                self.wfile.write(chunk)
            self.wfile.flush()
            self.close_connection = True
            return
        if path == "/close":
            self.send_response(200)
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(b"data")
            self.close_connection = True
            return
        if path == "/largeheaders":
            self.send_response(200)
            for i in range(100):
                self.send_header("X-Fill-" + str(i), "x" * 1000)
            self.send_header("Content-Length", "4")
            with contextlib.suppress(BrokenPipeError, ConnectionResetError):
                self.end_headers()
                self.wfile.write(b"data")
            return
        code = 206 if path == "/range" else 404 if path == "/error" else 204 if path == "/empty" else 200
        body = b"" if code == 204 else b"data"
        if path == "/gzip":
            body = gzip.compress(b"data" * 100)
        self.send_response(code)
        self.send_header("Content-Length", str(100 if path == "/partial" else len(body)))
        if code == 206:
            self.send_header("Content-Range", "bytes 0-3/4")
        if path == "/gzip":
            self.send_header("Content-Encoding", "gzip")
        self.end_headers()
        self.wfile.write(body)
        self.wfile.flush()
        if path == "/partial":
            self.close_connection = True


class TransferProbe(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.base = "http://127.0.0.1:" + str(cls.server.server_port)

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()

    def probe(self, path="/short", env=None, **options):
        opts = {"url": self.base + path, "endpoint_id": "primary", "attempt_id": "fixture", "timeout_sec": 2, "max_bytes": 1048576}
        opts.update(options)
        script = "local M=dofile(" + literal(str(MODULE)) + ");local r=M.probe(" + literal(opts) + ");"
        keys = ("curl_exit", "http_code", "bytes_received", "completeness", "termination", "reason", "transfer_verified", "http_reachable", "cleanup_ok", "playback", "completeness_basis", "capture_error")
        script += "for _,k in ipairs(" + "{" + ",".join(map(literal, keys)) + "}) do print(k..'='..tostring(r[k])) end"
        before = set(Path("/tmp").glob("z2w-transfer.*"))
        result = subprocess.run([LUA, "-"], input=script, text=True, capture_output=True, cwd=ROOT, timeout=8, env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        after = set(Path("/tmp").glob("z2w-transfer.*"))
        self.assertEqual(after - before, set(), "probe left scratch directories")
        return dict(line.split("=", 1) for line in result.stdout.splitlines())

    def test_pure_and_fault_suite(self):
        result = subprocess.run([LUA, "tools/test_transfer_probe.lua"], cwd=ROOT, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("assertions passed", result.stdout)
        print(result.stdout.strip())

    def test_complete(self):
        r = self.probe()
        self.assertEqual((r["curl_exit"], r["bytes_received"], r["transfer_verified"]), ("0", "4", "true"))
        self.assertEqual((r["cleanup_ok"], r["playback"]), ("true", "unknown"))

    def test_redirect_final_headers(self):
        r = self.probe("/redirect")
        self.assertEqual((r["http_code"], r["bytes_received"], r["completeness"]), ("200", "4", "complete"))

    def test_cut_at_one_mib_is_not_verified(self):
        # TSPU byte cap: 2 MiB announced, only 1 MiB delivered, then RST/close.
        r = self.probe("/cut", max_bytes=8388608, timeout_sec=5)
        self.assertEqual((r["curl_exit"], r["bytes_received"], r["termination"]), ("18", "1048576", "partial"))
        self.assertEqual(r["transfer_verified"], "false")
        self.assertNotEqual(r["completeness"], "complete")

    def test_partial_exit_preserved(self):
        r = self.probe("/partial")
        self.assertEqual((r["curl_exit"], r["bytes_received"], r["termination"]), ("18", "4", "partial"))
        self.assertEqual(r["transfer_verified"], "false")

    def test_short_tail(self):
        r = self.probe("/range", range={"start": 0, "finish": 1048575})
        self.assertEqual((r["completeness"], r["transfer_verified"]), ("complete", "true"))

    def test_range_ignored_complete(self):
        self.assertEqual(self.probe(range={"start": 0, "finish": 1048575})["completeness"], "complete")

    def test_http_error(self):
        r = self.probe("/error")
        self.assertEqual((r["http_code"], r["http_reachable"], r["transfer_verified"]), ("404", "true", "false"))

    def test_no_body(self):
        for opts in ({"path": "/empty"}, {"method": "HEAD"}):
            with self.subTest(opts=opts):
                r = self.probe(**opts)
                self.assertEqual((r["bytes_received"], r["completeness"], r["transfer_verified"]), ("0", "not_applicable", "false"))

    def test_chunked_and_broken_chunk(self):
        r = self.probe("/chunked")
        self.assertEqual((r["completeness"], r["completeness_basis"]), ("complete", "protocol-end"))
        r = self.probe("/badchunk")
        self.assertNotEqual(r["curl_exit"], "0")
        self.assertEqual(r["transfer_verified"], "false")

    def test_close_delimited(self):
        r = self.probe("/close")
        self.assertEqual((r["completeness"], r["completeness_basis"]), ("complete", "close-eof"))

    def test_encoding_domain(self):
        r = self.probe("/gzip")
        self.assertEqual(r["transfer_verified"], "true")
        self.assertNotEqual(r["bytes_received"], "400", "must not compare decoded bytes to encoded Content-Length")

    def test_timeout(self):
        r = self.probe("/timeout", timeout_sec=1)
        self.assertEqual((r["curl_exit"], r["termination"], r["transfer_verified"]), ("28", "timeout", "false"))

    def test_header_bound(self):
        r = self.probe("/largeheaders")
        self.assertEqual(r["transfer_verified"], "false")
        self.assertEqual(r["completeness"], "unknown")

    def test_declared_byte_limit(self):
        r = self.probe(max_bytes=3)
        self.assertEqual((r["curl_exit"], r["termination"], r["transfer_verified"]), ("63", "caller_limit", "false"))

    def test_real_subprocess_rc_and_quoted_url(self):
        with tempfile.TemporaryDirectory(prefix="transfer-curl-stub-") as tmp:
            tmp = Path(tmp)
            stub = tmp / "curl"
            argv = tmp / "argv.json"
            stub.write_text("#!/usr/bin/python3\nimport json,os,pathlib,sys\na=sys.argv[1:]\npathlib.Path(os.environ['ARGV_OUT']).write_text(json.dumps(a))\npathlib.Path(a[a.index('--dump-header')+1]).write_bytes(b'HTTP/1.1 200 OK\\r\\nContent-Length: 100\\r\\n\\r\\n')\nprint('\\nZ2W_METRICS 200 4 0.5 8 0.01')\nsys.exit(18)\n")
            stub.chmod(0o755)
            env = dict(os.environ, PATH=str(tmp) + os.pathsep + os.environ["PATH"], ARGV_OUT=str(argv))
            # Shell metacharacters are literal URL bytes; no command can execute.
            url = self.base + "/it'$(false);x"
            r = self.probe(env=env, url=url)
            args = json.loads(argv.read_text())
            self.assertEqual(args[-1], url)
            self.assertNotIn("--insecure", args)
            self.assertNotIn("-k", args)
            self.assertEqual((r["curl_exit"], r["bytes_received"], r["termination"]), ("18", "4", "partial"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
