#!/usr/bin/env python3
"""Run the actual SSH filesystem helper locally over pipes, without a remote account."""
import base64
import json
import pathlib
import queue
import re
import subprocess
import sys
import tempfile
import textwrap
import threading
import time

sources = pathlib.Path(__file__).resolve().parents[1] / "TypeNBash"
def script(file, name):
    return textwrap.dedent(re.search(name + r' = #"""(.*?)"""#', (sources / file).read_text(), re.S)[1])

helper = script("AppClasses/RemoteSessionControl/SSHRemoteHelper.swift", "static let script")
scripts = {name: script("AppClasses/RemoteSessionControl/SSHWorkspaceFileSystem.swift", f"static let {name}Script")
           for name in ["list", "read", "write", "createFile", "mkdir", "remove", "move", "find"]}
scripts["search"] = script("AppClasses/ProjectControl/ProjectSearchFileAccess.swift", "static let remoteScript")
scripts["editorGitBaseline"] = script("AppClasses/GitControl/RemoteGit+EditorBaseline.swift", "editorBaselineScript")
# Test-only: echoes its arguments and stdin after a delay, to force reply order.
scripts["slow"] = "import sys, time\ntime.sleep(float(sys.argv[1]))\nprint(sys.argv[2] + sys.stdin.read())\n"


class Helper:
    def __init__(self, env=None):
        self.process = subprocess.Popen([sys.executable, "-c", helper], stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=env)
        self.lines = queue.Queue()
        self.next_id = 0
        threading.Thread(target=lambda: [self.lines.put(json.loads(line)) for line in self.process.stdout], daemon=True).start()

    def send(self, op, *args, data=None, **extra):
        self.next_id += 1
        message = dict(id=self.next_id, op=op, args=list(args), **extra)
        if data is not None:
            message["input"] = base64.b64encode(data).decode()
        self.process.stdin.write(json.dumps(message).encode() + b"\n")
        self.process.stdin.flush()
        return self.next_id

    def receive(self, timeout=10):
        return self.lines.get(timeout=timeout)

    def call(self, op, *args, data=None, **extra):
        identifier = self.send(op, *args, data=data, **extra)
        reply = self.receive()
        assert reply["id"] == identifier, reply
        return reply

    def output(self, op, *args, data=None):
        reply = self.call(op, *args, data=data)
        assert "error" not in reply, reply
        return base64.b64decode(reply["data"])


with tempfile.TemporaryDirectory(prefix="centcom-ssh-helper-") as temporary:
    root = pathlib.Path(temporary) / "project ' café\nnewline"
    root.mkdir()
    remote = Helper()
    assert remote.call("hello", version=1, scripts=scripts)["version"] == 1
    print("PASS: protocol-version handshake registers the production scripts")

    file = root / "notes.md"
    remote.output("write", str(file), data=b"first\r\nline\n")
    assert file.read_bytes() == b"first\r\nline\n" and not list(root.glob(".TypeNBash-*"))
    assert remote.output("read", str(file), "5") == b"first"
    (root / ".hidden").mkdir()
    remote.output("mkdir", str(root / "folder"))
    listing = {entry["name"]: entry for entry in json.loads(remote.output("list", str(root), "0"))}
    assert set(listing) == {"notes.md", "folder"} and listing["folder"]["directory"]
    assert listing["notes.md"]["size"] == 12 and abs(listing["notes.md"]["mtime"] - file.stat().st_mtime) < 1
    assert ".hidden" in {entry["name"] for entry in json.loads(remote.output("list", str(root), "1"))}
    assert "FileExistsError" in remote.call("createFile", str(file), data=b"x")["error"]
    assert "FileExistsError" in remote.call("mkdir", str(root / "folder"))["error"]
    assert file.read_bytes() == b"first\r\nline\n"
    assert remote.output("search", "read", str(root), str(file), "100") == file.read_bytes()
    assert "ValueError" in remote.call("search", "read", str(root), str(root.parent), "100")["error"]
    assert json.loads(remote.output("editorGitBaseline", str(file))) is None
    (root / "folder" / "Nested Notes.MD").write_text("x")
    (root / ".hidden" / "notes-secret").write_text("x")
    found = {entry["name"]: entry for entry in json.loads(remote.output("find", str(root), "notes", "0", "10"))}
    assert set(found) == {"notes.md", "folder/Nested Notes.MD"} and not found["notes.md"]["directory"], found
    hidden = json.loads(remote.output("find", str(root), "NOTES", "1", "10"))
    assert ".hidden/notes-secret" in {entry["name"] for entry in hidden}
    assert len(json.loads(remote.output("find", str(root), "notes", "1", "2"))) == 2
    assert json.loads(remote.output("find", str(root), "folder", "0", "10"))[0]["directory"]
    print("PASS: list with mtime, bounded read, atomic write, mkdir/create errors, search, find, and baseline scripts")

    doomed = root / "doomed.txt"
    doomed.write_text("x")
    remote.output("remove", str(doomed))
    assert not doomed.exists()
    tree = root / "doomed folder"
    (tree / "inner").mkdir(parents=True)
    (tree / "inner" / "file.txt").write_text("x")
    remote.output("remove", str(tree))
    assert not tree.exists()
    # A link goes; what it points to stays.
    kept = pathlib.Path(temporary) / "kept outside"
    kept.mkdir()
    (kept / "keep.txt").write_text("x")
    (root / "link").symlink_to(kept, target_is_directory=True)
    remote.output("remove", str(root / "link"))
    assert not (root / "link").is_symlink() and (kept / "keep.txt").exists()
    assert "FileNotFoundError" in remote.call("remove", str(root / "missing"))["error"]
    # The home refusal runs with HOME pointed at a throwaway folder, so a
    # broken guard could only ever delete that.
    fake_home = pathlib.Path(temporary) / "fake home"
    fake_home.mkdir()
    (fake_home / "keep.txt").write_text("x")
    guarded = Helper(env={**__import__("os").environ, "HOME": str(fake_home)})
    assert guarded.call("hello", version=1, scripts=scripts)["version"] == 1
    assert "PermissionError" in guarded.call("remove", "~")["error"]
    assert "PermissionError" in guarded.call("remove", str(fake_home))["error"]
    assert (fake_home / "keep.txt").exists()
    guarded.process.stdin.close()
    guarded.process.wait(timeout=10)
    print("PASS: remove deletes files and folders, unlinks links without following them, and refuses the home folder")

    before = root / "before.txt"
    before.write_text("before")
    remote.output("move", str(before), str(root / "after.txt"))
    assert not before.exists() and (root / "after.txt").read_text() == "before"
    (root / "taken.txt").write_text("taken")
    assert "FileExistsError" in remote.call("move", str(root / "after.txt"), str(root / "taken.txt"))["error"]
    assert (root / "taken.txt").read_text() == "taken" and (root / "after.txt").exists()
    # A case-only rename is the same item, even where the disk ignores case.
    remote.output("move", str(root / "after.txt"), str(root / "AFTER.txt"))
    assert "AFTER.txt" in {path.name for path in root.iterdir()}
    (root / "old folder" / "inner").mkdir(parents=True)
    remote.output("move", str(root / "old folder"), str(root / "new folder"))
    assert (root / "new folder" / "inner").is_dir() and not (root / "old folder").exists()
    print("PASS: move renames files and folders, refuses to replace an existing item, and allows case-only renames")

    slow = remote.send("slow", "1.0", "slow:", data=b"payload")
    fast = remote.send("list", str(root), "0")
    echoes = {remote.send("slow", "0.3", f"echo{index}:", data=str(index).encode()): index for index in range(8)}
    big = root / "big.bin"
    big.write_bytes(bytes(range(256)) * 40_000)
    large = remote.send("read", str(big), str(20_000_000))
    replies = [remote.receive() for _ in range(11)]
    order = [reply["id"] for reply in replies]
    assert order.index(fast) < order.index(slow) and order[-1] == slow, order
    by_id = {reply["id"]: reply for reply in replies}
    for identifier, index in echoes.items():
        assert base64.b64decode(by_id[identifier]["data"]) == f"echo{index}:{index}\n".encode()
    assert base64.b64decode(by_id[large]["data"]) == big.read_bytes()
    assert base64.b64decode(by_id[slow]["data"]) == b"slow:payload\n"
    print("PASS: replies arrive out of order; concurrent scripts keep their own argv, stdin and stdout")

    watched, other = root / "folder", root / "other"
    other.mkdir()
    remote.send("watch", str(watched), str(other))
    assert remote.receive()["id"] == remote.next_id
    (watched / "new.txt").write_text("x")
    event = remote.receive(timeout=5)
    assert event == {"event": "changed", "path": str(watched)}, event
    remote.send("watch", str(other))
    remote.receive()
    (watched / "ignored.txt").write_text("x")
    other.rmdir()
    assert remote.receive(timeout=5) == {"event": "changed", "path": str(other)}
    try:
        unexpected = remote.receive(timeout=3.5)
        raise AssertionError(f"Unwatched or unchanged folder reported: {unexpected}")
    except queue.Empty:
        pass
    print("PASS: watched folders push changed events; unwatched folders stay quiet")

    remote.send("slow", "60", "never")
    remote.process.stdin.close()
    started = time.monotonic()
    assert remote.process.wait(timeout=5) == 0 and time.monotonic() - started < 5
    print("PASS: helper exits when stdin closes, even with a request still running")
