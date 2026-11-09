import Combine
import Foundation

struct WorkspaceSearchQuery: Equatable, Sendable {
    var text = ""
    var matchCase = false
    var wholeWord = false
    var regex = false
    var includes = ""
    var excludes = ""
    var useIgnores = true

    func expression() throws -> NSRegularExpression {
        var pattern = regex ? text : NSRegularExpression.escapedPattern(for: text)
        if wholeWord { pattern = "(?<![\\p{L}\\p{N}_])(?:" + pattern + ")(?![\\p{L}\\p{N}_])" }
        return try NSRegularExpression(pattern: pattern, options: matchCase ? [.anchorsMatchLines] : [.anchorsMatchLines, .caseInsensitive])
    }
}

struct WorkspaceSearchMatch: Identifiable, Sendable {
    var id: Int { range.location }
    let range: NSRange
    let line: Int
    let column: Int
    let preview: String
    let previewRange: NSRange
}

struct WorkspaceSearchFile: Identifiable, Sendable {
    var id: String { url.path }
    let url: URL
    let path: String
    let source: String
    let matches: [WorkspaceSearchMatch]
}

struct WorkspaceSearchResults: Sendable {
    var files: [WorkspaceSearchFile] = []
    var limitHit = false
    var skipped = 0
    var count: Int { files.reduce(0) { $0 + $1.matches.count } }
}

/// The worker receives immutable editor snapshots; no AppKit or actor state crosses queues.
enum WorkspaceSearchEngine {
    static let maxFileBytes = 4 * 1024 * 1024
    static let maxMatches = 10_000
    static let maxFiles = 20_000
    static let excludedDirectories: Set<String> = [".git", ".hg", ".svn", "node_modules", ".build"]

    static func search(root: URL, query: WorkspaceSearchQuery, buffers: [String: String] = [:],
                       cancelled: () -> Bool = { false }) throws -> WorkspaceSearchResults {
        guard !query.text.isEmpty else { return WorkspaceSearchResults() }
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let expression = try query.expression()
        let includes = SearchPathFilter(query.includes), excludes = SearchPathFilter(query.excludes)
        var output = WorkspaceSearchResults()
        // Git supplies its own ignore semantics, including nested .gitignore and negations.
        let gitPaths = query.useIgnores ? gitFiles(root: root) : nil
        var paths: [String] = []
        if let gitPaths {
            paths = gitPaths
            if paths.count > maxFiles { paths = Array(paths.prefix(maxFiles)); output.limitHit = true }
        } else if let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [], errorHandler: { _, _ in output.skipped += 1; return true }) {
            for case let url as URL in iterator {
                if cancelled() { break }
                guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { output.skipped += 1; continue }
                if values.isSymbolicLink == true { iterator.skipDescendants(); continue }
                if values.isDirectory == true {
                    if url.lastPathComponent == ".git" || (query.useIgnores && excludedDirectories.contains(url.lastPathComponent)) { iterator.skipDescendants() }
                    continue
                }
                // macOS directory enumeration may return /private/var for a /var root.
                let path = url.standardizedFileURL.resolvingSymlinksInPath().path
                guard path.hasPrefix(root.path + "/") else { continue }
                paths.append(String(path.dropFirst(root.path.count + 1)))
                if paths.count >= maxFiles { output.limitHit = true; break }
            }
        }
        paths = Array(Set(paths + buffers.keys)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var retainedBytes = 0
        for path in paths {
            if cancelled() { break }
            if !includes.isEmpty && !includes.matches(path) { continue }
            if excludes.matches(path) { continue }
            let url = root.appendingPathComponent(path).standardizedFileURL
            guard url.path.hasPrefix(root.path + "/"), url.resolvingSymlinksInPath() == url else { continue }
            let source: String
            if let buffer = buffers[path] {
                guard buffer.utf8.count <= maxFileBytes else { output.skipped += 1; continue }
                source = buffer
            }
            else {
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true,
                      (values.fileSize ?? maxFileBytes + 1) <= maxFileBytes,
                      let data = try? Data(contentsOf: url), data.count <= maxFileBytes, !data.contains(0),
                      let text = String(data: data, encoding: .utf8) else { output.skipped += 1; continue }
                source = text
            }
            let remaining = maxMatches - output.count
            let matches = find(in: source, expression: expression, limit: remaining + 1, cancelled: cancelled)
            if matches.isEmpty { continue }
            if remaining == 0 { output.limitHit = true; break }
            retainedBytes += source.utf8.count
            if retainedBytes > 32 * 1024 * 1024 { output.limitHit = true; break }
            output.files.append(WorkspaceSearchFile(url: url, path: path, source: source, matches: Array(matches.prefix(remaining))))
            if matches.count > remaining { output.limitHit = true; break }
        }
        return output
    }

    static func find(in source: String, expression: NSRegularExpression, limit: Int = maxMatches,
                     cancelled: () -> Bool = { false }) -> [WorkspaceSearchMatch] {
        let ns = source as NSString
        var results: [WorkspaceSearchMatch] = []
        var line = 1, lineStart = 0
        expression.enumerateMatches(in: source, options: [.reportProgress], range: NSRange(location: 0, length: ns.length)) { match, _, stop in
            if cancelled() || results.count >= limit { stop.pointee = true; return }
            guard let match else { return }
            let range = match.range
            while lineStart < range.location {
                let next = ns.range(of: "\n", range: NSRange(location: lineStart, length: ns.length - lineStart))
                if next.location == NSNotFound || next.location >= range.location { break }
                lineStart = NSMaxRange(next); line += 1
            }
            let end = ns.range(of: "\n", range: NSRange(location: range.location, length: ns.length - range.location))
            let lineEnd = end.location == NSNotFound ? ns.length : end.location
            // Use character boundaries when clipping previews containing emoji or non-BMP text.
            let rawStart = max(lineStart, range.location - 32)
            let start = rawStart < ns.length ? ns.rangeOfComposedCharacterSequence(at: rawStart).location : rawStart
            let rawEnd = min(lineEnd, max(range.location + min(range.length, 180), start + 220))
            let finish = rawEnd > start ? NSMaxRange(ns.rangeOfComposedCharacterSequence(at: rawEnd - 1)) : rawEnd
            let prefix = start > lineStart ? "…" : ""
            let preview = prefix + ns.substring(with: NSRange(location: start, length: finish - start)).replacingOccurrences(of: "\r", with: " ") + (finish < lineEnd ? "…" : "")
            results.append(WorkspaceSearchMatch(range: range, line: line, column: range.location - lineStart + 1, preview: preview,
                previewRange: NSRange(location: range.location - start + (prefix as NSString).length, length: min(range.length, finish - range.location))))
        }
        return results
    }

    static func replacing(_ file: WorkspaceSearchFile, matches: [WorkspaceSearchMatch], query: WorkspaceSearchQuery, replacement: String) throws -> String {
        let expression = try query.expression()
        let mutable = NSMutableString(string: file.source)
        for hit in matches.sorted(by: { $0.range.location > $1.range.location }) {
            guard let match = expression.firstMatch(in: file.source, options: [.withoutAnchoringBounds, .withTransparentBounds], range: hit.range), match.range == hit.range else { throw LocalFileError.changedOnDisk }
            let value = query.regex ? expression.replacementString(for: match, in: file.source, offset: 0, template: replacement) : replacement
            mutable.replaceCharacters(in: hit.range, with: value)
        }
        return mutable as String
    }

    private static func gitFiles(root: URL) -> [String]? {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path, "-c", "core.fsmonitor=false", "ls-files", "--cached", "--others", "--exclude-standard", "-z", "--", "."]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else { return nil }
        return text.split(separator: "\0").map(String.init)
    }
}

/// Comma-separated globs. Bare names match at any depth; paths are workspace-relative.
struct SearchPathFilter {
    private let expressions: [NSRegularExpression]
    var isEmpty: Bool { expressions.isEmpty }
    init(_ value: String) {
        expressions = value.split(separator: ",").compactMap { raw in
            var glob = raw.trimmingCharacters(in: .whitespaces)
            if glob.hasPrefix("./") { glob.removeFirst(2) }
            guard !glob.isEmpty else { return nil }
            let anyDepth = !glob.contains("/")
            if glob.hasSuffix("/") { glob.removeLast() }
            var pattern = anyDepth ? "(?:^|/)" : "^"
            let chars = Array(glob); var i = 0
            while i < chars.count {
                if chars[i] == "*" {
                    if i + 1 < chars.count && chars[i + 1] == "*" {
                        if i + 2 < chars.count && chars[i + 2] == "/" { pattern += "(?:.*/)?"; i += 3; continue }
                        pattern += ".*"; i += 2; continue
                    }
                    pattern += "[^/]*"
                } else if chars[i] == "?" { pattern += "[^/]" }
                else { pattern += NSRegularExpression.escapedPattern(for: String(chars[i])) }
                i += 1
            }
            return try? NSRegularExpression(pattern: pattern + "(?:/.*)?$")
        }
    }
    func matches(_ path: String) -> Bool { expressions.contains { $0.firstMatch(in: path, range: NSRange(location: 0, length: (path as NSString).length)) != nil } }
}

@MainActor
final class WorkspaceSearchModel: ObservableObject {
    @Published var query = WorkspaceSearchQuery() { didSet { if query != oldValue { schedule() } } }
    @Published var replacement = ""
    @Published var showReplace = false
    @Published var showFilters = false
    @Published var collapsed: Set<String> = []
    @Published private(set) var results = WorkspaceSearchResults()
    @Published private(set) var searching = false
    @Published private(set) var hasSearched = false
    @Published var error: String?
    @Published var focusRequest = UUID()
    @Published var selectedMatchID: String?
    private weak var files: FileWorkspaceModel?
    private var task: Task<Void, Never>?
    private var worker: Task<WorkspaceSearchResults, Error>?
    private var generation = UUID()
    private var subscription: AnyCancellable?
    private var observedBuffers: [String: String] = [:]
    private var observedDirtyPaths: Set<String> = []
    @Published private var replacementUndo: [(id: UUID, before: String, after: String)] = []
    private(set) var completedQuery: WorkspaceSearchQuery?

    init(files: FileWorkspaceModel) {
        self.files = files
        observedBuffers = Dictionary(uniqueKeysWithValues: files.documents.map { ($0.url.path, $0.text) })
        observedDirtyPaths = Set(files.documents.filter(\.isDirty).map { $0.url.path })
        subscription = files.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, let files = self.files else { return }
                let current = Dictionary(uniqueKeysWithValues: files.documents.map { ($0.url.path, $0.text) })
                let changed = files.documents.contains { document in
                    self.observedBuffers[document.url.path].map { $0 != document.text } ?? document.isDirty
                } || self.observedDirtyPaths.contains { current[$0] == nil }
                self.observedBuffers = current
                self.observedDirtyPaths = Set(files.documents.filter(\.isDirty).map { $0.url.path })
                if changed && !self.query.text.isEmpty { self.schedule() }
            }
        }
    }
    deinit { task?.cancel(); worker?.cancel() }
    func cancel() { generation = UUID(); task?.cancel(); worker?.cancel(); searching = false }
    func clear() { query.text = ""; results = WorkspaceSearchResults(); completedQuery = nil; hasSearched = false; error = nil }
    func schedule(immediate: Bool = false) {
        cancel(); error = nil; completedQuery = nil; selectedMatchID = nil
        guard !query.text.isEmpty else { results = WorkspaceSearchResults(); hasSearched = false; return }
        searching = true
        let request = generation, query = query
        task = Task { [weak self] in
            do {
                if !immediate { try await Task.sleep(for: .milliseconds(300)) }
                guard let self, let files = self.files, !Task.isCancelled else { return }
                let root = files.rootURL
                let buffers = Dictionary(uniqueKeysWithValues: files.documents.map { (files.relativePath($0.url), $0.text) })
                let worker = Task.detached(priority: .userInitiated) {
                    try WorkspaceSearchEngine.search(root: root, query: query, buffers: buffers, cancelled: { Task.isCancelled })
                }
                self.worker = worker
                let result = try await worker.value
                guard !Task.isCancelled, self.generation == request else { return }
                self.results = result; self.completedQuery = query; self.searching = false; self.hasSearched = true
            } catch {
                guard let self, self.generation == request, !Task.isCancelled else { return }
                self.results = WorkspaceSearchResults(); self.searching = false; self.hasSearched = true
                self.error = L("搜索失败：\(error.localizedDescription)")
            }
        }
    }
    func open(_ file: WorkspaceSearchFile, match: WorkspaceSearchMatch, keep: Bool = false) -> Bool {
        guard let files else { return false }
        files.open(file.url, preview: !keep)
        guard let document = files.selectedDocument, document.url == file.url else { return false }
        guard document.text == file.source else { schedule(immediate: true); error = L("文件内容已变化，请刷新搜索结果。"); return false }
        document.searchSelection = EditorSelectionRequest(range: match.range)
        selectedMatchID = file.id + ":" + String(match.id)
        return true
    }
    /// Replacements enter editor buffers and use the editor's existing save/conflict path.
    /// Opening every affected file also makes batch replacements reviewable before saving.
    @discardableResult func replace(file selectedFile: WorkspaceSearchFile? = nil, match: WorkspaceSearchMatch? = nil) -> Bool {
        guard let files, !searching, completedQuery == query else { return false }
        let targets = selectedFile.map { [$0] } ?? results.files
        guard !targets.isEmpty else { return false }
        do {
            var edits: [(WorkspaceSearchFile, String)] = []
            for file in targets {
                let current: String
                if let document = files.documents.first(where: { $0.url == file.url }) { current = document.text }
                else {
                    guard file.url.resolvingSymlinksInPath() == file.url, file.url.path.hasPrefix(files.rootURL.path + "/") else { throw LocalFileError.symbolicLink }
                    current = try String(contentsOf: file.url, encoding: .utf8)
                }
                guard current == file.source else { throw LocalFileError.changedOnDisk }
                let hits = match.map { [$0] } ?? file.matches
                edits.append((file, try WorkspaceSearchEngine.replacing(file, matches: hits, query: query, replacement: replacement)))
            }
            // Load all destinations before changing any buffer. An unreadable file aborts the batch.
            for (file, _) in edits {
                files.open(file.url, preview: false)
                guard files.selectedDocument?.url == file.url, files.selectedDocument?.text == file.source else { throw LocalFileError.changedOnDisk }
            }
            replacementUndo = []
            for (file, text) in edits {
                if let document = files.documents.first(where: { $0.url == file.url }) {
                    replacementUndo.append((document.id, document.text, text))
                    files.update(document, text: text)
                }
            }
            schedule(immediate: true); return true
        } catch { self.error = L("替换失败：\(error.localizedDescription)"); return false }
    }
    var canUndoReplacement: Bool {
        guard let files, !replacementUndo.isEmpty else { return false }
        return replacementUndo.allSatisfy { edit in files.documents.contains { $0.id == edit.id && $0.text == edit.after } }
    }
    func undoReplacement() {
        guard let files, canUndoReplacement else { return }
        for edit in replacementUndo {
            if let document = files.documents.first(where: { $0.id == edit.id }) { files.update(document, text: edit.before) }
        }
        replacementUndo = []; schedule(immediate: true)
    }
}

struct EditorSelectionRequest: Equatable {
    let id = UUID()
    let range: NSRange
}
