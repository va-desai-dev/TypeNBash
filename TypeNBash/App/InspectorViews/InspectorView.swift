//
//  WritingInspectorSubtabs.swift
//  TypeNBash
//
//  Created by Vedant A. Desai on 10/24/26.
//

import SwiftUI
import BibTeXKit
import BibTeXViewer

enum WritingInspectorSubtabs: String, CaseIterable, Identifiable {
    case citations, stats
    var id: String { rawValue }
}

/// Sampling is active only while the inspector is mounted.
struct WorkspaceInspector: View {
    let session: WindowSession
    @State private var monitor: SystemMonitor?
    @Binding var selection: InspectorTabs
    @Binding var subselection: WritingInspectorSubtabs
    @State private var showsBibPicker = false
    @State private var editingSnippet: Snippet?
    /// Sends a snippet to the console of the workspace hosting this inspector.
    let onRunSnippet: (String) -> Void

    var body: some View {
        // A real container, not a Group: Group forwards its modifiers to its
        // children, so while `monitor` is still nil the telemetry/process cases
        // have no children, nothing mounts, and the `.task` that creates the
        // monitor never runs.
        ZStack {
            switch selection {
                case .telemtry:
                    if let monitor {
                        ScrollView {
                            VStack {
                                TelemetryInspector(monitor: monitor)
                            }
                        }
                    }
                case .process:
                    if let monitor {
                        ScrollView {
                            VStack {
                                TopProcessesView(monitor: monitor)
                            }
                        }
                    }
                case .snippets:
                    SnippetsTab(store: session.storedSnippets, onRun: onRunSnippet, editing: $editingSnippet)
                case .agents:
                    if let agent = session.agent {
                        AgenticChatView(session: agent)
                            .id(ObjectIdentifier(agent))
                    } else {
                        ContentUnavailableView(
                            "No Project Open",
                            systemImage: "folder",
                            description: Text("Agents work inside a project's folder.")
                        )
                    }
                case .writing:
                    if subselection == .stats  {
                        WritingInspector(model: session.fileBrowser)
                    } else if let bibliography = session.bibliography {
                        BibliographyInspector(
                            library: bibliography,
                            onOpenFile: { url in
                                session.fileBrowser.select(
                                    WorkspaceFileEntry(url: url, isDirectory: false, byteCount: nil))
                            },
                            onChooseFile: { showsBibPicker = true }
                        )
                        .id(ObjectIdentifier(bibliography))
                        .sheet(isPresented: $showsBibPicker) {
                            BibFilePickerSheet(library: bibliography, fileSystem: session.fileSystem)
                        }
                    } else {
                        ContentUnavailableView(
                            "No Project Open",
                            systemImage: "books.vertical",
                            description: Text("Each project keeps its own .bib bibliography.")
                        )
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: session.terminalGeneration) {
            let monitor = monitor ?? SystemMonitor()
            self.monitor = monitor
            await session.streamTelemetry(to: monitor)
        }
        .paneBar(.top) {
            PaneBar {
                FillingTabStrip(accessibilityLabel: "Inspector Tabs", tabs: InspectorTabs.allCases,
                                selection: $selection, title: \.rawValue) { .image($0.nsImage) }
            }
        }
        .paneBar(.bottom) {
            if selection == .writing, session.fileBrowser.supportsCitations {
                PaneBar(edge: .bottom) {
                    WritingSubtabPicker(selection: $subselection)
                }
            } else if selection == .snippets {
                PaneBar(edge: .bottom) {
                    SnippetsBarItems(store: session.storedSnippets, onRun: onRunSnippet, editing: $editingSnippet)
                }
            } else {
                EmptyView()
            }
        }
    }
}

struct InspectorTabPicker: View {
    @Binding var selection: InspectorTabs

    var body: some View {
    }
}


struct WritingSubtabPicker: View {
    @Binding var selection: WritingInspectorSubtabs

    var body: some View {
        Picker("Writing", selection: $selection) {
            ForEach(WritingInspectorSubtabs.allCases) { tab in
                Text(tab.rawValue.capitalized)
                    .tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .buttonSizing(.flexible)
        .frame(maxWidth: .infinity)
    }
}

enum InspectorTabs: String, CaseIterable, Identifiable {
    case telemtry, process, snippets, agents, writing
    var id: String { rawValue }
    var title: String {
        switch self {
            case .telemtry: return "Telemetry"
            case .process: return "Processes"
            case .snippets: return "Snippets"
            case .agents: return "Agents"
            case .writing: return "Writing"
        }
    }
    var icon: String {
        switch self {
            case .telemtry: return "gauge.with.dots.needle.33percent"
            case .process: return "list.bullet.circle"
            case .snippets: return "apple.terminal.circle"
            case .agents: return "bubble.circle"
            case .writing: return "pencil.circle"
        }
    }
    var nsImage: NSImage? {
        switch self {
            case .telemtry: NSImage(systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: nil)
            case .process: NSImage(systemSymbolName: "list.bullet.circle", accessibilityDescription: nil)
            case .snippets: NSImage(systemSymbolName: "apple.terminal.circle", accessibilityDescription: nil)
            case .agents: NSImage(systemSymbolName: "bubble.circle", accessibilityDescription: nil)
            case .writing: NSImage(systemSymbolName: "pencil.circle", accessibilityDescription: nil)
        }
    }
}
