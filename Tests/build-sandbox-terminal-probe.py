#!/usr/bin/env python3
"""Build a separately signed GUI probe using the AppStoreDebug production module.
Usage: build-sandbox-terminal-probe.py DerivedData SourcePackages OutputDirectory SigningIdentity
Launch the resulting .app via Launch Services, then select its generated workspace.
"""
import pathlib
import platform
import plistlib
import shutil
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parent
build = pathlib.Path(sys.argv[1]).resolve() / "Build"
packages = pathlib.Path(sys.argv[2]).resolve()
out = pathlib.Path(sys.argv[3]).resolve()
identity = sys.argv[4]
out.mkdir(parents=True, exist_ok=False)
products = build / "Products/AppStoreDebug"
source_app = products / "TypeNBash.app"
app = out / "SandboxTerminalProbe.app"
macos = app / "Contents/MacOS"
resources = app / "Contents/Resources"
macos.mkdir(parents=True)
resources.mkdir()
fixture = out / "workspace # café"
fixture.mkdir()
(out / "outside").mkdir()
(out / "outside/control.txt").write_text("unselected fixture\n")
(fixture / "outside-link").symlink_to(out / "outside", target_is_directory=True)
(fixture / "input.txt").write_text("selected fixture\n")
(fixture / "hello.sh").write_text("#!/bin/sh\nprintf 'script ran\\n'\n")
(fixture / "hello.sh").chmod(0o755)
(fixture / "hello.c").write_text('#include <stdio.h>\nint main(void) { puts("binary ran"); return 0; }\n')
subprocess.run(["xcrun", "clang", str(fixture / "hello.c"), "-o", str(fixture / "hello")], check=True)
subprocess.run(["git", "init", "-b", "main", str(fixture)], check=True, stdout=subprocess.DEVNULL)
shutil.copy(root / "sandbox-terminal-commands.zsh", resources / "commands.zsh")
with (source_app / "Contents/Info.plist").open("rb") as file:
    deployment = plistlib.load(file)["LSMinimumSystemVersion"]
with (app / "Contents/Info.plist").open("wb") as file:
    plistlib.dump({"CFBundleIdentifier": "VD.TypeNBash.SandboxTerminalProbe", "CFBundleExecutable": "SandboxTerminalProbe",
                  "CFBundleName": "SandboxTerminalProbe", "CFBundlePackageType": "APPL", "CFBundleVersion": "1",
                  "LSMinimumSystemVersion": deployment, "NSHighResolutionCapable": True,
                  "ProbeWorkspacePath": str(fixture)}, file)
dylib = macos / "TypeNBash.debug.dylib"
shutil.copy(source_app / "Contents/MacOS/TypeNBash.debug.dylib", dylib)
frameworks = source_app / "Contents/Frameworks"
if frameworks.exists():
    shutil.copytree(frameworks, app / "Contents/Frameworks")
maps = list((build / "Intermediates.noindex/GeneratedModuleMaps").glob("*.modulemap"))
maps.append(packages / "checkouts/Yams/Sources/CYaml/include/module.modulemap")
command = ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5", "-target",
           f"{platform.machine()}-apple-macos{deployment}", "-module-cache-path", str(out / "ModuleCache"),
           "-I", str(products), "-Xcc", "-I" + str(packages / "checkouts/libgit2/include")]
for module in maps:
    command += ["-Xcc", "-fmodule-map-file=" + str(module)]
command += [str(root / "SandboxTerminalProbe.swift"), str(dylib), "-Xlinker", "-rpath", "-Xlinker", "@executable_path",
            "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks", "-o", str(macos / "SandboxTerminalProbe")]
subprocess.run(command, check=True)
entitlements = out / "probe.entitlements"
with entitlements.open("wb") as file:
    plistlib.dump({"com.apple.security.app-sandbox": True, "com.apple.security.network.client": True,
                  "com.apple.security.files.user-selected.read-write": True,
                  "com.apple.security.files.bookmarks.app-scope": True}, file)
# Nested code already carries the production build's signatures; sign our copied
# debug library and the probe executable with the same local development identity.
subprocess.run(["codesign", "--force", "--sign", identity, "--options", "runtime", "--timestamp=none", str(dylib)], check=True)
subprocess.run(["codesign", "--force", "--sign", identity, "--options", "runtime", "--timestamp=none",
                "--generate-entitlement-der", "--entitlements", str(entitlements), str(app)], check=True)
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
print(app)
print(fixture)
