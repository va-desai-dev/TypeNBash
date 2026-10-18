# Source organization

`TypeNBash` contains app sources and bundled resources. Development notes and
test harnesses live outside that directory. Xcode synchronizes the source folder,
so moving Swift files inside it does not require individual project references.

| Folder | Responsibility |
| --- | --- |
| `App` | App entry point, window composition, toolbar and presentation state |
| `Workspace` | Window session, backend transitions, filesystem abstraction |
| `Projects` | Saved project persistence, selection and opening |
| `SSH` | Connection profiles, authentication, transport and remote filesystem |
| `Terminal` | Native terminal bridge, controller and shell integration |
| `FileBrowser` | Directory browsing and file preview; `CSV` owns the grid |
| `Analysis` | Notebook steps, the statistics kernel and distributions, and the notebook pane |
| `Editor` | Text editor bridge, session, syntax, text system and find UI |
| `SourceControl` | Git service, observable model and UI; `Diff` and `GitHub` own their features |
| `Telemetry` | System monitoring, remote telemetry and inspector rows |
| `Agents` | Native BYOK provider adapters, tool runner, workspace tools, approvals, conversations, and chat presentation |
| `Resources`, `Assets.xcassets` | Bundled syntax definitions and visual assets |

Keep operational work in the existing models and services. Views own presentation
state and forward actions to those objects. Editor text-system extensions remain
together under `Editor`, separate from workspace and Git operations.

## Startup routing

The app has two native scenes: a fixed-size Welcome `Window` with a system
background and hidden title bar, and a resizable workspace `WindowGroup` with
its own default size and canvas styling. File → Welcome to TypeNBash (Command-N)
reopens the startup window without changing existing workspaces.

`EntryView` owns a fresh `AppRouter` each time Welcome opens. Home prepares a local
workspace; New Project replaces the dashboard with an inline project form at
the same welcome-window size. Its saved-project section is omitted because the
dashboard already provides that list. Cancel returns to the dashboard. Selecting SSH replaces the
project list with saved connection profiles. New Connection opens the shared SSH
form inline in Welcome; selecting a saved connection prefills that form. Cancel
returns to the SSH list, and successful connection transfers the session to a
workspace window. The workspace toolbar retains the modal SSH form. Open Project
uses the selected saved project, or presents the picker when nothing is selected.
Cancellation and failed opens retain Welcome. On success, `WorkspaceWindows`
retains the prepared router by UUID, the app opens a separate workspace window,
and Welcome closes without disconnecting the transferred session. Closing a
workspace releases only its session. These transient window IDs are not restored
across app launches; launch starts at Welcome.

`ContentView` routes project sessions to `ProjectWorkspaceView`, keyed by project
identity, and unscoped Home/SSH sessions to `FreeWorkspaceView`. Each owns its
terminal controller and feature presentation state. Project mode always mounts a
native vertical split with editor/comparison above and console below. Changing
files or opening Git changes does not replace the console. `CanvasView` shares
only window chrome, sidebar and telemetry; editor UI state lives in
`WorkspaceEditorPane`. Leaving a project releases its UI state.

The project's `WindowSession` owns its backend, root and file browser. Console PWD
reports are recorded as `consoleDirectory` but never navigate the project browser,
and a local console restart replaces
only the terminal generation, preserving the editor's draft. Home/SSH browsing
continues to follow shell directories. This is workspace state isolation, not an
OS security sandbox for executed commands.

Terminal/editor selection is independent of startup routing. Project validation, credentials and persistence
remain in `ProjectPickerModel` and the existing SSH flow.

See `Tests/TESTS.md` for the build and integration harnesses.

## Analysis notebook

`AnalysisStep` describes a calculation as a `Codable` value; `AnalysisKernel` is
the only thing that runs one, pure and off the main actor. `NotebookModel` owns
a project's steps, the tables they read and the results so far, and `NotebookView`
builds and renders those values without computing anything. Steps persist in a
project sidecar; results do not. The toolbar action captures the editor's table
before swapping the pane in, because showing the notebook unmounts the grid.
`NotebookScript` emits the same steps as an R script, and `EditorSession`
resolves the `# %%` cell around the caret so the editor can send it to the
project console. That hand-off is one way: nothing reads R's output back.
See `NOTEBOOK.md`.

## Project footer divider

`ProjectSplitView` accepts editor, footer and console content. Its native split
subclass reserves the footer's height as divider thickness, draws the separator
edges, and positions a non-arranged hosting view inside that gap. The split
controller makes the status area the effective drag area. Passive status
content passes pointer events to AppKit while retaining accessibility labels.
The footer and the console button sit in that gap as non-arranged subviews, and
`NSSplitView` hit-tests only its arranged panes, so both are offered a point
before the divider claims it. The hosting view declines anything that is not one
of its own AppKit-backed controls, which keeps a status label passive while
letting a footer text field or button work. The native footer button toggles the
console split item's `isCollapsed` state. The console remains mounted, its shell keeps running,
and AppKit restores its previous height when shown. The divider remains visible
while collapsed, so the Show Console action stays reachable. SwiftUI's binding
can request visibility changes, including revealing the console for Open in Terminal.
Editor and Git comparison footers supply their own contents; project mode omits
their in-pane footer to avoid duplication. Home/SSH keep the ordinary editor
footer. Divider movement stays in AppKit and does not write SwiftUI geometry state.

## Portable project definitions

`ProjectManifest` defines the versioned `.typenbash.json` file and its validation.
`ProjectPickerModel` orchestrates create/initialize/open against the selected
`WorkspaceFileSystem`; the form only presents those actions. Exclusive file
creation protects existing definitions on both local and SSH backends. Recents
remain in `ProjectStore`, while portable name/output settings live with project
files and are reloaded on open. `WindowSession.prepareProjectOutputDirectory()`
provides one lazy, project-relative output destination for future exporters.
See `PROJECTS.md` for the format and behavior.

## BYOK workspace agents

`AgentSession` owns observable chat state and user decisions; `AgentRunner` owns
the bounded provider/tool loop. `AgentHTTPProvider` maps Anthropic Messages,
OpenAI Responses, and OpenAI Chat Completions to common events while retaining
provider continuation items. `AgentChatCompletionStream` assembles interleaved
tool names/arguments by index and preserves reasoning fields used by local models.
Raw SSE framing handles fragmented UTF-8 and requires a complete response before
any tool executes. Model IDs are explicit settings, not hard-coded aliases.

`AgentConnection` separates API format, Base URL, and authentication. Settings
retain independent ENGRAISERVER/custom, local Ollama, Ollama Cloud, and official
API connections. ENGRAISERVER defaults to `https://llm.engrai.app/v1` with Chat
Completions and a bearer credential; its model ID is user-selected. Local Ollama
defaults to `http://localhost:11434/v1` with Responses and no credential. A signed-in
local Ollama server can route cloud models; direct Ollama Cloud uses
`https://ollama.com/v1` and an Ollama bearer key. The app does not start model servers
or perform subscription OAuth. OpenAI/Anthropic API connections remain optional.

An origin URL gets `/v1`; an explicit base path is retained. A pasted full endpoint
is normalized without doubling the suffix. Credentials live in Keychain scoped to
the normalized API base and authentication mode. Existing official-provider key
accounts remain usable. URL credentials, query strings and fragments are rejected.
Requests do not follow redirects or use shared credential/cookie storage. HTTPS
is required for remote hosts; local HTTP is allowed with `NSAllowsLocalNetworking`
and a local-network usage description, without an arbitrary-loads ATS exception.
Ollama/custom Responses requests omit OpenAI-only encrypted-reasoning and strict
schema options. Chat Completions uses `role: tool` results and requires a finish
reason plus `[DONE]`; incomplete, truncated or duplicate calls cannot execute.

`AgentWorkspaceTools` reads and searches on an actor. Its descriptor-relative local
access rejects traversal, symlinks, hard links, known credential paths, nonregular
files and oversized/binary content. This specialized access layer avoids reopening
unchecked paths through the general browsing filesystem. Changes carry content
revisions and exact-match edits. `AgentEditorCoordinator` checks every registered
editor for unsaved changes immediately before a bounded atomic file commit, then
refreshes the relevant windows. The chat exposes before/after review and conditional
revert of existing-file edits. New files/directories are retained when stopping a run.

`AgentConversationStore` uses a dedicated SwiftData configuration for transcripts,
provider continuation state, pending tool calls and completed results. Recovery
settles uncertain calls as interrupted rather than replaying side effects. Provider
or model changes take effect in a new conversation. Each new conversation also
freezes its endpoint, API format and authentication method, so changing settings
does not send existing history to a different server. Legacy snapshots retain
their original official endpoint. Context is bounded to 2 MB,
turns to 20 model rounds, and provider output to 8 MB; automatic compaction is not
implemented. Tools are advertised and checked at dispatch against build capabilities.

Debug/Release are DMG configurations with `DIRECT_DISTRIBUTION`. The
`TypeNBash-AppStore` scheme uses AppStoreDebug/AppStoreRelease, `APP_STORE`, its own
bundle identifier, sandbox entitlements and user-selected folder bookmarks.
`AgentLocalCommand` is compiled only with `DIRECT_DISTRIBUTION && !APP_STORE`.
Commands require individual approval, capture bounded stdout/stderr, and use their
own process group with a 120-second maximum. The working directory is not a security
boundary for commands. The agent never writes commands into the interactive terminal.

The App Store variant does not instantiate the terminal pane; its terminal launch
call is also compiled out. Its project picker uses NSOpenPanel and holds a security
scope for the workspace/session lifetime. SSH agents and App Store SSH workspaces
are not implemented yet. This configuration is a sandbox development target; the
rest of the app still needs signed sandbox acceptance and distribution review.
