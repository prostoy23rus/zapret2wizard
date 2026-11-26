#!/usr/bin/env python3
"""Offline regression for packaging/build-feed.py (opkg Packages path)."""

import gzip
import io
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile


def write_ipk(path, control_tgz):
    """OpenWrt >=24.10 ipk: gzip(tar ./debian-binary ./control.tar.gz ./data.tar.gz)."""
    data_tgz = io.BytesIO()
    with tarfile.open(fileobj=data_tgz, mode="w:gz") as tar:
        pass
    with tarfile.open(path, mode="w:gz") as tar:
        for name, payload in (
            ("./debian-binary", b"2.0\n"),
            ("./control.tar.gz", control_tgz),
            ("./data.tar.gz", data_tgz.getvalue()),
        ):
            info = tarfile.TarInfo(name)
            info.size = len(payload)
            tar.addfile(info, io.BytesIO(payload))


def make_control_tgz():
    buf = io.BytesIO()
    control = (
        "Package: luci-app-blockcheckw\n"
        "Version: 9.9.9-1\n"
        "Depends: libc, luci-base, nftables\n"
        "Architecture: aarch64_cortex-a53\n"
        "Installed-Size: 123\n"
        "Section: luci\n"
        "Priority: optional\n"
        "Description: Test package\n"
        " Second line of description.\n"
    ).encode()
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        info = tarfile.TarInfo("control")
        info.size = len(control)
        tar.addfile(info, io.BytesIO(control))
    return buf.getvalue()


def main():
    tmp = tempfile.mkdtemp()
    try:
        dist = os.path.join(tmp, "dist")
        out = os.path.join(tmp, "feed")
        os.makedirs(dist)
        ipk = os.path.join(dist, "luci-app-blockcheckw_9.9.9-1_aarch64_cortex-a53.ipk")
        write_ipk(ipk, make_control_tgz())
        with open(os.path.join(dist, "zapret2wizard_9.9.9-r9_aarch64_cortex-a53.apk"), "wb") as f:
            f.write(b"fake apk")
        script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "packaging", "build-feed.py")
        proc = subprocess.run([sys.executable, script, "--dist", dist, "--out", out, "--tag", "v9.9.9", "--no-apk-index"],
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        if proc.returncode != 0:
            print(proc.stdout)
            return 1
        packages = os.path.join(out, "opkg", "aarch64_cortex-a53", "Packages")
        text = open(packages, encoding="utf-8").read()
        checks = [
            "Package: luci-app-blockcheckw",
            "Version: 9.9.9-1",
            "Architecture: aarch64_cortex-a53",
            "Filename: luci-app-blockcheckw_9.9.9-1_aarch64_cortex-a53.ipk",
            "SHA256sum: ",
            "Description: Test package",
            " Second line of description.",
        ]
        for item in checks:
            if item not in text:
                print("FAIL: Packages missing", item)
                return 1
        if not os.path.exists(os.path.join(out, "opkg", "aarch64_cortex-a53",
                                           "luci-app-blockcheckw_9.9.9-1_aarch64_cortex-a53.ipk")):
            print("FAIL: ipk not copied")
            return 1
        apk_canonical = os.path.join(out, "apk", "aarch64_cortex-a53", "zapret2wizard-9.9.9-r9.apk")
        if not os.path.exists(apk_canonical):
            print("FAIL: apk not copied under canonical name")
            return 1
        if os.path.exists(os.path.join(out, "apk", "aarch64_cortex-a53", "zapret2wizard_9.9.9-r9_aarch64_cortex-a53.apk")):
            print("FAIL: apk copied under non-canonical name")
            return 1
        sums = open(os.path.join(out, "SHA256SUMS"), encoding="utf-8").read()
        if "Packages" not in sums or "SHA256SUMS" in sums:
            print("FAIL: SHA256SUMS")
            return 1
        import json
        meta = json.load(open(os.path.join(out, "index.json"), encoding="utf-8"))
        if meta["arches"]["aarch64_cortex-a53"]["opkg"] != 1:
            print("FAIL: index.json")
            return 1
        print("OK: build-feed opkg Packages + copies + SHA256SUMS + index.json")
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
