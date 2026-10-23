# Project search checks

```sh
python3 Tests/run-editor-checks.py /path/to/DerivedData \
  /path/to/SourcePackages ProjectSearchIntegrationChecks.swift
python3 Tests/run-project-search-file-checks.py
```

The native harness checks recursive project scope, include/exclude globs, binary
and size limits, symlink loops, CRLF/UTF-16 result navigation, shared find-field
focus and typing, unsaved buffers,
single/file replacements, native Undo, stale-file rejection, regex capture and
zero-width replacements, advanced text options, query cancellation, and project
teardown. It writes `/tmp/centcom-project-search.png` for visual inspection.
The Python check executes the actual SSH search script against local fixtures,
covering unusual paths, root escape attempts, full reads, stale writes, permissions,
and temporary-file cleanup. It does not require or establish an SSH connection.

# Find-bar keyboard focus checks

```sh
python3 Tests/run-editor-checks.py /tmp/centcom-agents-build \
  /tmp/centcom-agents-build/SourcePackages FindFocusIntegrationChecks.swift
```

Types `Bar`, waits for incremental matching, then finishes `Barrett` in the real
inline find field against a long document. Verifies the document is unchanged,
Next/Previous preserve field focus, Replace-and-Find preserves an independently
focused native replacement field, and dismissing Find returns focus to the editor.
Restores the shared Find pasteboard after the check.

# Browser focus and navigation checks

```sh
python3 Tests/run-editor-checks.py /tmp/centcom-agents-build \
  /tmp/centcom-agents-build/SourcePackages BrowserIntegrationChecks.swift
```

Uses a synthetic WebKit page in a native window to check address parsing, repeated
Command-L selection without selecting webpage text, address drafts, Escape,
Return, new-window links, and closing/reopening tabs. Requires a logged-in macOS
GUI session. Live authentication providers and popup `window.opener` callbacks
are not covered; the browser provides an explicit default-browser handoff.

# Native Word preview checks

After a Debug build, run:

```sh
python3 Tests/run-editor-checks.py /tmp/centcom-agents-build \
  /tmp/centcom-agents-build/SourcePackages WordPreviewChecks.swift
```

Checks `.docx` routing through the workspace filesystem, the 25 MB whole-file
limit even when file size is unknown, read-only save behavior, private temporary
snapshot permissions and cleanup, and mounting the native Quick Look view.
Requires a logged-in macOS GUI session. Writes a view capture to
`/tmp/centcom-docx-preview.png`; remote Quick Look layers may not appear in that
capture. Complex Word layout fidelity remains dependent on macOS Quick Look.

# Source citation highlighting checks

```sh
python3 Tests/run-editor-checks.py /tmp/centcom-agents-build \
  /tmp/centcom-agents-build/SourcePackages EditorCitationChecks.swift
```

Checks bracketed citation groups, UTF-16 ranges, case-sensitive keys, code and
link exclusions, switching/reloading the active bibliography, syntax recoloring,
typing and undo, and clearing colors when no library is loaded. Produces
`/tmp/centcom-citation-highlights.png` from the mounted source editor.

# Bibliography inspector checks

```sh
python3 Tests/run-runtime-checks.py /tmp/centcom-agents-build \
  /tmp/centcom-agents-build/SourcePackages BibliographyInspectorChecks.swift
```

Checks Markdown-only eligibility, author/title/journal search, ordered Pandoc
citations with duplicate keys, and selection reset. Renders long filenames,
titles, and keys at 260 and 300 points in the app's dark scheme; screenshots are
saved to `/tmp/centcom-bibliography-260-dark.png` and
`/tmp/centcom-bibliography-300-dark.png` for visual inspection.

# Writing statistics checks

After a Debug build, run:

```sh
python3 Tests/run-runtime-checks.py /tmp/centcom-agents-build \
  /tmp/centcom-agents-build/SourcePackages WritingStatisticsChecks.swift
```

Checks empty documents, soft breaks and blank paragraphs, Markdown formatting and
link destinations, Unicode, 250-word page boundaries, supported extensions,
clearing stale previews on file switches, unsaved edits, silent five-second refresh
during continuous typing, and sampling cancellation. The Writing inspector
supports `.md` and `.txt`; pages are estimates rounded up at 250 words per page.

# Native editor integration checks

These checks mount the production SwiftUI/AppKit bridge in a temporary macOS
window and use the app's bundled syntax definitions. They cover completions
(including acceptance), comment and indent shortcuts, quote pairing, CRLF,
line movement and undo, settings propagation, grammar changes, binding updates,
symbol parsing, find/replace, and dark-mode ruler rendering.

Build the Debug app, then run the harness with the same DerivedData and
SourcePackages directories:

```sh
xcodebuild -project TypeNBash.xcodeproj -scheme TypeNBash -configuration Debug \
  -derivedDataPath /tmp/centcom-editor-build CODE_SIGNING_ALLOWED=NO build
python3 Tests/run-editor-checks.py /tmp/centcom-editor-build \
  /tmp/centcom-editor-build/SourcePackages
```

Requires Xcode and a logged-in macOS GUI session. The runner links the built
`TypeNBash.debug.dylib`; it does not launch CENTCOM's workspace or terminal UI.
The temporary test app has its own preferences domain. The shared Find pasteboard
is restored when the checks finish successfully. Test-app files and rendered
previews are written under `/tmp`.

The full-pane bitmap and separate ruler bitmap are useful for visual inspection:
`/tmp/centcom-editor-preview.png` and `/tmp/centcom-editor-ruler.png`. AppKit's
full-view bitmap capture can omit the ruler's separately rendered layer.

The editor includes an optional change strip beside its line numbers (Editor
Options → Show Changes). Green marks additions, blue marks modified lines, and
red notches mark deletions. It compares the live buffer with Git HEAD on the
file's local or SSH host, including staged and unsaved edits. When Git content
is unavailable, it compares with the last loaded/saved text. Local Git refreshes
on editing, saving, app activation, and commits made through Source Control.
SSH caches the baseline for live editing and refreshes it on opening, saving,
browser refresh, app activation, Source Control commits, and terminal prompts.
Comparisons are
debounced and limited to 2 MB. The strip stays visible when line numbers are hidden.

```sh
python3 Tests/run-runtime-checks.py /tmp/centcom-editor-build \
  /tmp/centcom-editor-build/SourcePackages EditorChangeIntegrationChecks.swift
```

The change suite covers insertion/replacement/deletion boundaries, empty files,
CRLF and Unicode, HEAD versus staged/unsaved content, commits, untracked files,
saved-text fallback, and save snapshot isolation. Native editor checks also verify
visible marker colors, wrapped-line coverage, and the compact numberless gutter.

```sh
python3 Tests/run-ssh-editor-baseline-checks.py
python3 Tests/run-runtime-checks.py /tmp/centcom-editor-build \
  /tmp/centcom-editor-build/SourcePackages SSHEditorChangeIntegrationChecks.swift
```

SSH checks execute the production remote script locally against temporary Git
repositories and exercise the editor model with a controlled remote filesystem.
They cover nested/special filenames, staged versus HEAD content, unborn and
untracked files, commits, detached HEAD, linked worktrees, unavailable Git,
binary/oversized content, cached comparisons, disconnected fallback, and late
responses after switching hosts. They do not establish a live SSH connection.
Live acceptance: open a modified file in an SSH project, edit and save, then
commit from its console; the strip should include saved and unsaved changes and
clear committed changes after the prompt returns without replacing the draft.

Markdown saving uses the same loaded/saved snapshot and filesystem write path as
code files. Run the mounted editor/header save checks with:

```sh
python3 Tests/run-editor-checks.py /tmp/centcom-editor-build \
  /tmp/centcom-editor-build/SourcePackages RemoteFileSaveIntegrationChecks.swift
```

These exercise typing and Command-S in the production Markdown editor and Save
header, local persistence, a remote filesystem fixture, code-file regression,
failed-save retry, edits during a save, and truncated-file protection. The remote
fixture verifies the write dispatch without establishing a live SSH connection.

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
Push checks verify initial publication, explicit branch selection even with a
broad forced refspec in Git config, detached HEAD refusal, and rejection of a
diverged remote without overwriting its history.
An existing repository created by command-line Git also exercises commit failure
and retry. Missing identity opens Commit Identity and blocks committing until a
name and email are saved in repository-local Git config. Tests check validation,
reopening the repository, author/committer fields, and preserving the pending
message and staging. A locked branch displays the underlying Git error and leaves
HEAD unchanged; retry commits only staged contents with the correct parent,
preserving additional unstaged edits. No global identity is written or inferred
from the repository's previous authors or GitHub sign-in.

App-default checks use an isolated UserDefaults suite: remembering an identity
from the repository form, persistence across settings instances, normalization,
invalid-input rejection, and clearing the default. Fresh repositories reuse the
saved default without prompting. Existing Git config values take precedence per
field; missing fields are copied to repository config only when committing.
Refresh leaves config unchanged. Clearing the app default leaves identities
already saved in repositories intact. Author and committer fields are verified
for missing, partial, and complete repository identities.

Run the same suite against the compiled App Store configuration with:

```sh
python3 Tests/run-runtime-checks.py /tmp/centcom-byok-store-final \
  /tmp/centcom-byok-packages SourceControlIntegrationChecks.swift AppStoreDebug
```

These tests load the built module outside the app sandbox. Signed sandbox
acceptance: open an existing repo via the native folder panel, enter Commit
Identity when global config is unavailable, save it, then commit staged changes.
The author's name/email must match the entries; the home global config must stay
unchanged. No additional home-directory grant or Git subprocess is needed.
In Settings → Source Control, save a Default Commit Identity, then open another
repository without an identity. Commit without re-entering it and verify the
author. Repeat after restarting the app. Verify the repository form's “Remember
as app default” toggle and that SSH repositories still use host configuration.
It does not access GitHub, use credentials, or modify the workspace repository.

Manual UI check: open a local project and click Source Control in the toolbar.
Refresh, stage a saved file, enter a message, and commit staged changes. Verify
that opening a non-repository displays an explanation and that the toolbar
button is disabled for SSH workspaces. Unstage is available after the
repository's first commit. Push sends only the current branch to the selected
remote under the same branch name, without force, and reports remote rejection.
It does not change upstream configuration. Pull/merge are not part of this integration.

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
and Fetch works for a private `https://github.com/OWNER/REPO.git` remote.
Commit locally, then Push to verify authenticated publication. Repository write
permission is required; protected branches may require a pull request instead.
Committing alone never publishes changes. Existing
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

# Unified diff viewer

```sh
python3 Tests/run-runtime-checks.py /tmp/centcom-sgx-build \
  /path/to/SourcePackages GitDiffIntegrationChecks.swift
```

Checks cover unborn repositories and untracked files, stacked removals before additions and
old/new line numbers, staged versus unstaged content, deletions, binary and large-file
fallbacks, renames, and clean repositories. All changes occur in temporary fixtures.
Set `CENTCOM_DIFF_PREVIEW=1` to also render a temporary native window and write
`/tmp/centcom-diff-preview.png` for visual inspection.

Click the toolbar's two-arrow Changes button in a local workspace. Select a file,
switch All Changes / Unstaged / Staged, and scroll the single comparison pane.
Removed lines precede additions within each changed block. Deleted files have
a struck-through filename and display their previous contents as removed lines. The viewer shows read-only saved-file patches with three
context lines. Unsaved editor buffers are not included. Files larger than 2 MB
receive a fallback message; text previews are capped at 20,000 rows and long lines
at 10,000 bytes. Refresh reloads external filesystem or Git changes.

# CSV editing checks

After building TypeNBash, run the native grid and preview-header checks:

```sh
python3 Tests/run-runtime-checks.py /tmp/centcom-browser-build \
  /path/to/SourcePackages CSVIntegrationChecks.swift
```

This opens a temporary preview window and CSV fixture. It verifies double-click
editing, pending-edit Save availability, Command-S through the actual header,
Escape cancellation, Tab commit/navigation, and serialization of quotes,
delimiters, line breaks, and empty cells. Requires a logged-in macOS GUI session.

# Startup routing checks

```sh
python3 Tests/run-runtime-checks.py /tmp/centcom-browser-build \
  /path/to/SourcePackages AppRouterIntegrationChecks.swift
```

Exercises local launch, inline-setup cancellation and completion, saved-project
session handoff, failed-open retention, cancellation before activation, and
independent workspace-window ownership. Uses
temporary folders and an isolated preferences domain, with no live SSH host.
Manual acceptance: launch to Welcome, select a recent project or choose Home;
verify SSH and New Project stay on Welcome when cancelled and open the configured
workspace after success. Live SSH authentication still requires a reachable host.

Welcome-window acceptance: verify Welcome is fixed-size with system chrome, then
open Home and verify a separate resizable workspace appears. Press Command-N to
reopen Welcome; opening another workspace must keep the first session alive.
Closing either workspace must leave the other usable.

Welcome filtering: the picker has only Local and SSH. Local lists local projects;
SSH lists remote projects, including projects with a missing saved connection so
opening them can report the existing error. Clicking a project opens it directly.
The footer consistently offers New Project and Open Home.

SSH welcome acceptance: New Connection beside the Projects heading opens a blank
connection form. Open Home opens that form with a saved host preselected, when
available; its Connection picker offers saved hosts or New Connection. Cancel
returns to the SSH tab. Successful authentication opens a free workspace;
failed authentication keeps the form and its error visible.

Project welcome acceptance: New Project in the footer replaces the dashboard
with the project form at the same window size, without a project sheet or duplicate
saved-project list. Cancel restores the dashboard. Opening a valid folder opens
the workspace; an invalid folder leaves its error in the form. Saved-project
selection on the dashboard continues to open directly.
The Local tab starts project setup on This Mac. SSH preselects a saved host;
with no saved hosts, it first connects and then continues to project setup.

# Project workspace isolation and console layout

After building, run the native window harness:

```sh
python3 Tests/run-runtime-checks.py /tmp/centcom-browser-build \
  /path/to/SourcePackages ProjectWorkspaceIntegrationChecks.swift
```

This mounts the production workspace in a temporary window and checks that a
project owns exactly one console, the footer occupies the actual divider gap,
status labels and blank areas hit the native divider, dragging the footer resizes
it, the native console button receives separate clicks, repeated hide/show keeps
the shell alive and restores its height, editor changes retain the shell PID and divider position, window resizing keeps valid terminal geometry without restarting the
shell, and leaving project mode tears down the project console and vertical
split. It uses an isolated preferences domain and temporary project folder.
The runtime suite also checks that project console directory reports and local
shell restarts preserve unsaved drafts.

Manual acceptance: open a project, drag the console divider, select several files,
open and close Changes, and toggle the inspector. The console should stay mounted
at the chosen height and retain its running command. Home and unscoped SSH keep
the terminal/editor picker. For performance comparisons, capture the same resize
sequence in Instruments before and after; these checks validate lifecycle and
geometry, not frame timing or peak memory.

# Portable project definitions

```sh
python3 Tests/run-runtime-checks.py /tmp/centcom-browser-build \
  /path/to/SourcePackages ProjectManifestIntegrationChecks.swift
```

Checks new directory creation, initializing existing folders, ordinary folders
remaining unmodified, refusing collisions and definition overwrites, copying and
reopening definitions at a new location, version/JSON/path validation, output
folder preparation, symlink boundary checks, and recent-list persistence. Fixtures
and preferences are isolated. Live SSH creation still requires a reachable host;
the SSH exclusive-create script can be exercised locally without credentials.

The format and output contract are documented in `PROJECTS.md`.

CSV integration checks also exercise analysis snapshots: committing pending cell
edits, all versus filtered/sorted rows, stable source-row indices, numeric missing
and invalid values, duplicate headers, short records, type hints, snapshot
independence after edits, CSV serialization and closed-grid lifetime.

# Analysis notebook checks

The runtime runner takes a check file as an optional third argument. After the
same Debug build:

```sh
python3 Tests/run-runtime-checks.py /tmp/centcom-projects-build \
  /tmp/centcom-projects-build/SourcePackages AnalysisIntegrationChecks.swift
```

These pin the statistics to the values R gives for the same data — sample SD,
type-7 quartiles, Pearson and tie-averaged Spearman, the t/F/chi-square/normal
distribution functions to twelve significant digits, `cor.test`, `chisq.test`,
`p.adjust`, `qt`, `t.test` in its one-sample, Welch, pooled and paired forms,
`summary(aov(y ~ f))`, and `summary(lm(y ~ x1 + x2))` with `confint` and
`anova` — and cover the missing
versus unusable distinction, the three missing policies, cross-tab totals and
exclusions, header drift and absent columns, snapshot fingerprints, sidecar
round-tripping and validation, decoding a notebook written before significance
testing existed, the Markdown export, and cell resolution for the console
hand-off. The emitted R script is checked by executing it under `Rscript`, which
is skipped when R is not installed. Each expected constant carries the R
expression that produced it, so any of them can be regenerated with `Rscript`. The last block mounts
`NotebookView` in a temporary window over a temporary project and runs a step
against a file on disk. No project of yours is read or written.

# BYOK agent checks

Core checks compile the production runner, providers, native tools, and DMG
command executor directly. They do not need package downloads or API keys:

```sh
python3 Tests/run-agent-core-checks.py
python3 Tests/run-agent-core-checks.py --app-store
```

Checks cover revision conflicts, exclusive creation, symlink/traversal and hard-link
rejection, binary-file exclusion, native search, SSE fragmentation/Unicode,
provider-specific continuation blocks, interleaved Chat Completions tool deltas,
endpoint normalization, credential scoping, keyless local requests, HTTP fixtures, unauthorized tools,
interrupted-call recovery, and DMG command output, timeout and descendant cleanup.
The App Store check also verifies the command implementation is absent from symbols.

After a Debug app build, run the integration checks against the built module:

```sh
python3 Tests/run-runtime-checks.py /tmp/centcom-byok-build \
  /tmp/centcom-byok-packages AgentIntegrationChecks.swift
```

This additionally checks edit approvals/declines, cross-window unsaved-buffer
protection, SwiftData endpoint snapshots, independent saved connection settings,
and an isolated temporary Keychain service.
No live provider requests are made. All file fixtures are in `/tmp`.

Live acceptance: in Settings → Agents select ENGRAISERVER/custom (Chat Completions,
`https://llm.engrai.app/v1`, bearer credential entered directly into the app), Ollama
(Responses, local Base URL, no authentication), or Ollama Cloud (Responses,
`https://ollama.com/v1`, Ollama bearer key). Set an available tool-capable model ID.
Official OpenAI/Anthropic API routes remain optional; no paid API account is needed
for local inference. Cloud models through local Ollama require that server to be
signed in already. The app does not perform browser OAuth or start model servers.
Then open a local project. Ask for an edit and
review its before/after text. Decline must leave disk unchanged; approval must
apply the edit and refresh open editors. Follow-up prompts and reopening the
project must retain conversation context. Stop must cancel requests and pending
approvals. In the DMG, enable local commands and approve a small test command.
The App Store build must never offer or dispatch that tool.

Changing a Base URL must clear the credential indicator unless a key was already
saved for the new endpoint. A running/existing conversation keeps its original
endpoint, model and API format; use New Chat to apply settings changes. Verify
local-network permission on a signed build when connecting to a LAN server.
HTTP fixture tests validate wire behavior, not live model tool quality, cloud
account access, or the signed sandbox's network permission prompts.

Build the `TypeNBash-AppStore` scheme for the sandboxed configuration. Signed
sandbox acceptance additionally requires choosing a workspace in the native
folder panel, reopening through its bookmark after relaunch, and revoking access.
Signing/provisioning and store review remain separate from unsigned compile checks.

# Signed sandbox terminal prototype

`AppStoreDebug` exposes a SwiftTerm console only while a local project with a
retained `WorkspaceFolderGrant` is open. `AppStoreRelease` still has no local
console, and agent shell execution remains DMG-only. The DMG launch arguments,
login-shell integration, credential environment, and terminal backend are unchanged.

The prototype launches `/bin/zsh -d -i` with an explicit system-tool PATH and
app-owned HOME, startup file, history, and temporary directory. It starts at the
project root and rejects configurations without a grant or outside that grant.
It does not source the real user's shell configuration or pass the parent app's
environment/credentials. Closing the project removes its console. This is a
workspace-anchored shell inheriting App Sandbox, **not a per-repository jail**:
normal system/container access and other applicable app grants still exist.

Build the `TypeNBash-AppStore` scheme using `AppStoreDebug` with signing enabled.
Then build the separate diagnostic app, supplying a local signing identity:

```sh
python3 Tests/build-sandbox-terminal-probe.py /tmp/centcom-byok-store-final \
  /tmp/centcom-byok-packages /tmp/centcom-sandbox-probe-new 'Apple Development: …'
```

The output directory must not already exist. Open its `SandboxTerminalProbe.app`
through Finder/Launch Services, then select the generated `workspace # café`
folder in the native chooser. The probe uses the production launch configuration,
folder grant, SwiftTerm host, and controller from the built app module. It has its
own bundle identifier/container and the same file-access/network sandbox
entitlements; it does not use the production app group. It runs commands only in
the generated fixture. It creates no global Git identity and uses no credentials
or network requests. No sandbox exceptions or unsandboxed helpers are installed.

`terminal-probe.log` records command outcomes. `pty-output/log-*` records raw PTY
output, including startup errors. `probe-resize.txt` records parent-side PTY sizes;
`probe-lifecycle.txt` records whether Ctrl-C interrupted a 30-second sleep within
two seconds. `probe-process.txt` records shell exit and the parent's denied read
of an unselected sibling. SwiftTerm reports a raw wait status: 1792 is exit 7.

Signed measurements on macOS 27.0 (26A428), 2026-10-19:

| Operation | Observed result |
| --- | --- |
| Selected workspace read/write; child `/bin/sh`; pipes and sort | Works |
| `/bin/sh ./hello.sh` | Works |
| Unselected sibling read/write, including via symlink | Denied |
| App-owned HOME read/write and `/etc/hosts` read | Works, as allowed by App Sandbox |
| Direct workspace script or compiled binary execution | Denied |
| `/usr/bin/git`, `/usr/bin/python3`, Swift and Clang launchers | `xcrun: error: cannot be used within an App Sandbox.` |
| `/opt/homebrew/bin/python3` and Node | Execution denied |
| PTY descriptors (`isatty`) | Present |
| Parent-side `TIOCGWINSZ` and resize | Works; initial size is explicitly set on the master |
| Zsh terminal process group, `/dev/tty`, `stty` | Fail (`operation not permitted`, `device not configured`, `TIOCGETD` denial) |
| Ctrl-C during foreground `sleep 30` | Did not interrupt within two seconds; command finishes normally |
| Explicit shell exit | Delivered after the foreground command finishes |

The ordinary project commands are useful, but this launch path is not a reliable
full interactive terminal under the current sandbox entitlements. Do not ship the
prototype as one. The native SwiftGitX UI remains the working Git path. macOS 26,
restored project bookmarks, multiple concurrent workspace grants, full-screen TUIs,
and App Review acceptance require separate validation.

DMG validation: `run-runtime-checks.py` passes its existing state and real-PTY
checks, including local zsh, remote bash/zsh hooks, encoded directory reports,
SSH workflow guards, and shell exit.
