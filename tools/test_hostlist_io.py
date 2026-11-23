#!/usr/bin/env python3
"""Disposable-root production-shell regressions. Run on Linux with python3.
Fault injection overrides commands with functions in one child shell only;
no fake executables are installed, no router/service/network operations run.
HOSTLIST_IO_SHELL='busybox ash' optionally selects one shell instead of matrix.
"""
import json
import os
from pathlib import Path
import pwd
import shlex
import shutil
import stat
import subprocess
import tempfile
import threading
import unittest

MODULE = Path(__file__).resolve().parents[1] / "openwrt/luci-app-blockcheckw/root/usr/share/zapret2wizard/hostlist_io.sh"
SHELLS = [shlex.split(os.environ["HOSTLIST_IO_SHELL"])] if os.environ.get("HOSTLIST_IO_SHELL") else [["/bin/sh"], ["dash"], ["busybox", "ash"]]
SHELLS = [shell for shell in SHELLS if shutil.which(shell[0])]
if not SHELLS:
    raise RuntimeError("No requested Linux shell is available")


class HostlistIO(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="hostlist-io-")
        self.root = Path(self.tmp.name)
        self.root.chmod(0o755)
        self.module = self.root / "hostlist_io.sh"
        self.module.write_bytes(MODULE.read_bytes())
        self.module.chmod(0o644)
        self.source = self.root / "sanitized input.txt"
        self.source.write_bytes(b"new.example\nsecond.example\n")
        self.source.chmod(0o644)
        self.dest = self.root / "user list.txt"
        self.original = b"# exact original\nold.example\n\x00unterminated"
        self.reset()
        self.reference = self.root / "expected-original"
        self.reference.write_bytes(self.original)
        self.log = self.root / "operations"

    def reset(self):
        self.dest.write_bytes(self.original)
        self.dest.chmod(0o640)

    def tearDown(self):
        self.tmp.cleanup()

    def run_shell(self, shell, body, *args, unprivileged=False):
        env = {"PATH": "/usr/bin:/bin", "LC_ALL": "C", "HOME": str(self.root),
               "FAULT_LOG": str(self.log), "EXPECTED_ORIGINAL": str(self.reference),
               "EXPECTED_SOURCE": str(self.source)}
        preexec = None
        if unprivileged and os.geteuid() == 0:
            nobody = pwd.getpwnam("nobody")
            def demote():
                os.setgroups([])
                os.setgid(nobody.pw_gid)
                os.setuid(nobody.pw_uid)
            preexec = demote
        return subprocess.run(shell + ["-c", '. "$1"; shift\n' + body,
                                      "test-hostlist-io", str(self.module), *map(str, args)],
                              cwd=self.root, env=env, capture_output=True,
                              timeout=15, preexec_fn=preexec)

    def save(self, shell, prefix="", source=None, dest=None, **kwargs):
        return self.run_shell(shell, prefix + '\nhostlist_io_save "$1" "$2"',
                              source or self.source, dest or self.dest, **kwargs)

    def assert_preserved(self, result):
        self.assertNotEqual(result.returncode, 0, result)
        self.assertEqual(result.stdout, b"")
        self.assertEqual(self.dest.read_bytes(), self.original)
        self.assertEqual(stat.S_IMODE(self.dest.stat().st_mode), 0o640)
        self.assertEqual(list(self.root.glob(".hostlist_io.*")), [])

    def test_sourcing_no_io_and_retains_caller_umask_trap(self):
        for shell in SHELLS:
            with self.subTest(shell=shell):
                result = self.run_shell(shell, 'before=$(umask); trap "echo caller-trap" 0; . "$1"; [ "$(umask)" = "$before" ]', self.module)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, b"caller-trap\n")
                self.assertEqual(self.dest.read_bytes(), self.original)

    def test_count_exact_integer_and_json_compatible(self):
        cases = [(None, 0), (b"", 0), (b" \t\r\n\n", 0),
                 (b"#comment\n \t#comment\n\r\n", 0),
                 (b"one.example\n#comment\n\n two.example \nlast.example", 3),
                 (b"not-sanitized # inline content\n", 1)]
        for shell in SHELLS:
            for index, (content, expected) in enumerate(cases):
                with self.subTest(shell=shell, content=content):
                    target = self.root / ("count-%s" % index)
                    if content is not None:
                        target.write_bytes(content)
                    result = self.run_shell(shell, 'hostlist_io_count "$1"', target)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout, (str(expected) + "\n").encode())
                    self.assertEqual(json.loads(b'{"count":' + result.stdout + b'}'), {"count": expected})

    def test_save_exact_bytes_preserves_mode_and_source(self):
        self.source.write_bytes(b"# caller data\nUPPER.Example\n\n\x00tail")
        for shell in SHELLS:
            with self.subTest(shell=shell):
                self.reset()
                self.dest.chmod(0o604)
                result = self.save(shell)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, b"")
                self.assertEqual(self.dest.read_bytes(), self.source.read_bytes())
                self.assertEqual(stat.S_IMODE(self.dest.stat().st_mode), 0o604)
                self.assertEqual(list(self.root.glob(".hostlist_io.*")), [])

    def test_new_empty_file_private_independent_of_umask(self):
        self.source.write_bytes(b"")
        for index, shell in enumerate(SHELLS):
            with self.subTest(shell=shell):
                target = self.root / ("new-%s" % index)
                result = self.save(shell, "umask 000", dest=target)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(target.read_bytes(), b"")
                self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o600)

    def test_stat_and_chmod_are_not_runtime_dependencies(self):
        prefix = 'stat() { return 127; }; chmod() { return 127; }'
        for shell in SHELLS:
            with self.subTest(shell=shell):
                self.reset()
                result = self.save(shell, prefix)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(stat.S_IMODE(self.dest.stat().st_mode), 0o640)
                self.assertEqual(self.dest.read_bytes(), self.source.read_bytes())

    def test_relative_option_like_paths(self):
        (self.root / "-source").write_bytes(b"value")
        for shell in SHELLS:
            with self.subTest(shell=shell):
                result = self.save(shell, source="-source", dest="-dest")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual((self.root / "-dest").read_bytes(), b"value")

    def test_faults_map_to_actual_production_operations(self):
        faults = {
            "cp": 'cp() { printf "cp:%s:%s\\n" "$2" "$3" >> "$FAULT_LOG"; return 1; }',
            "mktemp": 'mktemp() { printf "mktemp\\n" >> "$FAULT_LOG"; return 1; }',
            "cat": 'cat() { printf "cat:%s\\n" "$1" >> "$FAULT_LOG"; command dd if="$1" bs=4 count=1 2>/dev/null; return 1; }',
            "mv": 'mv() { printf "mv:%s:%s\\n" "$2" "$3" >> "$FAULT_LOG"; return 1; }',
        }
        for shell in SHELLS:
            for operation, prefix in faults.items():
                with self.subTest(shell=shell, operation=operation):
                    self.log.write_bytes(b"")
                    result = self.save(shell, prefix)
                    self.assert_preserved(result)
                    self.assertTrue(self.log.read_text().startswith(operation), result.stderr)
                    if operation in ("cp", "mv"):
                        self.assertIn(str(self.root / ".hostlist_io."), self.log.read_text())

    @unittest.skipUnless(shutil.which("busybox"), "BusyBox unavailable")
    def test_busybox_applets_not_just_ash_syntax(self):
        # Functions route these real operations to actual BusyBox applets, not
        # GNU tools. They are scoped to this subprocess and its disposable root.
        prefix = "\n".join(name + '() { busybox ' + name + ' "$@"; }'
                           for name in ("cp", "mktemp", "cat", "mv", "rm", "awk"))
        result = self.save(["busybox", "ash"], prefix)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.dest.read_bytes(), self.source.read_bytes())
        result = self.run_shell(["busybox", "ash"], prefix + '\nhostlist_io_count "$1"', self.dest)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, b"2\n")

    def test_real_partial_write_limit_preserves_original(self):
        self.source.write_bytes(b"large.example\n" * 10000)
        for shell in SHELLS:
            with self.subTest(shell=shell):
                # Ignore SIGXFSZ so cat returns EFBIG after a genuinely partial
                # staging write. Neither prior target nor caller source changes.
                result = self.save(shell, "trap '' XFSZ; ulimit -f 1")
                self.assert_preserved(result)
                self.assertIn(b"hostlist_io_write_failed", result.stderr)

    def test_count_read_error_does_not_leak_partial_count(self):
        for shell in SHELLS:
            result = self.run_shell(shell, 'awk() { printf "7\\n"; return 1; }; hostlist_io_count "$1"', self.source)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, b"")

    def test_commit_same_directory_complete_staging_intact_original(self):
        prefix = r'''mv() {
            [ "$1" = -fT ] || return 81
            [ "$(dirname "$2")" = "$(dirname "$3")" ] || return 82
            command cmp "$3" "$EXPECTED_ORIGINAL" || return 83
            command cmp "$2" "$EXPECTED_SOURCE" || return 84
            [ "$(command stat -c %a "$2")" = 640 ] || return 85
            printf 'commit\n' >> "$FAULT_LOG"
            command mv "$@"
        }'''
        for shell in SHELLS:
            with self.subTest(shell=shell):
                self.reset()
                result = self.save(shell, prefix)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.dest.read_bytes(), self.source.read_bytes())
        self.assertEqual(self.log.read_text(), "commit\n" * len(SHELLS))

    def test_unprivileged_success_retains_custom_mode(self):
        # cp -p must work for an ordinary owner too, not only privileged root.
        if os.geteuid() == 0:
            nobody = pwd.getpwnam("nobody")
            for path in (self.root, self.dest):
                os.chown(path, nobody.pw_uid, nobody.pw_gid)
        for shell in SHELLS:
            with self.subTest(shell=shell):
                self.reset()
                self.dest.chmod(0o604)
                result = self.save(shell, unprivileged=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(stat.S_IMODE(self.dest.stat().st_mode), 0o604)
                self.assertEqual(self.dest.read_bytes(), self.source.read_bytes())

    def test_missing_parent_not_created(self):
        for shell in SHELLS:
            result = self.save(shell, dest=self.root / "missing" / "hosts")
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((self.root / "missing").exists())
            self.assertEqual(self.dest.read_bytes(), self.original)

    def test_real_permission_failure_readonly_parent(self):
        directory = self.root / "readonly"
        directory.mkdir(mode=0o755)
        target = directory / "hosts"
        target.write_bytes(self.original)
        target.chmod(0o644)
        directory.chmod(0o555)
        try:
            for shell in SHELLS:
                result = self.save(shell, dest=target, unprivileged=True)
                self.assertNotEqual(result.returncode, 0, result)
                self.assertIn(b"hostlist_io_temp_failed", result.stderr)
                self.assertEqual(target.read_bytes(), self.original)
                self.assertEqual(list(directory.glob(".hostlist_io.*")), [])
        finally:
            directory.chmod(0o755)

    def test_unreadable_source_and_count_fail_without_stdout(self):
        self.source.chmod(0o000)
        for shell in SHELLS:
            self.assert_preserved(self.save(shell, unprivileged=True))
            result = self.run_shell(shell, 'hostlist_io_count "$1"', self.source, unprivileged=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, b"")

    def test_symlink_and_dangling_leaves_never_overwrite_targets(self):
        for shell in SHELLS:
            for dangling in (False, True):
                with self.subTest(shell=shell, dangling=dangling):
                    link = self.root / "destination-link"
                    if link.is_symlink():
                        link.unlink()
                    link.symlink_to(self.root / "does-not-exist" if dangling else self.dest)
                    self.assertNotEqual(self.save(shell, dest=link).returncode, 0)
                    self.assertTrue(link.is_symlink())
                    self.assertEqual(self.dest.read_bytes(), self.original)
                    self.assertFalse((self.root / "does-not-exist").exists())
                    self.assert_preserved(self.save(shell, source=link))
                    result = self.run_shell(shell, 'hostlist_io_count "$1"', link)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(result.stdout, b"")

    def test_directory_fifo_missing_source_rejected(self):
        directory = self.root / "directory"
        directory.mkdir()
        fifo = self.root / "fifo"
        os.mkfifo(fifo)
        for shell in SHELLS:
            for target in (directory, fifo):
                self.assertNotEqual(self.save(shell, dest=target).returncode, 0)
                self.assert_preserved(self.save(shell, source=target))
                result = self.run_shell(shell, 'hostlist_io_count "$1"', target)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, b"")
            self.assert_preserved(self.save(shell, source=self.root / "absent-source"))
        self.assertEqual(list(directory.iterdir()), [])

    def test_concurrent_replacements_never_expose_partial_content(self):
        a, b = b"a.example\n" * 20000, b"b.example\n" * 20000
        self.source.write_bytes(a)
        other = self.root / "other-source"
        other.write_bytes(b)
        for shell in SHELLS:
            with self.subTest(shell=shell):
                self.reset()
                seen = []
                stop = threading.Event()
                def observe():
                    while not stop.is_set():
                        value = self.dest.read_bytes()
                        if value not in (self.original, a, b):
                            seen.append(value)
                            break
                thread = threading.Thread(target=observe)
                thread.start()
                try:
                    workers = [subprocess.Popen(shell + ["-c", '. "$1"; hostlist_io_save "$2" "$3"', "test-hostlist-io", str(self.module), str(source), str(self.dest)], stdout=subprocess.PIPE, stderr=subprocess.PIPE) for source in (self.source, other)]
                    for worker in workers:
                        out, err = worker.communicate(timeout=15)
                        self.assertEqual(worker.returncode, 0, err)
                        self.assertEqual(out, b"")
                finally:
                    stop.set()
                    thread.join(timeout=5)
                self.assertFalse(seen, "reader observed partial content")
                self.assertIn(self.dest.read_bytes(), (a, b))
                self.assertEqual(list(self.root.glob(".hostlist_io.*")), [])


if __name__ == "__main__":
    print("Shell matrix:", ", ".join(" ".join(shell) for shell in SHELLS), flush=True)
    unittest.main(verbosity=2)
