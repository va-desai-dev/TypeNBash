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

# SwiftGitX source control checks

After building TypeNBash, pass the source-control suite to the runtime runner:

```sh
python3 Tests/run-runtime-checks.py /tmp/centcom-sgx-build \
  /path/to/SourcePackages SourceControlIntegrationChecks.swift
```

The suite exercises the production service in temporary repositories: discovery
from a subfolder, no implicit repository creation, an initial commit, special
characters in paths, partially staged files, unstaging without changing file
contents, staged deletions, fetching a local bare remote, and linked worktrees.
It does not access GitHub, use credentials, or modify the workspace repository.

Manual UI check: open a local project and click Source Control in the toolbar.
Refresh, stage a saved file, enter a message, and commit staged changes. Verify
that opening a non-repository displays an explanation and that the toolbar
button is disabled for SSH workspaces. Unstage is available after the
repository's first commit. Push/pull are not part of this integration.

# GitHub authentication checks

```sh
python3 Tests/run-runtime-checks.py /tmp/centcom-sgx-build \
  /path/to/SourcePackages GitHubAuthenticationChecks.swift
```

This suite requires access to the macOS Keychain. It uses a unique test service
and fake credentials, removes that item afterward, and intercepts all API
requests with URLProtocol. It checks successful validation, rejected and malformed
responses, preservation of an existing credential after failed replacement,
Keychain restoration/replacement/deletion, exact HTTPS host restrictions, and
credential retry limits. Device-flow checks validate the client ID and request
parameters, pending/slow-down polling, denial, expiration, disabled registration,
cancellation, token rotation, and concurrent refresh coalescing. No GitHub
account or real network access is used.

Live acceptance: enable Device Flow on the registered OAuth app, open Source
Control, and choose Sign in with GitHub. Copy the displayed code into the browser
page and approve `repo read:user` access. Verify Cancel stops polling, declining
produces a useful error, the login appears after approval, reopening restores it,
and Fetch works for a private `https://github.com/OWNER/REPO.git` remote. Existing
saved tokens remain usable; disconnect first to test browser sign-in.

Access and refresh tokens, plus their expiration dates, are stored in Keychain.
Fetch refreshes expiring authorization before use. Disconnect removes credentials
from this Mac; revoke app authorization on GitHub to invalidate the tokens.
The OAuth client ID is public app configuration; no client secret is embedded.
Token transport does not support GitHub Enterprise or SSH URLs, and API validation
does not guarantee access to every repository or organization. The transport
retains certificate verification, rejects redirects, and provides credentials
only for HTTPS on github.com. Tokens are never saved to Git config, UserDefaults,
logs, or command-line arguments.
