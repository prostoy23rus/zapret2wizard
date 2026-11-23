#!/usr/bin/env python3
"""Build artifacts in a disposable directory and inspect the shipped owner/hooks."""
import importlib.util
import io
from pathlib import Path
import subprocess
import tarfile
import tempfile

repo = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("bcw_packaging", repo / "packaging/build.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
with tempfile.TemporaryDirectory(prefix="bcw-packaging-") as temp:
    temp = Path(temp)
    engine = temp / "nfqws2"
    engine.write_text("fixture engine, never executed")
    result = subprocess.run(["bash", str(repo / "packaging/build-ipk.sh"), "test", str(engine), "", str(temp)], capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr
    with tarfile.open(next(temp.glob("*.ipk"))) as outer:
        with tarfile.open(fileobj=io.BytesIO(outer.extractfile("./control.tar.gz").read())) as control:
            hook = control.extractfile("./prerm").read().decode()
            assert "bcw_lifecycle_prepare_remove" in hook and '"$1" = upgrade' in hook
        with tarfile.open(fileobj=io.BytesIO(outer.extractfile("./data.tar.gz").read())) as data:
            assert data.extractfile("./usr/share/zapret2wizard/lifecycle.sh").read().startswith(b"#!/bin/sh")
    bundle = temp / "bundle.tar.gz"
    module.build_bundle(module.collect_files(str(repo), str(engine), ""), "test", "test", str(bundle))
    with tarfile.open(bundle) as outer:
        with tarfile.open(fileobj=io.BytesIO(outer.extractfile("zapret2wizard-test-test/payload.tar").read())) as data:
            assert any(x.name.endswith("/usr/share/zapret2wizard/lifecycle.sh") for x in data.getmembers())
    apk = (repo / "packaging/build-apk.sh").read_text()
    assert "bcw_lifecycle_prepare_remove || exit 1" in apk
    sdk = (repo / "openwrt/luci-app-blockcheckw/Makefile").read_text()
    assert "define Package/luci-app-blockcheckw/prerm" in sdk
    assert "bcw_lifecycle_prepare_remove || exit 1" in sdk
print("PASS: IPK owner + checked removal/upgrade hook; bundle owner; APK hook wiring")
