#!/usr/bin/env python3
"""Exercise the actual SSH search script locally, without a remote account."""
import base64
import json
import pathlib
import re
import subprocess
import sys
import tempfile
import textwrap

source = pathlib.Path(__file__).resolve().parents[1] / "TypeNBash/AppClasses/ProjectControl/ProjectSearchFileAccess.swift"
script = textwrap.dedent(re.search(r'static let remoteScript = #"""(.*?)"""#', source.read_text(), re.S)[1])
with tempfile.TemporaryDirectory(prefix="centcom-search-files-") as temporary:
    parent = pathlib.Path(temporary)
    root = parent / "project # café"
    root.mkdir()
    file = root / "quote ' newline\n.txt"
    file.write_bytes(b"old\r\ntext\r\n")
    file.chmod(0o640)
    outside = parent / "project-sibling"
    outside.mkdir()
    (outside / "secret").write_bytes(b"outside")
    (root / "escape").symlink_to(outside, target_is_directory=True)
    (root / "cycle").symlink_to(root, target_is_directory=True)

    def run(action, path, limit=100, payload=None, success=True, base=root):
        result = subprocess.run([sys.executable, "-c", script, action, str(base), str(path), str(limit)],
                                input=json.dumps(payload).encode() if payload else None, capture_output=True)
        assert (result.returncode == 0) == success, result.stderr.decode()
        return result.stdout

    listing = json.loads(run("list", root))
    assert [entry["name"] for entry in listing] == [file.name]
    assert run("read", file) == b"old\r\ntext\r\n"
    run("read", file, 2, success=False)
    run("read", root / "escape/secret", success=False)
    run("list", root / "cycle", success=False)
    run("read", outside / "secret", success=False)
    print("PASS: remote listing skips links, exact bounded reads, unusual names, root and sibling boundaries")

    def payload(expected, replacement):
        return {"expected": base64.b64encode(expected).decode(), "replacement": base64.b64encode(replacement).decode()}

    run("replace", file, payload=payload(b"stale", b"wrong"), success=False)
    assert file.read_bytes() == b"old\r\ntext\r\n"
    run("replace", file, payload=payload(file.read_bytes(), b"new\r\ntext\r\n"))
    assert file.read_bytes() == b"new\r\ntext\r\n" and file.stat().st_mode & 0o777 == 0o640
    assert len(list(root.glob(".TypeNBash-*"))) == 0
    print("PASS: remote replacement rejects stale content, preserves CRLF/permissions, and cleans temporary files")

    alias = parent / "root-alias"
    alias.symlink_to(root, target_is_directory=True)
    assert run("read", alias / file.name, base=alias) == file.read_bytes()
    print("PASS: a symlinked project root is supported without following links beneath it")
