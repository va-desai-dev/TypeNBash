# Native editor integration checks

These checks mount the production SwiftUI/AppKit bridge in a temporary macOS
window and use the app's bundled syntax definitions. They cover completions
(including acceptance), comment and indent shortcuts, quote pairing, CRLF,
line movement and undo, settings propagation, grammar changes, binding updates,
symbol parsing, find/replace, and dark-mode ruler rendering.

Build the Debug app, then run the harness with the same DerivedData and
SourcePackages directories:

```sh
xcodebuild -project CENTCOM.xcodeproj -scheme CENTCOM -configuration Debug \
  -derivedDataPath /tmp/centcom-editor-build CODE_SIGNING_ALLOWED=NO build
python3 Tests/run-editor-checks.py /tmp/centcom-editor-build \
  /tmp/centcom-editor-build/SourcePackages
```

Requires Xcode and a logged-in macOS GUI session. The runner links the built
`CENTCOM.debug.dylib`; it does not launch CENTCOM's workspace or terminal UI.
The temporary test app has its own preferences domain. The shared Find pasteboard
is restored when the checks finish successfully. Test-app files and rendered
previews are written under `/tmp`.

The full-pane bitmap and separate ruler bitmap are useful for visual inspection:
`/tmp/centcom-editor-preview.png` and `/tmp/centcom-editor-ruler.png`. AppKit's
full-view bitmap capture can omit the ruler's separately rendered layer.

# Terminal and workspace runtime checks

Build the current app target, then run:

```sh
xcodebuild -project TypeNBash.xcodeproj -scheme TypeNBash -configuration Debug \
  -derivedDataPath /tmp/centcom-projects-build CODE_SIGNING_ALLOWED=NO build
python3 Tests/run-runtime-checks.py /tmp/centcom-projects-build \
  /tmp/centcom-projects-build/SourcePackages
```

These checks link the production app module and exercise workspace generation
isolation, failed connection retention, local restoration, repeated directory
reports preserving drafts, OSC 7 decoding, and telemetry resets on host changes. Real PTYs exercise generated local
zsh and remote bash/zsh startup, prompt arrays, unusual directory names, the SSH
profile guard, unsupported-shell fallback, and normal exit status. All fixtures
live in temporary directories; no saved profiles, credentials, or remote hosts are used.

The runtime checks also cover local/SSH project identity and persistence, missing
connections, project root boundaries, failed-open retention, shell restart, and
invalid folders leaving saved projects unchanged. The production remote listing
script is tested against hidden folders, directory symlinks, and special characters.
The runner reads the deployment target from the built app.
Local picker checks cover the shared in-app browser, hidden folders, directory
symlinks, selection without changing the workspace, and invalid paths.

Live SSH acceptance: open Projects while connected, browse Home/Up and hidden
folders, select a folder, and verify the browser and terminal start there. Reopen
that saved project after disconnecting. Repeat with a saved key connection and a
password supplied in Projects. Cancel browsing and try an inaccessible folder;
the previous workspace should remain active. These checks need a reachable SSH
host and are not covered by the local harness.
