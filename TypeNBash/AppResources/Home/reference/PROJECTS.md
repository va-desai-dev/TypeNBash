# Project workspaces

A folder can be opened as a workspace without modifying it. A managed project
also contains a portable `.typenbash.json` definition:

```json
{
  "version": 1,
  "name": "Analysis",
  "outputDirectory": "output"
}
```

The containing folder is the project root. All three fields are required in
version 1. `outputDirectory` is a single child-folder name, not an absolute path
or a path containing traversal components. The definition contains no host paths,
SSH profile IDs, credentials, or executable commands. It can travel with a copied
folder or be committed alongside the project's files.

A project may also hold `.typenbash-notebook.json` beside this file, with the
same project-relative, portable rules. See `NOTEBOOK.md`.

## Creation and opening

The project setup form has three actions:

- **Create new folder:** choose a parent directory and a project folder name.
  TypeNBash creates that child directory and its definition, then opens it.
- **Initialize existing folder:** add a definition to an existing directory.
  Existing files remain in place; an existing definition is never overwritten.
- **Open existing folder:** read its definition if present; otherwise open it as
  an ordinary folder workspace without writing metadata. The path field also
  accepts the path to `.typenbash.json` itself.

New Project defaults to creating a new folder. The same actions use the selected
local or SSH filesystem. A copied project opens using its new containing folder;
its saved name and output setting follow it. UserDefaults stores the recent list
and machine-specific connection association, not the sole project definition.
Definitions are reloaded when opening, including from the recent list. Invalid,
oversized, or unsupported definitions report an error before switching workspaces.
Removing a recent entry does not delete the folder or definition.

Creation refuses name collisions. If creation is interrupted after filesystem
writes, the new files remain available; cancellation does not delete directories.
The output folder is not eagerly created.

## Output contract

Export actions call `WindowSession.prepareProjectOutputDirectory()` and write
through the active workspace filesystem. It creates and returns the configured
output directory on the project's host. Ordinary folder projects use `output` by
default. The resolver rejects file collisions, paths resolving outside the
project, and a workspace change while the request is running. The analysis
notebook's export is the first action to use it.

This is the shared destination contract; it does not redirect arbitrary shell
commands, which still use their own working directory. Local definitions can be
opened through the project picker; Finder file association is not part of this
format implementation.
