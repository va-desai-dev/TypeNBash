#!/usr/bin/env python3
"""Exercise the exact SSH baseline script locally, using disposable Git repositories."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import textwrap

source = (Path(__file__).resolve().parents[1] / "TypeNBash/SourceControl/RemoteGit+EditorBaseline.swift").read_text()
script = textwrap.dedent(re.search(r'editorBaselineScript = #"""(.*?)"""#', source, re.S).group(1))

with tempfile.TemporaryDirectory(prefix="centcom-ssh-baseline-") as temporary:
    root = Path(temporary)
    def git(*args):
        return subprocess.check_output(["git", "-C", str(root), *args], stderr=subprocess.DEVNULL)
    def baseline(path, env=None):
        return json.loads(subprocess.check_output([sys.executable, "-c", script, str(path)], env=env))

    file = root / "plain.swift"
    assert baseline(file) is None
    git("init", "-b", "main")
    git("config", "user.name", "Fixture")
    git("config", "user.email", "fixture@example.invalid")
    assert baseline(file) == ""
    nested = root / "nested ' café\nfolder"
    nested.mkdir()
    special = nested / ":literal [x] $(touch nope) ' café\n.swift"
    original = "first\r\nold 👩🏽‍💻\r\nlast\r\n"
    special.write_bytes(original.encode())
    (root / "binary").write_bytes(b"a\0b")
    (root / "large").write_bytes(b"x" * (2 * 1024 * 1024 + 1))
    (root / "invalid").write_bytes(b"\xff")
    (root / "empty").write_bytes(b"")
    (root / "link").symlink_to(special)
    git("add", ".")
    git("commit", "-m", "Fixture")
    assert baseline(special) == original
    assert baseline(file) == ""
    assert baseline(root / "empty") == ""
    assert baseline(root / "binary") is None
    assert baseline(root / "large") is None
    assert baseline(root / "invalid") is None
    assert baseline(root / "link") is None
    special.write_text("staged\n")
    git("add", ".")
    special.write_text("unstaged\n")
    assert baseline(special) == original, "Uses HEAD, not the index or saved working tree"
    git("commit", "-m", "Staged update")
    assert baseline(special) == "staged\n"
    git("checkout", "--detach")
    assert baseline(special) == "staged\n"
    worktree = root / "worktree"
    git("worktree", "add", "-b", "fixture-worktree", str(worktree))
    assert baseline(worktree / special.relative_to(root)) == "staged\n"
    assert baseline(special, dict(os.environ, PATH="")) is None
    assert not (root / "nope").exists()
print("SSH baseline script passed: nested/special paths, unborn/untracked, HEAD vs index/worktree, commits, detached HEAD, linked worktrees, binary/large/invalid fallback, missing Git.")
