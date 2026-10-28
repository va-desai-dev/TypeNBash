#!/usr/bin/env python3
"""Exercise the actual SSH agent workspace script locally, without a remote account."""
import base64
import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import textwrap

source = pathlib.Path(__file__).resolve().parents[1] / "TypeNBash/AppClasses/AgentsControl/AgentRemoteWorkspaceAccess.swift"
script = textwrap.dedent(re.search(r'static let remoteScript = #"""(.*?)"""#', source.read_text(), re.S)[1])
excluded = json.dumps(sorted([".git", ".ssh", ".aws", ".env", ".DS_Store", "node_modules", ".build", "DerivedData"]))

with tempfile.TemporaryDirectory(prefix="centcom-agent-remote-") as temporary:
    parent = pathlib.Path(temporary)
    root = parent / "project # café"
    root.mkdir()
    (root / "hello.txt").write_bytes(b"hello\ngoodbye\n")
    (root / "hello.txt").chmod(0o640)
    (root / "nested").mkdir()
    (root / "nested/deep.txt").write_bytes("naïve goodbye\n".encode())
    (root / "binary").write_bytes(b"a\0b")
    (root / ".env").write_bytes(b"SECRET=1")
    (root / "id.pem").write_bytes(b"key")
    outside = parent / "project-sibling"
    outside.mkdir()
    (outside / "secret").write_bytes(b"outside")
    (outside / "linked").write_bytes(b"goodbye")
    os.link(outside / "linked", root / "hardlink-source")
    (root / "escape").symlink_to(outside, target_is_directory=True)
    (root / "file-link").symlink_to(outside / "secret")

    def run(action, path, *extra, payload=None, success=True):
        result = subprocess.run([sys.executable, "-c", script, action, str(root), path, excluded, *extra],
                                input=json.dumps(payload).encode() if payload else None, capture_output=True)
        assert (result.returncode == 0) == success, (action, path, result.stderr.decode())
        if not success:
            last = result.stderr.decode().strip().splitlines()[-1]
            assert last.startswith("ValueError: "), last
            return last
        return result.stdout

    def commit(path, after, replacing=False, revision="", directory=False, success=True):
        return run("commit", path, payload={"directory": directory, "replacing": replacing, "revision": revision,
                                            "after": base64.b64encode(after).decode()}, success=success)

    names = {entry["name"]: entry["directory"] for entry in json.loads(run("list", "."))}
    assert names == {"hello.txt": False, "nested": True, "binary": False}, names
    print("PASS: listing skips links, hard links, credentials and excluded names")

    assert run("read", "hello.txt") == b"hello\ngoodbye\n"
    for path in ["../project-sibling/secret", "/etc/passwd", ".env", "id.pem", "escape/secret", "file-link",
                 "binary", "hardlink-source", "nested/../hello.txt", "missing.txt"]:
        run("read", path, success=False)
    run("list", "escape", success=False)
    print("PASS: reads reject traversal, absolute paths, credentials, links, hard links and binary files")

    search = json.loads(run("search", ".", "goodbye", "0"))
    assert [(match["path"], match["line"]) for match in search["matches"]] == [("hello.txt", 2), ("nested/deep.txt", 1)], search
    assert search["skipped_files"] == 1 and search["scan_limited"] is False, search
    assert json.loads(run("search", ".", "goodbye", "1"))["matches"][0]["path"] == "nested/deep.txt"
    print("PASS: search walks without links, skips binaries, and honours offset")

    revision = hashlib.sha256(b"hello\ngoodbye\n").hexdigest()
    commit("hello.txt", b"hello\nagain\n", replacing=True, revision=revision)
    assert (root / "hello.txt").read_bytes() == b"hello\nagain\n"
    assert (root / "hello.txt").stat().st_mode & 0o777 == 0o640
    assert "changed after it was read" in commit("hello.txt", b"stale", replacing=True, revision=revision, success=False)
    assert (root / "hello.txt").read_bytes() == b"hello\nagain\n"
    print("PASS: revision-checked replacement preserves permissions and rejects stale edits")

    commit("nested/new.txt", "créé\n".encode())
    assert (root / "nested/new.txt").read_bytes() == "créé\n".encode()
    assert "already exists" in commit("nested/new.txt", b"again", success=False)
    commit("file-link", b"bad", success=False)
    commit("escape/new", b"bad", success=False)
    assert not (outside / "new").exists() and (outside / "secret").read_bytes() == b"outside"
    commit("folder", b"", directory=True)
    assert (root / "folder").is_dir()
    commit("folder", b"", directory=True, success=False)
    commit("big.txt", b"x" * (1_048_576 + 1), success=False)
    assert not any(name.startswith(".typenbash-agent-") for _, _, files in os.walk(root) for name in files)
    print("PASS: exclusive creation, link refusal, directories, size limit, and temporary-file cleanup")

print("All SSH agent workspace script checks passed; no SSH connection was made.")
