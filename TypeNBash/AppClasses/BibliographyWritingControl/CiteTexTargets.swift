import SwiftUI
import BibTeXViewer

/// Every open project's bibliography, and which one Safari captures land in.
///
/// There is one CiteTex inbox and possibly several open projects. Rather than
/// guessing from which window was key last, the user picks the target from
/// the menu bar, which stays reachable while they are in Safari.
@MainActor
@Observable
final class CiteTexTargets {
    static let shared = CiteTexTargets()

    struct Target: Identifiable {
        let id = UUID()
        let projectName: String
        weak var library: BibLibrary?
    }

    private(set) var targets: [Target] = []

    /// The target that receives captures. Bound to the menu bar picker.
    var activeID: UUID? {
        didSet {
            guard activeID != oldValue else { return }
            targets.first { $0.id == activeID }?.library?.becomeCaptureTarget()
        }
    }

    private init() {}

    /// Lists a project's library. The first one listed receives captures
    /// until the user picks another.
    @discardableResult
    func register(_ library: BibLibrary, projectName: String) -> UUID {
        targets.removeAll { $0.library == nil }
        let target = Target(projectName: projectName, library: library)
        targets.append(target)
        if activeID == nil || !targets.contains(where: { $0.id == activeID }) {
            activeID = target.id
        }
        return target.id
    }

    /// Removes a closed project. If it was the target, captures move to the
    /// next open project instead of waiting for one that is gone.
    func unregister(_ id: UUID) {
        targets.removeAll { $0.id == id || $0.library == nil }
        if !targets.contains(where: { $0.id == activeID }) {
            activeID = targets.first?.id
        }
    }
}

/// The menu bar's Safari menu: which open project's .bib CiteTex fills.
struct CiteTexMenu: View {
    @Bindable var targets: CiteTexTargets

    var body: some View {
        Picker("Send Safari Citations To", selection: $targets.activeID) {
            ForEach(targets.targets) { target in
                if let library = target.library {
                    CiteTexTargetLabel(projectName: target.projectName, library: library)
                        .tag(Optional(target.id))
                }
            }
        }
        .pickerStyle(.inline)
    }
}

/// Observes the library so the row follows the project's current .bib.
private struct CiteTexTargetLabel: View {
    let projectName: String
    @ObservedObject var library: BibLibrary

    var body: some View {
        Text("\(projectName) — \(library.fileURL?.lastPathComponent ?? "no .bib chosen")")
    }
}
