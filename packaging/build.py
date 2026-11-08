#!/usr/bin/env python3
"""Сборка пакетов Zapret2Wizard: .ipk (opkg) и универсального bundle (.tar.gz).

Пакет самодостаточный: внутри LuCI-приложение, helper, сканер blockcheckw,
движок nfqws2 под выбранную архитектуру, конфиг, init-скрипт, списки и Lua.

Пример:
    python packaging/build.py --arch aarch64_cortex-a53 \\
        --engine openwrt/engine/nfqws2-linux-arm64 \\
        --scanner ../deepseek/build/blockcheckw-aarch64
"""

import argparse
import gzip
import io
import json
import os
import shutil
import sys
import tarfile
import time

REPO_NAME = "luci-app-blockcheckw"
PKG_NAME = "luci-app-blockcheckw"


def read_version(repo: str) -> str:
    with open(os.path.join(repo, "openwrt", "version.json"), "r", encoding="utf-8") as f:
        return json.load(f)["version"]


def collect_files(repo: str, engine: str, scanner: str):
    """Возвращает список (relative_path, source_path, mode, link_target|None)."""
    root = os.path.join(repo, "openwrt", REPO_NAME, "root")
    items = []

    for base, _dirs, files in os.walk(root):
        for name in files:
            src = os.path.join(base, name)
            rel = os.path.relpath(src, root).replace("\\", "/")
            mode = 0o755 if name in ("blockcheckw-helper", "zapret2wizard", "uci2config") else 0o644
            items.append((rel, src, mode, None))

    if engine:
        items.append(("usr/bin/nfqws2", engine, 0o755, None))
    if scanner:
        items.append(("usr/bin/blockcheckw", scanner, 0o755, None))

    # совместимость путей: scanner ищет движок в /opt/zapret2/nfq2/nfqws2
    items.append(("opt/zapret2/nfq2/nfqws2", None, 0o777, "/usr/bin/nfqws2"))
    items.append(("usr/bin/zapret2wizard", None, 0o777, "/usr/bin/blockcheckw-helper"))
    return items


def add_dir(tar, path):
    info = tarfile.TarInfo(path)
    info.type = tarfile.DIRTYPE
    info.mode = 0o755
    info.mtime = 1600000000
    info.uid = info.gid = 0
    info.uname = info.gname = "root"
    tar.addfile(info)


def build_data_tar(items, base_dir="."):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as tar:
        dirs = set()
        for rel, _src, _mode, _link in items:
            parts = rel.split("/")[:-1]
            for i in range(1, len(parts) + 1):
                d = "/".join(parts[:i])
                if d and d not in dirs:
                    dirs.add(d)
                    add_dir(tar, f"{base_dir}/{d}")
        for rel, src, mode, link in items:
            info = tarfile.TarInfo(f"{base_dir}/{rel}")
            info.mode = mode
            info.mtime = 1600000000
            info.uid = info.gid = 0
            info.uname = info.gname = "root"
            if link:
                info.type = tarfile.SYMTYPE
                info.linkname = link
                tar.addfile(info)
            else:
                with open(src, "rb") as f:
                    data = f.read()
                info.size = len(data)
                tar.addfile(info, io.BytesIO(data))
    return buf.getvalue()


def gz(data: bytes, mtime: int = 0) -> bytes:
    out = io.BytesIO()
    with gzip.GzipFile(fileobj=out, mode="wb", compresslevel=9, mtime=mtime) as g:
        g.write(data)
    return out.getvalue()


def build_control_tar(control: str, scripts: dict) -> bytes:
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as tar:
        for name, content in [("./control", control)] + list(scripts.items()):
            data = content.encode("utf-8")
            info = tarfile.TarInfo(name)
            info.mode = 0o755 if name.startswith("./post") or name.startswith("./pre") else 0o644
            info.size = len(data)
            info.mtime = 1600000000
            info.uid = info.gid = 0
            info.uname = info.gname = "root"
            tar.addfile(info, io.BytesIO(data))
    return buf.getvalue()


def ar_entry(name: str, data: bytes) -> bytes:
    header = (
        f"{name:<16}{int(time.time()):<12}{0:<6}{0:<6}{'100644':<8}{len(data):<10}`\n"
    ).encode("ascii")
    pad = b"\n" if len(data) % 2 else b""
    return header + data + pad


def build_ipk(items, control: str, scripts: dict, out_path: str):
    data_tgz = gz(build_data_tar(items))
    ctrl_tgz = gz(build_control_tar(control, scripts))
    with open(out_path, "wb") as f:
        f.write(b"!<arch>\n")
        f.write(ar_entry("debian-binary", b"2.0\n"))
        f.write(ar_entry("control.tar.gz", ctrl_tgz))
        f.write(ar_entry("data.tar.gz", data_tgz))


BUNDLE_INSTALLER = r"""#!/bin/sh
# Установка Zapret2Wizard из автономного бандла (без интернета).
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
echo "=== Zapret2Wizard bundle installer ==="

if [ ! -d "$HERE/payload" ]; then
    echo "  распаковываю payload..."
    tar -xf "$HERE/payload.tar" -C "$HERE"
fi

# Не перетираем существующий конфиг со стратегиями при обновлении.
if [ -f /etc/config/zapret2wizard ] && [ -f "$HERE/payload/etc/config/zapret2wizard" ]; then
    cp -f /etc/config/zapret2wizard /tmp/zapret2wizard.cfg.keep
    rm -f "$HERE/payload/etc/config/zapret2wizard"
    echo "  существующий конфиг сохранён"
fi

mkdir -p /usr/bin /etc/init.d /etc/config /usr/share/blockcheckw \
         /usr/share/luci/menu.d /usr/share/rpcd/acl.d \
         /usr/share/zapret2wizard /etc/zapret2wizard/ipset \
         /www/luci-static/resources/view/blockcheckw /opt/zapret2/nfq2

cp -a "$HERE/payload/." /

chmod +x /usr/bin/blockcheckw-helper /usr/bin/circular-builder.lua \
         /usr/bin/nfqws2 /usr/bin/blockcheckw /etc/init.d/zapret2wizard \
         /usr/share/zapret2wizard/uci2config 2>/dev/null || true
chmod 644 /www/luci-static/resources/view/blockcheckw/main.js 2>/dev/null || true

[ -e /usr/bin/zapret2wizard ] || ln -sf /usr/bin/blockcheckw-helper /usr/bin/zapret2wizard
[ -e /opt/zapret2/nfq2/nfqws2 ] || ln -sf /usr/bin/nfqws2 /opt/zapret2/nfq2/nfqws2

rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache* 2>/dev/null || true
/etc/init.d/rpcd restart >/dev/null 2>&1 || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true

/etc/init.d/zapret2wizard enable >/dev/null 2>&1 || true
/etc/init.d/zapret2wizard restart >/dev/null 2>&1 || true
sleep 2

echo "  установлено. Проверка:"
/usr/bin/blockcheckw-helper doctor 2>/dev/null | head -14 || true
echo
echo "Откройте LuCI → Службы → Zapret2Wizard и запустите поиск."
"""


def build_bundle(items, version: str, arch: str, out_path: str):
    payload = io.BytesIO()
    with tarfile.open(fileobj=payload, mode="w") as tar:
        for rel, src, mode, link in items:
            info = tarfile.TarInfo(f"payload/{rel}")
            info.mode = mode
            info.mtime = 1600000000
            info.uid = info.gid = 0
            info.uname = info.gname = "root"
            if link:
                info.type = tarfile.SYMTYPE
                info.linkname = link
                tar.addfile(info)
            else:
                with open(src, "rb") as f:
                    data = f.read()
                info.size = len(data)
                tar.addfile(info, io.BytesIO(data))

    import hashlib
    payload_bytes = payload.getvalue()
    digest = hashlib.sha256(payload_bytes).hexdigest()

    with open(out_path, "wb") as f:
        with tarfile.open(fileobj=f, mode="w:gz") as tar:
            for name, content in [
                (f"zapret2wizard-{version}-{arch}/install.sh", BUNDLE_INSTALLER),
                (f"zapret2wizard-{version}-{arch}/payload.tar", payload_bytes),
                (f"zapret2wizard-{version}-{arch}/README.txt",
                 f"Zapret2Wizard {version} (autonomous bundle, {arch})\n\n"
                 "Установка:\n"
                 "  tar -xzf <этот файл> -C /tmp\n"
                 "  cd /tmp/zapret2wizard-* && sh install.sh\n\n"
                 "Ничего не скачивается: все зависимости внутри.\n"),
            ]:
                data = content.encode("utf-8") if isinstance(content, str) else content
                info = tarfile.TarInfo(name)
                info.mode = 0o755 if name.endswith("install.sh") else 0o644
                info.size = len(data)
                info.mtime = 1600000000
                tar.addfile(info, io.BytesIO(data))


POSTINST = """#!/bin/sh
[ -n "$IPKG_INSTROOT" ] && exit 0
rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache* 2>/dev/null || true
/etc/init.d/rpcd restart >/dev/null 2>&1 || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true
/etc/init.d/zapret2wizard enable >/dev/null 2>&1 || true
/etc/init.d/zapret2wizard restart >/dev/null 2>&1 || true
exit 0
"""

PRERM = """#!/bin/sh
[ -n "$IPKG_INSTROOT" ] && exit 0
/etc/init.d/zapret2wizard stop >/dev/null 2>&1 || true
/etc/init.d/zapret2wizard disable >/dev/null 2>&1 || true
exit 0
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default=".")
    ap.add_argument("--arch", required=True, help="например aarch64_cortex-a53")
    ap.add_argument("--engine", required=True)
    ap.add_argument("--scanner", default="")
    ap.add_argument("--out", default="dist")
    args = ap.parse_args()

    repo = os.path.abspath(args.repo)
    version = read_version(repo)
    items = collect_files(repo, os.path.abspath(args.engine),
                          os.path.abspath(args.scanner) if args.scanner else "")
    total_size = sum(os.path.getsize(src) for _r, src, _m, l in items if src)
    os.makedirs(args.out, exist_ok=True)

    control = (
        f"Package: {PKG_NAME}\n"
        f"Version: {version}-1\n"
        f"Depends: libc, luci-base, nftables, curl, ca-bundle\n"
        f"Section: luci\n"
        f"Priority: optional\n"
        f"Architecture: {args.arch}\n"
        f"Installed-Size: {int(total_size / 1024)}\n"
        f"Maintainer: prostoy23rus <https://github.com/prostoy23rus/zapret2wizard>\n"
        f"Description: Zapret2Wizard {version} — автономный обход DPI (Zapret2)\n"
        f" Включает LuCI-интерфейс, helper, сканер blockcheckw и движок nfqws2.\n"
    )

    # .ipk собирается отдельным скриптом packaging/build-ipk.sh (GNU ar в WSL):
    # у самодельного ar встречаются проблемы совместимости с opkg.
    bundle = os.path.join(args.out, f"zapret2wizard-{version}-{args.arch}-bundle.tar.gz")
    build_bundle(items, version, args.arch, bundle)
    print("bundle:", bundle, os.path.getsize(bundle), "bytes")


if __name__ == "__main__":
    main()
