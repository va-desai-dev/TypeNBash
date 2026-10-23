import Foundation
import LineEnding
import StringUtils
import TextFind
import ValueRange

nonisolated struct ProjectSearchMatch: Identifiable, Sendable {
    var id: NSRange { range }
    let range: NSRange
    let line: Int
    let before: String
    let matched: String
    let after: String
}

nonisolated struct ProjectSearchResult: Identifiable, Sendable {
    var id: URL { url }
    let url: URL
    let path: String
    let text: String
    let matches: [ProjectSearchMatch]
    let pattern: TextFind.Pattern

    var icon: FileTypeIcon {
        WorkspaceFileEntry.icon(for: url)
    }
    var label: String {
        url.lastPathComponent
    }
}

nonisolated struct ProjectReplacement: Identifiable, Sendable {
    let id = UUID()
    let file: ProjectSearchResult
    let text: String
    let changes: [ProjectSearchChange]
}

nonisolated struct ProjectSearchChange: Identifiable, Sendable {
    var id: NSRange { match.range }
    let match: ProjectSearchMatch
    let replacement: String
}

nonisolated enum ProjectSearchEngine {
    static let byteLimit = 2 * 1024 * 1024
    static let matchLimit = 10_000
    static let snapshotLimit = 32 * 1024 * 1024

    @concurrent static func search(text: String, url: URL, path: String, query: String,
                                   options: FindOptions, limit: Int) async throws -> ProjectSearchResult {
        let ending = text.lineEndingRanges().majorValue() ?? .lf
        let pattern = try TextFind.Pattern(findString: query.replacingLineEndings(with: ending), mode: options.mode)
        let finder = TextFind(for: text, pattern: pattern)
        let counter = LineCounter(string: text)
        let source = text as NSString
        var matches: [ProjectSearchMatch] = []
        try finder.findAll { ranges, stop in
            if Task.isCancelled || matches.count >= limit { stop = true; return }
            let range = ranges[0]
            let line = source.lineRange(for: NSRange(location: range.location, length: 0))
            // Bound snippets even for minified files and multi-line regex matches.
            let start = max(line.location, range.location - 60)
            let end = min(source.length, range.location + min(range.length, 160) + 80, NSMaxRange(line))
            let visibleMatchEnd = min(NSMaxRange(range), end)
            matches.append(ProjectSearchMatch(range: range, line: counter.lineNumber(at: range.location),
                before: source.substring(with: NSRange(location: start, length: range.location - start)),
                matched: range.length == 0 ? "│" : source.substring(with: NSRange(location: range.location, length: visibleMatchEnd - range.location)),
                after: source.substring(with: NSRange(location: visibleMatchEnd, length: end - visibleMatchEnd)).trimmingCharacters(in: .newlines)))
        }
        try Task.checkCancellation()
        return ProjectSearchResult(url: url, path: path, text: text, matches: matches, pattern: pattern)
    }

    @concurrent static func replacement(for file: ProjectSearchResult, match: NSRange?, with template: String) async throws -> ProjectReplacement {
        let output = NSMutableString(string: file.text)
        var changes: [ProjectSearchChange] = []
        for item in file.matches where match == nil || item.range == match {
            try Task.checkCancellation()
            let finder = try TextFind(for: file.text, pattern: file.pattern, selectedRanges: [item.range])
            guard let replacement = finder.replace(with: template), replacement.range == item.range else {
                throw WorkspaceFileSystemError.unsupported("A match could not be replaced. Search again.")
            }
            changes.append(ProjectSearchChange(match: item, replacement: replacement.value))
        }
        for change in changes.reversed() {
            output.replaceCharacters(in: change.match.range, with: change.replacement)
        }
        guard output.length <= byteLimit, output.lengthOfBytes(using: String.Encoding.utf8.rawValue) <= byteLimit else {
            throw WorkspaceFileSystemError.fileTooLarge(limit: byteLimit)
        }
        return ProjectReplacement(file: file, text: output as String, changes: changes)
    }

    /// Comma-separated path globs. A bare name/glob matches at any depth.
    static func filters(_ value: String) throws -> [NSRegularExpression] {
        try value.split(separator: ",").compactMap { part in
            let glob = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !glob.isEmpty else { return nil }
            var expression = glob.contains("/") ? "^" : "(^|.*/)"
            var index = glob.startIndex
            while index < glob.endIndex {
                let character = glob[index]
                index = glob.index(after: index)
                if character == "*" {
                    if index < glob.endIndex, glob[index] == "*" {
                        index = glob.index(after: index)
                        if index < glob.endIndex, glob[index] == "/" {
                            index = glob.index(after: index)
                            expression += "(?:.*/)?"
                        } else { expression += ".*" }
                    } else { expression += "[^/]*" }
                } else if character == "?" { expression += "[^/]" }
                else { expression += NSRegularExpression.escapedPattern(for: String(character)) }
            }
            return try NSRegularExpression(pattern: expression + "$")
        }
    }

    static func matches(_ path: String, filters: [NSRegularExpression]) -> Bool {
        filters.contains { $0.firstMatch(in: path, range: NSRange(location: 0, length: (path as NSString).length)) != nil }
    }
}

/// Everything one project-wide search needs, captured when the search is scheduled.
struct ProjectSearchRequest {
    let root: URL
    let fileSystem: any WorkspaceFileSystem
    let query: String
    let options: FindOptions
    let includes: String
    let excludes: String
    /// The open document, searched from its in-memory text instead of disk.
    let bufferURL: URL?
    let buffer: String?
}

enum ProjectSearchEvent {
    case scanned
    case skipped
    case found(ProjectSearchResult)
}

extension ProjectSearchEngine {
    /// Walks the project depth-first and reports progress through `emit`.
    /// Throws `CancellationError` as soon as `isCurrent` turns false, so a stale
    /// search never touches the caller's state. Returns whether a limit stopped the walk.
    @MainActor static func crawl(_ request: ProjectSearchRequest, isCurrent: () -> Bool,
                                 emit: (ProjectSearchEvent) -> Void) async throws -> Bool {
        let root = request.root, fs = request.fileSystem
        _ = try TextFind.Pattern(findString: request.query, mode: request.options.mode)
        let includeFilters = try filters(request.includes)
        let excludeFilters = try filters(request.excludes)
        func checkCurrent() throws {
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
        }
        var directories = [root]
        var snapshotBytes = 0
        var visited = 0
        var found = 0
        while let directory = directories.popLast() {
            try checkCurrent()
            let entries: [WorkspaceFileEntry]
            do { entries = try await fs.searchEntries(at: directory, root: root) }
            catch is CancellationError { throw CancellationError() }
            catch {
                try checkCurrent()
                if directory == root { throw error }
                emit(.skipped)
                continue
            }
            for entry in entries.sorted(by: { $0.url.path < $1.url.path }) {
                try checkCurrent()
                visited += 1
                if visited > 50_000 { return true }
                guard entry.url.standardizedFileURL.pathComponents.starts(with: root.standardizedFileURL.pathComponents) else { continue }
                let path = entry.url.pathComponents.dropFirst(root.pathComponents.count).joined(separator: "/")
                if matches(path, filters: excludeFilters) { continue }
                if entry.isDirectory { directories.append(entry.url); continue }
                if !includeFilters.isEmpty && !matches(path, filters: includeFilters) { continue }
                do {
                    let text: String
                    if entry.url == request.bufferURL, let buffer = request.buffer {
                        guard buffer.utf8.count <= byteLimit else { emit(.skipped); continue }
                        text = buffer
                    } else {
                        if let size = entry.byteCount, size > byteLimit { emit(.skipped); continue }
                        let data = try await fs.readSearchFile(at: entry.url, root: root, limit: byteLimit)
                        guard !data.contains(0), let decoded = String(data: data, encoding: .utf8) else { emit(.skipped); continue }
                        text = decoded
                    }
                    let result = try await search(text: text, url: entry.url, path: path,
                        query: request.query, options: request.options, limit: matchLimit - found)
                    try checkCurrent()
                    emit(.scanned)
                    if !result.matches.isEmpty {
                        snapshotBytes += text.utf8.count
                        if snapshotBytes > snapshotLimit { return true }
                        found += result.matches.count
                        emit(.found(result))
                    }
                    if found >= matchLimit { return true }
                } catch is CancellationError { throw CancellationError() }
                catch {
                    try checkCurrent()
                    emit(.skipped)
                }
            }
        }
        return false
    }
}
