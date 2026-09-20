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
