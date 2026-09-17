#!/usr/bin/env python3
"""Run native editor checks against an existing Debug Xcode build.

Usage: python3 Tests/run-editor-checks.py <DerivedData> <SourcePackages>
Requires a logged-in macOS GUI session. Opens a temporary fixture window;
never reads or writes workspace documents. Build CENTCOM with
CODE_SIGNING_ALLOWED=NO first. Writes its test app and preview to /tmp.
"""
import pathlib
import plistlib
import platform
import subprocess
import sys
import tempfile

root = pathlib.Path(__file__).resolve().parent
build = pathlib.Path(sys.argv[1]).resolve() / "Build"
packages = pathlib.Path(sys.argv[2]).resolve()
products = build / "Products/Debug"
app = pathlib.Path(tempfile.mkdtemp(prefix="centcom-editor-checks-", dir="/tmp")) / "EditorChecks.app"
macos = app / "Contents/MacOS"
macos.mkdir(parents=True)
(app / "Contents/Resources").symlink_to(products / "CENTCOM.app/Contents/Resources")
with (app / "Contents/Info.plist").open("wb") as output:
    plistlib.dump({"CFBundleExecutable": "EditorChecks", "CFBundleIdentifier": "test.CENTCOM.EditorChecks",
                  "CFBundleName": "Editor Checks", "CFBundlePackageType": "APPL"}, output)

maps = list((build / "Intermediates.noindex/GeneratedModuleMaps").glob("*.modulemap"))
maps += [packages / "checkouts/Yams/Sources/CYaml/include/module.modulemap"]
command = ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5", "-target", f"{platform.machine()}-apple-macos26.0",
           "-module-cache-path", str(app.parent / "ModuleCache"), "-I", str(products)]
for module_map in maps:
    command += ["-Xcc", "-fmodule-map-file=" + str(module_map)]
dylib_directory = products / "CENTCOM.app/Contents/MacOS"
command += [str(root / "EditorIntegrationChecks.swift"), str(dylib_directory / "CENTCOM.debug.dylib"),
            "-Xlinker", "-rpath", "-Xlinker", str(dylib_directory), "-o", str(macos / "EditorChecks")]
subprocess.run(command, check=True)
subprocess.run([str(macos / "EditorChecks")], check=True)
