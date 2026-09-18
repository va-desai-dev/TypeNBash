#!/usr/bin/env python3
"""State checks plus real PTY startup/cd/SSH guard/exit checks. No SSH host needed.
Usage: python3 Tests/run-runtime-checks.py <DerivedData> <SourcePackages>
"""
import errno
import json
import os
import pathlib
import platform
import plistlib
import pty
import re
import select
import shlex
import shutil
import subprocess
import sys
import tempfile
import textwrap
import time
import urllib.parse

root = pathlib.Path(__file__).resolve().parent
build = pathlib.Path(sys.argv[1]).resolve() / "Build"
packages = pathlib.Path(sys.argv[2]).resolve()
products = build / "Products/Debug"
with (products / "TypeNBash.app/Contents/Info.plist").open("rb") as info:
    deployment_target = plistlib.load(info)["LSMinimumSystemVersion"]
with tempfile.TemporaryDirectory(prefix="centcom-runtime-checks-", dir="/tmp") as temporary:
    temporary = pathlib.Path(temporary)
    executable = temporary / "RuntimeChecks"
    maps = list((build / "Intermediates.noindex/GeneratedModuleMaps").glob("*.modulemap"))
    maps += [packages / "checkouts/Yams/Sources/CYaml/include/module.modulemap"]
    command = ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5", "-target",
               f"{platform.machine()}-apple-macos{deployment_target}", "-module-cache-path", str(temporary / "ModuleCache"),
               "-I", str(products), "-Xcc", "-I" + str(packages / "checkouts/libgit2/include")]
    for module_map in maps:
        command += ["-Xcc", "-fmodule-map-file=" + str(module_map)]
    dylibs = products / "TypeNBash.app/Contents/MacOS"
    command += [str(root / (sys.argv[3] if len(sys.argv) > 3 else "RuntimeIntegrationChecks.swift")), str(dylibs / "TypeNBash.debug.dylib"),
                "-Xlinker", "-rpath", "-Xlinker", str(dylibs), "-o", str(executable)]
    subprocess.run(command, check=True)
    subprocess.run([str(executable)], check=True)
    if len(sys.argv) > 3:
        sys.exit(0)
    home = temporary / "home"
    home.mkdir()
    target = home / "folder #?% ' café"
    target.mkdir()
    # Exercise the actual remote listing script with hidden and symlinked folders.
    listing_source = (root.parent / "TypeNBash/SSH/SSHWorkspaceFileSystem.swift").read_text()
    listing_script = re.search(r'let script = #"""(.*?)"""#', listing_source, re.S).group(1)
    listing_script = textwrap.dedent(listing_script)
    (home / ".hidden").mkdir()
    (home / "linked folder").symlink_to(target, target_is_directory=True)
    (home / "ordinary file").write_text("fixture")
    visible = json.loads(subprocess.check_output([sys.executable, "-c", listing_script, str(home), "0"]))
    entries = {entry["name"]: entry for entry in visible}
    assert entries[target.name]["directory"] and entries["linked folder"]["directory"]
    assert not entries["ordinary file"]["directory"] and ".hidden" not in entries
    hidden = json.loads(subprocess.check_output([sys.executable, "-c", listing_script, str(home), "1"]))
    assert any(entry["name"] == ".hidden" and entry["directory"] for entry in hidden)
    print("Remote directory script checks passed")
    # User startup files deliberately cd away and use an array prompt hook.
    (home / ".bash_profile").write_text("cd /\nPROMPT_COMMAND=('true' 'true')\n")
    (home / ".zprofile").write_text("cd /\n")
    fixtures = json.loads(subprocess.check_output([str(executable), str(home)], text=True))
    try:
        for name, shell, launch in [
            ("remote bash", "/bin/bash", ["/bin/sh", "-c", fixtures["remote"]]),
            ("remote zsh", "/bin/zsh", ["/bin/sh", "-c", fixtures["remote"]]),
            ("fallback bash", "/bin/unsupported-shell", ["/bin/sh", "-c", fixtures["remote"]]),
            ("local zsh", "/bin/zsh", ["/bin/zsh", "-i"]),
        ]:
            pid, descriptor = pty.fork()
            if pid == 0:
                environment = dict(os.environ, HOME=str(home), SHELL=shell, TERM="xterm-256color")
                environment.pop("ZDOTDIR", None)
                if name == "local zsh":
                    environment["ZDOTDIR"] = fixtures["localRC"]
                os.chdir(home)
                os.execve(launch[0], launch, environment)
            output = bytearray()

            def wait_for(predicate, description):
                deadline = time.monotonic() + 8
                while time.monotonic() < deadline:
                    if predicate(bytes(output)):
                        return
                    if select.select([descriptor], [], [], 0.1)[0]:
                        try:
                            data = os.read(descriptor, 65536)
                        except OSError as error:
                            if error.errno == errno.EIO:
                                break
                            raise
                        if not data:
                            break
                        output.extend(data)
                raise AssertionError(f"{name}: {description}\n{bytes(output)!r}")

            def directories(data):
                return [urllib.parse.unquote(urllib.parse.urlsplit(uri.decode()).path)
                        for uri in re.findall(rb'\x1b\]7;([^\x07]+)\x07', data)]

            try:
                wait_for(lambda data: bool(directories(data)), "initial directory report")
                if name != "local zsh":
                    assert directories(output)[-1] == str(home), (name, directories(output))
                os.write(descriptor, ("cd -- " + shlex.quote(str(target)) + "\n").encode())
                wait_for(lambda data: str(target) in directories(data), "encoded cd report")
                os.write(descriptor, b"ssh unconfigured.invalid; printf 'GUARD_STATUS=%s\\n' $?\n")
                wait_for(lambda data: b"GUARD_STATUS=126" in data, "SSH guard prevents unmanaged connection")
                assert b"Connect using the SSH button" in output
                os.write(descriptor, b"exit 7\n")
                deadline = time.monotonic() + 8
                while time.monotonic() < deadline:
                    child, status = os.waitpid(pid, os.WNOHANG)
                    if child:
                        assert os.waitstatus_to_exitcode(status) == 7, (name, status)
                        pid = None
                        break
                    if select.select([descriptor], [], [], 0.05)[0]:
                        try:
                            output.extend(os.read(descriptor, 65536))
                        except OSError:
                            pass
                assert pid is None, f"{name}: exit did not terminate shell: {bytes(output)!r}"
                print(f"PASS: {name}: startup, cd, encoded paths, SSH guard, exit")
            finally:
                os.close(descriptor)
                if pid:
                    os.kill(pid, 9)
                    os.waitpid(pid, 0)
    finally:
        shutil.rmtree(fixtures["localRC"], ignore_errors=True)
print("All runtime checks passed")
