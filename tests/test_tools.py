#!/usr/bin/env python3
"""Exercise installer archive/cache contracts without upstream or S3 access."""
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class ToolsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.bin = self.base / "bin"
        self.bin.mkdir()
        self.mapping = {}
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                        RUNNER_TOOL_CACHE=str(self.base / "cache"),
                        FIXTURES=str(self.base), TEST_ARCH="x86_64",
                        S3_WRITE="true", GITHUB_EVENT_NAME="push",
                        GITHUB_REF="refs/heads/main", DEFAULT_BRANCH="main")
        self.executable("uname", '#!/bin/sh\necho "$TEST_ARCH"\n')
        self.executable("curl", """#!/usr/bin/env python3
import json, os, pathlib, sys
base = pathlib.Path(os.environ['FIXTURES'])
args = sys.argv[1:]
url = next(a for a in args if a.startswith('https://'))
with (base / 'requests').open('a') as f:
    f.write(url + '\\n')
mapping = json.loads((base / 'mapping.json').read_text())
if url not in mapping:
    sys.exit(22)
data = pathlib.Path(mapping[url]).read_bytes()
if '-o' in args:
    pathlib.Path(args[args.index('-o') + 1]).write_bytes(data)
else:
    sys.stdout.buffer.write(data)
""")
        # macOS has shasum; Linux runners provide sha256sum directly.
        if not shutil.which("sha256sum"):
            self.executable("sha256sum", '#!/bin/sh\nexec shasum -a 256 "$@"\n')

    def executable(self, name, text):
        path = self.bin / name
        path.write_text(text)
        path.chmod(0o755)

    def document(self, url, value):
        path = self.base / f"document-{len(self.mapping)}"
        path.write_text(json.dumps(value) if not isinstance(value, str) else value)
        self.mapping[url] = str(path)

    def archive(self, name, version, arch, layout, bad_hash=False):
        triple = f"{arch}-unknown-linux-musl"
        if name == "zig":
            asset = f"zig-linux-{arch}-{version}" if layout == "old" else f"zig-{arch}-linux-{version}"
            filename, mode = f"{asset}.tar.xz", "w:xz"
            url = f"https://ziglang.org/download/{version}/{filename}"
            entries = {f"{asset}/zig": b'#!/bin/sh\ntest -f "$(dirname "$0")/lib/std/std.zig"\n',
                       f"{asset}/lib/std/std.zig": b"std library",
                       f"{asset}/lib/compiler_rt.zig": b"compiler runtime"}
        elif name == "cargo-zigbuild":
            if layout == "old":
                filename, mode = f"cargo-zigbuild-v{version}.{triple}.tar.gz", "w:gz"
                entry = name
            else:
                triple = f"{arch}-unknown-linux-gnu" if arch == "aarch64" else triple
                asset = f"cargo-zigbuild-{triple}"
                filename, mode = f"{asset}.tar.xz", "w:xz"
                entry = f"{asset}/{name}"
            url = f"https://github.com/rust-cross/cargo-zigbuild/releases/download/v{version}/{filename}"
            entries = {entry: b"#!/bin/sh\nexit 0\n"}
        else:
            asset = f"cargo-deny-{version}-{triple}" if name == "cargo-deny" else f"sccache-v{version}-{triple}"
            filename, mode = f"{asset}.tar.gz", "w:gz"
            owner, tag = ("EmbarkStudios/cargo-deny", version) if name == "cargo-deny" else ("mozilla/sccache", f"v{version}")
            url = f"https://github.com/{owner}/releases/download/{tag}/{filename}"
            entries = {f"{asset}/{name}": b"#!/bin/sh\nexit 0\n"}
        path = self.base / filename
        with tarfile.open(path, mode) as archive:
            for entry, data in entries.items():
                info = tarfile.TarInfo(entry)
                info.size, info.mode = len(data), 0o755 if entry.endswith(name) else 0o644
                archive.addfile(info, io.BytesIO(data))
        digest = "0" * 64 if bad_hash else hashlib.sha256(path.read_bytes()).hexdigest()
        self.mapping[url] = str(path)
        if name == "zig":
            self.document("https://ziglang.org/download/index.json", {version: {f"{arch}-linux": {"tarball": url, "shasum": digest}}})
        else:
            self.document(url + ".sha256", digest + "  " + filename + "\n")
            if name == "cargo-zigbuild":
                self.document(f"https://api.github.com/repos/rust-cross/cargo-zigbuild/releases/tags/v{version}", {"assets": [{"name": filename, "browser_download_url": url}]})
        return self.base / "cache" / "arc-tools" / name / version / arch

    def install(self, name, version, success=True):
        (self.base / "mapping.json").write_text(json.dumps(self.mapping))
        script = '''set -uo pipefail
source "$1/lib/common.sh"
source "$1/lib/tool.sh"
s3_configured() { return 0; }
s3_get() { test -f "$FIXTURES/s3/$1" || return 1; cp "$FIXTURES/s3/$1" "$2"; }
s3_put() { mkdir -p "$(dirname "$FIXTURES/s3/$1")"; cp "$2" "$FIXTURES/s3/$1"; }
tool_install "$2" "$3"
printf 'HIT=%s\\n' "$TOOL_HIT"
"$TOOL_DIR/$2"
'''
        result = subprocess.run(["bash", "-c", script, "test", str(ROOT), name, version],
                                env=self.env, text=True, capture_output=True)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def roundtrip(self, name, version, arch, layout):
        self.env["TEST_ARCH"] = arch
        dest = self.archive(name, version, arch, layout)
        self.assertIn("HIT=false", self.install(name, version).stdout)
        self.mapping.clear()  # No upstream access can succeed on either cache hit.
        self.assertIn("HIT=true", self.install(name, version).stdout)
        shutil.rmtree(dest)
        self.assertIn("HIT=true", self.install(name, version).stdout)
        if name == "zig":
            self.assertEqual((dest / "lib/compiler_rt.zig").read_text(), "compiler runtime")

    def test_zig_architectures_and_layouts(self):
        for arch in ("x86_64", "aarch64"):
            for version, layout in (("0.13.0", "old"), ("0.15.2", "new")):
                with self.subTest(arch=arch, version=version):
                    self.roundtrip("zig", version, arch, layout)

    def test_cargo_zigbuild_architectures_and_layouts(self):
        for arch in ("x86_64", "aarch64"):
            for version, layout in (("0.20.1", "old"), ("0.24.1", "new")):
                with self.subTest(arch=arch, version=version):
                    self.roundtrip("cargo-zigbuild", version, arch, layout)

    def test_existing_tools(self):
        for name in ("cargo-deny", "sccache"):
            with self.subTest(name=name):
                self.roundtrip(name, "0.20.2", "x86_64", "old")

    def test_checksum_mismatch_does_not_install_or_upload(self):
        for name in ("zig", "cargo-zigbuild"):
            with self.subTest(name=name):
                dest = self.archive(name, "0.15.2", "x86_64", "new", bad_hash=True)
                self.install(name, "0.15.2", success=False)
                self.assertFalse((dest / name).exists())
                self.assertFalse((self.base / "s3").exists())

    def test_incomplete_zig_local_and_s3_cache_fall_back(self):
        dest = self.archive("zig", "0.15.2", "x86_64", "new")
        dest.mkdir(parents=True)
        (dest / "zig").write_text("#!/bin/sh\nexit 0\n")
        (dest / "zig").chmod(0o755)
        key = self.base / "s3/tools/zig/0.15.2/x86_64.tar.gz"
        key.parent.mkdir(parents=True)
        with tarfile.open(key, "w:gz") as archive:
            archive.add(dest / "zig", arcname="zig")
        self.assertIn("HIT=false", self.install("zig", "0.15.2").stdout)
        self.assertTrue((dest / "lib/std/std.zig").is_file())

    def test_untrusted_context_cannot_upload(self):
        self.archive("zig", "0.15.2", "x86_64", "new")
        self.env["GITHUB_EVENT_NAME"] = "pull_request"
        self.install("zig", "0.15.2")
        self.assertFalse((self.base / "s3").exists())

    def test_exact_versions_and_supported_tools_only(self):
        self.install("zig", "latest", success=False)
        self.install("unknown", "1.2.3", success=False)
        self.assertFalse((self.base / "requests").exists())

    def test_action_exports_both_tools_and_aggregate_cache_hit(self):
        self.archive("zig", "0.15.2", "x86_64", "new")
        self.archive("cargo-zigbuild", "0.24.1", "x86_64", "new")
        (self.base / "mapping.json").write_text(json.dumps(self.mapping))
        output, paths = self.base / "output", self.base / "paths"
        env = dict(self.env, TOOLS="zig@0.15.2,cargo-zigbuild@0.24.1",
                   S3_ENDPOINT="", GITHUB_OUTPUT=str(output), GITHUB_PATH=str(paths))
        for expected in ("false", "true"):
            output.write_text("")
            paths.write_text("")
            result = subprocess.run(["bash", str(ROOT / "setup-cargo-tool/run.sh")],
                                    env=env, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(output.read_text().strip(), f"s3-cache-hit={expected}")
            exported = paths.read_text().splitlines()
            self.assertEqual(len(exported), 2)
            self.assertTrue((Path(exported[0]) / "zig").is_file())
            self.assertTrue((Path(exported[1]) / "cargo-zigbuild").is_file())


if __name__ == "__main__":
    unittest.main(verbosity=2)
