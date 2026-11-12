#!/usr/bin/env python3
"""Phase-1 Zstd migration gate: build the same tree as XZ and Zstd and compare.

Proves, on real archives produced by the real assembler CLI:
  - both formats emit base + engine with the documented names;
  - manifest sha256/bytes match the files on disk and the asset names match COMPRESS;
  - the two formats decompress to byte-identical tar trees (same normalized entries);
  - a valid base cache is reused without recompressing;
  - changing the Zstd level or thread count invalidates the cache.

Run directly: python3 runtime/tests/verify-compression-parity.py
"""
import hashlib
import io
import json
import lzma
import shutil
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]
RTBUILD = HERE / "lib" / "rtbuild.py"
ABI = "arm64-v8a"
LAYER_SUFFIX = {"xz": ".tar.xz", "zstd": ".tar.zstd", "gz": ".tar.gz"}


def make_fixture(root):
    """A tiny rootfs tree covering the entry kinds TarExtractor must restore."""
    def archive(path, rows):
        with tarfile.open(path, "w:gz", format=tarfile.GNU_FORMAT) as tar:
            for name, kind, value, mode in rows:
                item = tarfile.TarInfo(name)
                item.mode = mode
                if kind == "file":
                    data = value.encode()
                    item.size = len(data)
                    tar.addfile(item, io.BytesIO(data))
                else:
                    item.type = {"dir": tarfile.DIRTYPE, "symlink": tarfile.SYMTYPE,
                                 "hardlink": tarfile.LNKTYPE}[kind]
                    item.linkname = value
                    tar.addfile(item)

    archive(root / "ubuntu.gz", [
        ("usr/lib/os-release", "file", 'ID=ubuntu\nVERSION_ID="24.04"\n', 0o644),
        ("etc/os-release", "symlink", "../usr/lib/os-release", 0o777),
        ("usr/lib/fixture", "file", "base content", 0o4755),
        ("usr/lib/copy", "hardlink", "usr/lib/fixture", 0o644),
        ("tmp", "dir", "", 0o1777),
    ])
    archive(root / "node.gz", [("node/bin/node", "file", "node fixture", 0o755)])
    dsh = root / "dsh/node_modules/example/index.js"
    dsh.parent.mkdir(parents=True)
    dsh.write_text("synthetic engine input")
    bridge = root / "bridge/lib/index.js"
    bridge.parent.mkdir(parents=True)
    bridge.write_text("synthetic bridge input")
    pnpm = root / "pnpm/node_modules/pnpm/bin"
    pnpm.mkdir(parents=True)
    (pnpm / "pnpm.mjs").write_text("pnpm fixture")
    return {"ubuntu": hashlib.sha256((root / "ubuntu.gz").read_bytes()).hexdigest()}


def run(root, compress, out, level=None, threads=None, cache=None):
    """Assemble layered base+engine via the real CLI; return the parsed report."""
    out.mkdir(parents=True, exist_ok=True)
    command = [sys.executable, "-I", str(RTBUILD), "assemble", "--abi", ABI,
               "--base", str(root / "ubuntu.gz"), "--node", str(root / "node.gz"),
               "--dsh-prefix", str(root / "dsh"), "--pnpm-prefix", str(root / "pnpm"),
               "--bridge", str(root / "bridge"),
               "--runtime-info", json.dumps({"runtimeVersion": "verify", "abi": ABI,
                                             "ubuntuVersion": "24.04.5", "dshVersion": "0",
                                             "nodeVersion": "0", "pnpmVersion": "0",
                                             "prootVersion": "0", "dshPatches": [],
                                             "dshGoBridge": "0"}),
               "--report", str(out / "report.json"), "--compress", compress,
               "--base-out", str(out / ("base-" + ABI + LAYER_SUFFIX[compress])),
               "--engine-out", str(out / ("engine-" + ABI + LAYER_SUFFIX[compress])),
               "--base-cache", str(cache or (out / "cache")),
               "--zstd-level", str(level if level is not None else 3),
               "--zstd-threads", str(threads if threads is not None else 4),
               "--epoch", "1767225600"]
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit("assemble %s failed:\n%s" % (compress, result.stderr))
    return json.loads((out / "report.json").read_text())


def decompress(path):
    if path.suffix == ".xz":
        return lzma.decompress(path.read_bytes())
    return subprocess.run(["zstd", "-dc"], input=path.read_bytes(),
                          stdout=subprocess.PIPE, check=True).stdout


def check_layer(root, report, kind, compress):
    layer = report["layers"][kind]
    suffix = LAYER_SUFFIX[compress]
    assert layer["asset"] == "%s-%s%s" % (kind, ABI, suffix), layer["asset"]
    data = (root / layer["asset"]).read_bytes()
    assert layer["sha256"] == hashlib.sha256(data).hexdigest(), kind
    assert layer["bytes"] == len(data), kind
    tar = decompress(root / layer["asset"])
    assert layer["tarBytes"] == len(tar), kind
    assert layer["tarSha256"] == hashlib.sha256(tar).hexdigest(), kind
    return tar


def check_cache_reuse(root, first, second):
    assert second["baseCache"]["status"] == "reused", second["baseCache"]
    assert second["baseCache"]["key"] == first["baseCache"]["key"]
    assert second["layers"]["base"] == first["layers"]["base"]


def check_cache_invalidated(root, changed, first):
    assert changed["baseCache"]["status"] != "reused", changed["baseCache"]
    assert changed["baseCache"]["key"] != first["baseCache"]["key"]


def main():
    for tool in ("xz", "zstd"):
        if not shutil.which(tool):
            raise SystemExit("missing host tool: %s" % tool)
    print("xz:      ", subprocess.check_output(["xz", "--version"], text=True).splitlines()[0])
    print("zstd:    ", subprocess.check_output(["zstd", "--version"], text=True).splitlines()[0])

    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        make_fixture(root)

        xz = run(root, "xz", root / "out-xz")
        zstd = run(root, "zstd", root / "out-zstd")

        # 1. Both formats produce base + engine with the documented names and hashes.
        for kind in ("base", "engine"):
            xz_tar = check_layer(root / "out-xz", xz, kind, "xz")
            zstd_tar = check_layer(root / "out-zstd", zstd, kind, "zstd")
            # 2. The two formats decompress to a byte-identical normalized tree.
            assert xz_tar == zstd_tar, "%s tar bytes differ between xz and zstd" % kind
            print("%-6s tar sha256 %s  (xz %d B -> xz archive %d B, zstd archive %d B)" % (
                kind, hashlib.sha256(zstd_tar).hexdigest()[:12],
                len(zstd_tar), xz["layers"][kind]["bytes"], zstd["layers"][kind]["bytes"]))

        # 3. A second identical Zstd build reuses the validated base cache bytes.
        zstd_again = run(root, "zstd", root / "out-zstd-again", cache=root / "out-zstd/cache")
        check_cache_reuse(root / "out-zstd", zstd, zstd_again)
        print("cache: identical rebuild reused base bytes")

        # 4. Changing the Zstd level or thread count invalidates the cache.
        for field, value in (("level", 5), ("threads", 2)):
            changed = run(root, "zstd", root / ("out-zstd-%s" % value),
                          **{field: value}, cache=root / "out-zstd/cache")
            check_cache_invalidated(root / "out-zstd", changed, zstd)
            print("cache: zstd %s=%s invalidated the base cache" % (field, value))

    print("compression parity OK")


if __name__ == "__main__":
    main()