#!/usr/bin/env python3
"""Publish-ready repository feed from release artifacts.

Output layout (--out):
  opkg/<arch>/Packages + *.ipk
  apk/<arch>/APKINDEX.tar.gz + *.apk
  SHA256SUMS, index.json

apk index is produced by apk-tools 3 ("apk index -o ... --rewrite-arch ARCH").
Unsigned index/packages are still usable with --allow-untrusted; signing is a
separate step (see docs/UPDATES-FEED.md).
"""

import argparse
import gzip
import hashlib
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import time

AR_MAGIC = b"!<arch>\n"
APK_RE = re.compile(r"^(?P<name>[a-z0-9][a-z0-9+.-]*)_(?P<version>[^_]+)_(?P<arch>[^./]+)\.apk$")
IPK_RE = re.compile(r"^(?P<name>[a-z0-9][a-z0-9+.-]*)_(?P<version>[^_]+)_(?P<arch>[^./]+)\.ipk$")


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def read_ar_member(blob, wanted):
    if not blob.startswith(AR_MAGIC):
        raise ValueError("not an ar archive")
    pos = len(AR_MAGIC)
    while pos + 60 <= len(blob):
        header = blob[pos:pos + 60]
        name = header[0:16].decode("utf-8", "replace").strip().rstrip("/")
        size = int(header[48:58].decode("ascii").strip() or "0")
        data_start = pos + 60
        data_end = data_start + size
        if name == wanted:
            return blob[data_start:data_end]
        pos = data_end + (size % 2)
    raise KeyError(wanted)


def parse_control(text):
    fields = {}
    current = None
    for line in text.splitlines():
        if not line:
            continue
        if line[0] in " \t" and current:
            fields[current] += "\n" + line.strip()
            continue
        if ":" in line:
            key, value = line.split(":", 1)
            current = key.strip()
            fields[current] = value.strip()
    return fields


def read_control_tgz(blob):
    with tarfile.open(fileobj=io.BytesIO(blob), mode="r:gz") as tar:
        member = None
        for name in ("control", "./control"):
            try:
                member = tar.getmember(name)
                break
            except KeyError:
                continue
        if member is None:
            raise ValueError("control file not found")
        return tar.extractfile(member).read().decode("utf-8", "replace")


def ipk_control(path):
    """OpenWrt >=24.10: gzip(tar ./debian-binary ./control.tar.gz ./data.tar.gz).
    Legacy opkg: flat ar archive with control.tar.gz member."""
    with open(path, "rb") as f:
        blob = f.read()
    if blob.startswith(AR_MAGIC):
        return parse_control(read_control_tgz(read_ar_member(blob, "control.tar.gz")))
    with tarfile.open(fileobj=io.BytesIO(blob), mode="r:gz") as outer:
        member = None
        for name in ("control.tar.gz", "./control.tar.gz"):
            try:
                member = outer.getmember(name)
                break
            except KeyError:
                continue
        if member is None:
            raise ValueError("control.tar.gz not found in " + os.path.basename(path))
        inner = outer.extractfile(member).read()
    return parse_control(read_control_tgz(inner))


def opkg_entry(path, control):
    stanza = [
        ("Package", control.get("Package", "")),
        ("Version", control.get("Version", "")),
        ("Depends", control.get("Depends", "")),
        ("Conflicts", control.get("Conflicts", "")),
        ("Provides", control.get("Provides", "")),
        ("Replaces", control.get("Replaces", "")),
        ("Section", control.get("Section", "")),
        ("Priority", control.get("Priority", "")),
        ("Architecture", control.get("Architecture", "")),
        ("Installed-Size", control.get("Installed-Size", "")),
        ("Filename", os.path.basename(path)),
        ("Size", str(os.path.getsize(path))),
        ("SHA256sum", sha256_file(path)),
        ("Description", control.get("Description", "")),
    ]
    lines = []
    for key, value in stanza:
        if value == "" and key in ("Depends", "Conflicts", "Provides", "Replaces", "Section", "Priority"):
            continue
        if key == "Description":
            first, *rest = value.split("\n")
            lines.append("Description: " + first)
            for item in rest:
                lines.append(" " + item)
        else:
            lines.append(key + ": " + str(value))
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dist", required=True, help="directory with .apk/.ipk artifacts")
    ap.add_argument("--out", required=True, help="output feed directory")
    ap.add_argument("--base-url", default="", help="repository base URL for index.json")
    ap.add_argument("--tag", default="", help="release tag for index.json")
    ap.add_argument("--apk-tools", default="apk", help="apk-tools 3 binary for apk index")
    ap.add_argument("--no-apk-index", action="store_true", help="skip APKINDEX generation")
    ap.add_argument("--apk-host", default="", help="OpenWrt host apk (with mkndx --sign) for signed packages.adb")
    ap.add_argument("--apk-sign-key", default="", help="EC private key (PEM) for packages.adb signing")
    ap.add_argument("--apk-sign-pub", default="", help="public key (PEM) to verify generated packages.adb")
    args = ap.parse_args()

    dist = os.path.abspath(args.dist)
    out = os.path.abspath(args.out)
    if os.path.commonpath([dist, out]) == out:
        print("refusing to write feed into the artifact directory", file=sys.stderr)
        return 2
    if os.path.isdir(out):
        shutil.rmtree(out)
    os.makedirs(out)

    ipks = sorted(p for p in os.listdir(dist) if p.endswith(".ipk"))
    apks = sorted(p for p in os.listdir(dist) if p.endswith(".apk"))
    if not ipks and not apks:
        print("no .ipk/.apk artifacts in " + dist, file=sys.stderr)
        return 2

    summary = {"signed": bool(args.apk_sign_key), "generated_at": int(time.time()), "tag": args.tag, "base_url": args.base_url, "arches": {}}
    sha_lines = []

    by_arch = {}
    for name in ipks:
        m = IPK_RE.match(name)
        if not m:
            print("skip unexpected ipk name: " + name, file=sys.stderr)
            continue
        arch = m.group("arch")
        by_arch.setdefault(arch, {"ipk": [], "apk": []})["ipk"].append(os.path.join(dist, name))

    for arch, files in sorted(by_arch.items()):
        repo_dir = os.path.join(out, "opkg", arch)
        os.makedirs(repo_dir, exist_ok=True)
        entries = []
        for path in files["ipk"]:
            control = ipk_control(path)
            shutil.copy2(path, os.path.join(repo_dir, os.path.basename(path)))
            entries.append(opkg_entry(path, control))
        packages = "\n\n".join(entries).rstrip() + "\n"
        with open(os.path.join(repo_dir, "Packages"), "w", encoding="utf-8") as f:
            f.write(packages)
        summary["arches"].setdefault(arch, {})["opkg"] = len(entries)
        print("opkg %s: %d package(s)" % (arch, len(entries)))

    by_arch = {}
    for name in apks:
        m = APK_RE.match(name)
        if not m:
            print("skip unexpected apk name: " + name, file=sys.stderr)
            continue
        arch = m.group("arch")
        by_arch.setdefault(arch, []).append(os.path.join(dist, name))

    for arch, files in sorted(by_arch.items()):
        repo_dir = os.path.join(out, "apk", arch)
        os.makedirs(repo_dir, exist_ok=True)
        copied = []
        for path in files:
            m = APK_RE.match(os.path.basename(path))
            if not m:
                continue
            # apk derives the download name as <name>-<version>.apk (repository
            # artifacts are not named with underscores/arch like release assets).
            dst = os.path.join(repo_dir, m.group("name") + "-" + m.group("version") + ".apk")
            shutil.copy2(path, dst)
            copied.append(dst)
        if args.no_apk_index:
            print("apk %s: %d package(s), APKINDEX skipped" % (arch, len(copied)), file=sys.stderr)
        else:
            index_path = os.path.join(repo_dir, "APKINDEX.tar.gz")
            cmd = [args.apk_tools, "--allow-untrusted", "index", "-o", index_path, "--rewrite-arch", arch, "--no-warnings"] + copied
            proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            if proc.returncode != 0:
                sys.stderr.write(proc.stdout or "")
                print("apk index failed for " + arch, file=sys.stderr)
                return 3
            print("apk %s: %d package(s), APKINDEX ok" % (arch, len(copied)))
        if args.apk_sign_key:
            if not args.apk_host:
                print("--apk-sign-key requires --apk-host", file=sys.stderr)
                return 4
            adb_path = os.path.join(repo_dir, "packages.adb")
            cmd = [args.apk_host, "mkndx", "--allow-untrusted", "--sign", args.apk_sign_key,
                   "--output", adb_path, "--pkgname-spec", "${name}-${version}.apk"] + copied
            proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            if proc.returncode != 0:
                sys.stderr.write(proc.stdout or "")
                print("signed packages.adb failed for " + arch, file=sys.stderr)
                return 5
            if args.apk_sign_pub:
                import tempfile
                with tempfile.TemporaryDirectory() as kd:
                    shutil.copy2(args.apk_sign_pub, os.path.join(kd, "zapret2wizard-apk.pem"))
                    dump = subprocess.run([args.apk_host, "adbdump", "--keys-dir", kd, adb_path],
                                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
                    sig_line = [l for l in (dump.stdout or "").splitlines() if l.startswith("# sig ")]
                    if dump.returncode != 0 or not sig_line or ": OK" not in sig_line[-1]:
                        sys.stderr.write(dump.stdout or "")
                        print("signed packages.adb verification failed for " + arch, file=sys.stderr)
                        return 6
            print("apk %s: signed packages.adb (%d package(s))" % (arch, len(copied)))
        summary["arches"].setdefault(arch, {})["opkg"] = len(entries)
        print("opkg %s: %d package(s)" % (arch, len(entries)))

    by_arch = {}
    for name in apks:
        m = APK_RE.match(name)
        if not m:
            print("skip unexpected apk name: " + name, file=sys.stderr)
            continue
        arch = m.group("arch")
        by_arch.setdefault(arch, []).append(os.path.join(dist, name))

    for arch, files in sorted(by_arch.items()):
        repo_dir = os.path.join(out, "apk", arch)
        os.makedirs(repo_dir, exist_ok=True)
        copied = []
        for path in files:
            m = APK_RE.match(os.path.basename(path))
            if not m:
                continue
            # apk derives the download name as <name>-<version>.apk (repository
            # artifacts are not named with underscores/arch like release assets).
            dst = os.path.join(repo_dir, m.group("name") + "-" + m.group("version") + ".apk")
            shutil.copy2(path, dst)
            copied.append(dst)
        if args.no_apk_index:
            print("apk %s: %d package(s), APKINDEX skipped" % (arch, len(copied)), file=sys.stderr)
        if args.apk_sign_key:
            if not args.apk_host:
                print("--apk-sign-key requires --apk-host", file=sys.stderr)
                return 4
            adb_path = os.path.join(repo_dir, "packages.adb")
            cmd = [args.apk_host, "mkndx", "--allow-untrusted", "--sign", args.apk_sign_key,
                   "--output", adb_path, "--pkgname-spec", "${name}-${version}.apk"] + copied
            proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            if proc.returncode != 0:
                sys.stderr.write(proc.stdout or "")
                print("signed packages.adb failed for " + arch, file=sys.stderr)
                return 5
            if args.apk_sign_pub:
                import tempfile
                with tempfile.TemporaryDirectory() as kd:
                    shutil.copy2(args.apk_sign_pub, os.path.join(kd, "zapret2wizard-apk.pem"))
                    dump = subprocess.run([args.apk_host, "adbdump", "--keys-dir", kd, adb_path],
                                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
                    sig_line = [l for l in (dump.stdout or "").splitlines() if l.startswith("# sig ")]
                    if dump.returncode != 0 or not sig_line or ": OK" not in sig_line[-1]:
                        sys.stderr.write(dump.stdout or "")
                        print("signed packages.adb verification failed for " + arch, file=sys.stderr)
                        return 6
            print("apk %s: signed packages.adb (%d package(s))" % (arch, len(copied)))
        else:
            index_path = os.path.join(repo_dir, "APKINDEX.tar.gz")
            cmd = [args.apk_tools, "--allow-untrusted", "index", "-o", index_path, "--rewrite-arch", arch, "--no-warnings"] + copied
            proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            if proc.returncode != 0:
                sys.stderr.write(proc.stdout or "")
                print("apk index failed for " + arch, file=sys.stderr)
                return 3
            print("apk %s: %d package(s), APKINDEX ok" % (arch, len(copied)))
        summary["arches"].setdefault(arch, {})["apk"] = len(copied)

    for base, _dirs, files in os.walk(out):
        for name in sorted(files):
            path = os.path.join(base, name)
            rel = os.path.relpath(path, out).replace(os.sep, "/")
            if rel in ("SHA256SUMS", "index.json"):
                continue
            sha_lines.append("%s  %s" % (sha256_file(path), rel))
    sha_lines.sort(key=lambda line: line.split("  ", 1)[1])
    with open(os.path.join(out, "SHA256SUMS"), "w", encoding="utf-8") as f:
        f.write("\n".join(sha_lines) + "\n")
    with open(os.path.join(out, "index.json"), "w", encoding="utf-8") as f:
        json.dump(summary, f, ensure_ascii=False, indent=2, sort_keys=True)
        f.write("\n")
    print("feed written to " + out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
