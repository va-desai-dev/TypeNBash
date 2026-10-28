//
//  GitDiffFileList.swift
//  TypeNBash
//
//  Created by Vedant A. Desai on 10/24/26.
//

import SwiftUI

enum DiffListTab: String, CaseIterable, Sendable, Hashable, Identifiable {
    case changes = "Changes"
    case repos = "Repositories"
    var id: String { rawValue }
}

enum RepoDisclosureItems: String, CaseIterable, Sendable, Hashable, Identifiable {
    case branches = "Branches"
    case recents = "Recents"
    case tags = "Tags"
    case stashes = "Stashes"
    case remotes = "Remotes"
    var id: String { rawValue }

    var icon: String {
        switch self {
            case .branches: "externaldrive.fill"
            case .recents: "clock.fill"
            case .tags: "tag.square.fill"
            case .stashes: "tray.2.fill"
            case .remotes: "network"
        }
    }
}


struct GitDiffFileList: View {
    /// The list shares the comparison's model rather than owning one, so
    /// selecting a row is the same `select(_:)` that reloads the diff.
    let model: GitDiffModel
    @State private var highlightedFile: String?
    @State private var selection: DiffListTab = .changes
    /// Held here rather than in the Repositories list, which is rebuilt on
    /// every tab switch, so expansion and selection survive the trip.
    @State private var refs: GitRefsModel

    init(model: GitDiffModel, files: FileBrowserModel) {
        self.model = model
        _refs = State(initialValue: GitRefsModel(directory: model.directory, remote: model.remote, files: files))
    }

    var body: some View {
        Group {
            if selection == .changes {
                changeList
            } else if selection == .repos {
                RepoDisclosureList(model: refs)
            }
        }
        // Staging, commits, switches and merges all change what differs from HEAD.
        .onReceive(NotificationCenter.default.publisher(for: .gitRepositoryDidChange)) { _ in
            Task { await model.refresh() }
        }
        .paneBar(.top) {
            VStack(spacing: 0) {
                PaneBar {
                    GitDiffStatsLabel(model: model)
                    Spacer()
                    GitDiffScopePicker(model: model)
                }
                PaneBar {
                    FillingTabStrip(accessibilityLabel: "Source Control Tabs", tabs: DiffListTab.allCases,
                                    selection: $selection, title: \.rawValue) {
                        .title($0.rawValue)
                    }
                }
            }
        }
    }

    /// Filled when the change is staged, outlined when it is only in the
    /// working tree, and both — a faint fill inside the outline — when
    /// part of it is staged.
    func badgeView(for file: GitDiffFile) -> some View {
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
        let accent = file.status.color
        let fill = !file.staged ? 0 : file.unstaged ? 0.3 : 0.7
        return Text(file.status.letter)
            .font(.caption.monospaced().weight(.heavy))
            .frame(width: 16, height: 16)
            .background(accent.opacity(fill), in: shape)
            .overlay {
                if file.unstaged { shape.strokeBorder(accent, lineWidth: 1.5) }
            }
            .contentShape(Rectangle())
            .help(badgeHelp(for: file))
    }

    func badgeHelp(for file: GitDiffFile) -> String {
        let stage = switch (file.staged, file.unstaged) {
        case _ where model.scope == .committed: "Committed, not pushed"
        case (true, true): "Partially staged"
        case (true, false): "Staged"
        default: "Not staged"
        }
        return "\(file.tipMessage) · \(stage)"
    }

    var changeList: some View {
        List(selection: $highlightedFile) {
            ForEach(model.visibleFiles) { file in
                HStack(spacing: 8) {
                    FileTypeIconView(icon: file.icon, symbolStyle: Color.accentColor)
                    Text(file.label)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .strikethrough(file.status == .deleted)
                    Spacer()
                    badgeView(for: file)
                }
                .frame(height: 24)
                .contentShape(Rectangle())
                .tag(file.id)
                .onTapGesture(count: 1) {
                    // Highlight locally at once, like `FileBrowserList`, then
                    // load the diff; `onChange(of: model.selectedPath)` below
                    // keeps the highlight in sync if the model picks another file.
                    highlightedFile = file.id
                    model.select(file.path)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .listStyle(.sidebar)
        .onChange(of: model.selectedPath, initial: true) { _, value in
            highlightedFile = value
        }
    }
}

//MARK: Repositories outline
/// Branches, recents, tags, stashes and remotes as an Xcode-style outline.
/// Everything it shows comes from `GitRefsModel`; this only draws rows.
struct RepoDisclosureList: View {
    @Bindable var model: GitRefsModel
    @State private var forkSource: GitBranchRef?
    @State private var newBranchName = ""
    @State private var mergeSource: GitBranchRef?

    var body: some View {
        List(selection: $model.selection) {
            ForEach(RepoDisclosureItems.allCases) { section in
                RepoOutlineRow(model: model, id: "section:" + section.rawValue,
                               children: model.nodes(for: section), command: run) {
                    RepoRowLabel(title: section.rawValue, icon: section.icon, tint: .secondary)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .listStyle(.sidebar)
        .alert("New Branch", isPresented: isPresent($forkSource), presenting: forkSource) { source in
            TextField("Branch name", text: $newBranchName)
            Button("Create") {
                let name = newBranchName
                Task { await model.perform(.newBranch(name, from: source)) }
            }
            Button("Cancel", role: .cancel) { }
        } message: { source in
            Text("Create a branch at “\(source.name)” and switch to it.")
        }
        .confirmationDialog(mergeTitle, isPresented: isPresent($mergeSource), presenting: mergeSource) { source in
            Button("Merge") { Task { await model.perform(.merge(source)) } }
            Button("Cancel", role: .cancel) { }
        } message: { _ in
            Text("Fast-forwards when possible, otherwise records a merge commit. Conflicts are left in the work tree to resolve.")
        }
        .alert(model.notice?.title ?? "", isPresented: isPresent($model.notice)) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(model.notice?.message ?? "")
        }
        // Each visit reloads, which picks up fetches and checkouts made in
        // the console. Fetches, pushes and commits made in the app reload it
        // in place; its own actions already reload it.
        .task { await model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .gitRepositoryDidChange)) { note in
            guard note.object as AnyObject? !== model else { return }
            Task { await model.refresh() }
        }
    }

    /// Switching runs at once, since a safe checkout refuses to overwrite
    /// uncommitted work; the other two ask first.
    private func run(_ command: RepoBranchCommand) {
        switch command {
        case .switchTo(let ref): Task { await model.perform(.switchTo(ref)) }
        case .newBranch(let ref):
            newBranchName = ""
            forkSource = ref
        case .merge(let ref): mergeSource = ref
        }
    }

    private var mergeTitle: String {
        guard let mergeSource else { return "" }
        return "Merge “\(mergeSource.name)” into “\(model.snapshot?.current ?? "HEAD")”?"
    }

    private func isPresent<T>(_ value: Binding<T?>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
    }
}

enum RepoBranchCommand {
    case switchTo(GitBranchRef), newBranch(GitBranchRef), merge(GitBranchRef)
}

/// A row and, recursively, its children. Rows with children disclose them;
/// every disclosure starts open and remembers being closed in the model.
private struct RepoOutlineRow<Label: View>: View {
    let model: GitRefsModel
    let id: String
    let children: [GitRefNode]
    let command: (RepoBranchCommand) -> Void
    @ViewBuilder let label: Label

    var body: some View {
        if children.isEmpty {
            label.tag(id)
        } else {
            DisclosureGroup(isExpanded: isExpanded) {
                ForEach(children) { child in
                    RepoOutlineRow<RepoNodeLabel>(model: model, id: child.id, children: child.children,
                                                  command: command) {
                        RepoNodeLabel(model: model, node: child, command: command)
                    }
                }
            } label: {
                label.tag(id)
            }
        }
    }

    private var isExpanded: Binding<Bool> {
        Binding(
            get: { !model.collapsed.contains(id) },
            set: { open in
                if open { model.collapsed.remove(id) } else { model.collapsed.insert(id) }
            }
        )
    }
}

/// A ref's row, with the branch actions on branches. Tags get none.
private struct RepoNodeLabel: View {
    let model: GitRefsModel
    let node: GitRefNode
    let command: (RepoBranchCommand) -> Void

    var body: some View {
        if let ref = node.ref {
            RepoRowLabel(node: node).contextMenu {
                let blocked = model.actionBlocker != nil
                let current = model.snapshot?.current
                Button("Switch to “\(ref.name)”") { command(.switchTo(ref)) }
                    .disabled(blocked || node.isCurrent)
                Button("New Branch from “\(ref.name)”…") { command(.newBranch(ref)) }
                    .disabled(blocked)
                Divider()
                Button("Merge “\(ref.name)” into “\(current ?? "Current Branch")”…") { command(.merge(ref)) }
                    .disabled(blocked || current == nil || node.isCurrent)
                if let blocker = model.actionBlocker {
                    Divider()
                    Text(blocker)
                }
            }
        } else {
            RepoRowLabel(node: node)
        }
    }
}

private struct RepoRowLabel: View {
    let title: String
    let icon: String
    var tint: Color = .accentColor
    var isCurrent = false
    var help: String?

    init(title: String, icon: String, tint: Color = .accentColor, isCurrent: Bool = false, help: String? = nil) {
        self.title = title
        self.icon = icon
        self.tint = tint
        self.isCurrent = isCurrent
        self.help = help
    }

    init(node: GitRefNode) {
        self.init(title: node.title, icon: node.icon,
                  tint: node.kind == .folder ? .secondary : .accentColor,
                  isCurrent: node.isCurrent, help: node.detail)
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 16)
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
            if isCurrent {
                Text("(current)")
                    .foregroundStyle(.secondary)
            }
        }
        .help(help ?? title)
    }
}

