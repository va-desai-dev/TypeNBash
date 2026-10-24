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

helper = script("SSH/SSHRemoteHelper.swift", "static let script")
scripts = {name: script("SSH/SSHWorkspaceFileSystem.swift", f"static let {name}Script")
           for name in ["list", "read", "write", "createFile", "mkdir"]}
scripts["search"] = script("Projects/ProjectSearchFileAccess.swift", "static let remoteScript")
scripts["editorGitBaseline"] = script("SourceControl/RemoteGit+EditorBaseline.swift", "editorBaselineScript")
# Test-only: echoes its arguments and stdin after a delay, to force reply order.
scripts["slow"] = "import sys, time\ntime.sleep(float(sys.argv[1]))\nprint(sys.argv[2] + sys.stdin.read())\n"


class Helper:
    def __init__(self):
        self.process = subprocess.Popen([sys.executable, "-c", helper], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
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
    print("PASS: list with mtime, bounded read, atomic write, mkdir/create errors, search and baseline scripts")

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
