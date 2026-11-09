import AppKit
import SwiftUI

struct QuickOpenResult: Identifiable, Equatable, Sendable {
    var id: String { url.path }
    let url: URL
    let path: String
    let recent: Bool
}

enum QuickOpenEngine {
    static let maxFiles = 20_000
    static let maxResults = 100
    static let excludedDirectories: Set<String> = [".git", ".hg", ".svn", "node_modules", ".build"]

    static func files(root: URL, limit: Int = maxFiles) -> [URL] {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let paths = gitFiles(root: root, limit: limit) ?? enumeratedFiles(root: root, limit: limit)
        return paths.compactMap { path in
            let url = root.appendingPathComponent(path).standardizedFileURL
            guard url.path.hasPrefix(root.path + "/"), url.resolvingSymlinksInPath() == url,
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey]), values.isRegularFile == true else { return nil }
            return url
        }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    static func search(query: String, root: URL, candidates: [URL], recentPaths: [String], limit: Int = maxResults) -> [QuickOpenResult] {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let recent = Dictionary(recentPaths.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if needle.isEmpty {
            let recentURLs = recentPaths.compactMap { path -> URL? in
                let url = root.appendingPathComponent(path).standardizedFileURL
                return candidates.contains(where: { $0.path == url.path }) ? url : nil
            }
            return recentURLs.prefix(limit).map { QuickOpenResult(url: $0, path: relativePath($0, rootPath: rootPath), recent: true) }
        }

        return candidates.compactMap { url -> (QuickOpenResult, Int)? in
            let path = relativePath(url, rootPath: rootPath)
            let basenameScore = fuzzyScore(needle, in: url.lastPathComponent)
            let pathScore = fuzzyScore(needle, in: path)
            guard let score = basenameScore ?? pathScore else { return nil }
            let recentIndex = recent[path]
            let filenameWeight = basenameScore == nil ? 0 : 1_000
            let recentWeight = recentIndex.map { max(0, 20 - $0) } ?? 0
            return (QuickOpenResult(url: url, path: path, recent: recentIndex != nil), filenameWeight + score + recentWeight)
        }
        .sorted { left, right in
            if left.1 != right.1 { return left.1 > right.1 }
            return left.0.path.localizedStandardCompare(right.0.path) == .orderedAscending
        }
        .prefix(limit)
        .map(\.0)
    }

    private static func relativePath(_ url: URL, rootPath: String) -> String {
        url.path.hasPrefix(rootPath + "/") ? String(url.path.dropFirst(rootPath.count + 1)) : url.lastPathComponent
    }

    private static func fuzzyScore(_ query: String, in candidate: String) -> Int? {
        let wanted = Array(query.lowercased())
        let chars = Array(candidate)
        guard !wanted.isEmpty else { return 0 }
        var cursor = 0
        var previous = -2
        var score = 0
        var gaps = 0
        for character in wanted {
            guard let index = chars.indices.dropFirst(cursor).first(where: { String(chars[$0]).lowercased() == String(character) }) else { return nil }
            let atBoundary = index == 0 || "/\\._- \t".contains(chars[index - 1]) || (chars[index].isUppercase && !chars[index - 1].isUppercase)
            if index == previous + 1 { score += 18 }
            if atBoundary { score += 12 }
            if index == cursor { score += 5 }
            gaps += max(0, index - cursor)
            previous = index
            cursor = index + 1
        }
        return score - gaps
    }

    private static func gitFiles(root: URL, limit: Int) -> [String]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path, "-c", "core.fsmonitor=false", "ls-files", "--cached", "--others", "--exclude-standard", "-z", "--", "."]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else { return nil }
        return Array(text.split(separator: "\0").prefix(limit)).map(String.init)
    }

    private static func enumeratedFiles(root: URL, limit: Int) -> [String] {
        guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return [] }
        var paths: [String] = []
        for case let url as URL in iterator {
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { continue }
            if values.isSymbolicLink == true { iterator.skipDescendants(); continue }
            if values.isDirectory == true {
                if excludedDirectories.contains(url.lastPathComponent) { iterator.skipDescendants() }
                continue
            }
            let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
            guard resolved.path.hasPrefix(root.path + "/") else { continue }
            paths.append(String(resolved.path.dropFirst(root.path.count + 1)))
            if paths.count >= limit { break }
        }
        return paths
    }
}

struct QuickOpenPanel: View {
    @ObservedObject private var languagePreferences = LanguagePreferences.shared
    @ObservedObject var files: FileWorkspaceModel
    var onOpen: () -> Void
    var onDismiss: () -> Void
    @State private var query = ""
    @State private var candidates: [URL] = []
    @State private var results: [QuickOpenResult] = []
    @State private var selectedIndex = 0
    @State private var scanTask: Task<Void, Never>?
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var inputFocused: Bool

    var body: some View {
        let _ = languagePreferences.language
        VStack(spacing: 0) {
            TextField(L("转到文件"), text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .padding(.horizontal, 11)
                .frame(height: 40)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(inputFocused ? Color.accentColor : Color(nsColor: .separatorColor)) }
                .focused($inputFocused)
                .onSubmit(openSelected)
                .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
                .onKeyPress(.downArrow) { moveSelection(1); return .handled }
                .onKeyPress(.escape) { onDismiss(); return .handled }
                .accessibilityIdentifier("quick-open-input")
                .padding(10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                            QuickOpenRow(result: result, selected: index == selectedIndex, showRecent: query.isEmpty && result.recent) {
                                selectedIndex = index
                                openSelected()
                            }.id(result.id)
                        }
                        if results.isEmpty {
                            Text(candidates.isEmpty ? L("正在读取文件…") : L("未找到文件"))
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 54)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: selectedIndex) { _, index in
                    guard results.indices.contains(index) else { return }
                    proxy.scrollTo(results[index].id, anchor: .center)
                }
            }
        }
        .frame(width: 680, height: min(590, max(180, CGFloat(results.count) * 30 + 70)))
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor).opacity(0.8)) }
        .shadow(color: .black.opacity(0.28), radius: 20, y: 8)
        .onAppear {
            inputFocused = true
            loadCandidates()
            updateResults()
        }
        .onChange(of: query) { _, _ in updateResults() }
        .onDisappear { scanTask?.cancel(); searchTask?.cancel() }
    }

    private func loadCandidates() {
        scanTask?.cancel()
        let root = files.rootURL
        scanTask = Task {
            let found = await Task.detached(priority: .userInitiated) { QuickOpenEngine.files(root: root) }.value
            guard !Task.isCancelled else { return }
            candidates = found
            updateResults()
        }
    }

    private func updateResults() {
        searchTask?.cancel()
        let root = files.rootURL
        let candidates = Array(Set(candidates + files.documents.map(\.url)))
        let query = query
        let recent = files.documents.reversed().map { files.relativePath($0.url) }
        searchTask = Task {
            let found = await Task.detached(priority: .userInitiated) {
                QuickOpenEngine.search(query: query, root: root, candidates: candidates, recentPaths: recent)
            }.value
            guard !Task.isCancelled else { return }
            results = found
            selectedIndex = 0
        }
    }

    private func moveSelection(_ distance: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = (selectedIndex + distance + results.count) % results.count
    }

    private func openSelected() {
        guard results.indices.contains(selectedIndex) else { return }
        let url = results[selectedIndex].url
        files.open(url, preview: false)
        guard files.selectedDocument?.url == url else { return }
        onOpen()
    }

    private func fileSymbol(_ url: URL) -> String {
        switch CodeLanguage.forFile(url) {
        case .markdown: return "doc.richtext"
        case .json, .yaml: return "curlybraces"
        case .plain: return "doc"
        default: return "chevron.left.forwardslash.chevron.right"
        }
    }
}

private struct QuickOpenRow: View {
    let result: QuickOpenResult
    let selected: Bool
    let showRecent: Bool
    let action: () -> Void

    var body: some View {
        let parentPath = result.url.deletingLastPathComponent().lastPathComponent == result.url.lastPathComponent
            ? "" : result.path.split(separator: "/").dropLast().joined(separator: "/")
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: fileSymbol(result.url)).foregroundStyle(.secondary).frame(width: 16)
                Text(result.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                Text(parentPath).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                if showRecent { Text(L("最近打开")).font(.system(size: 10)).foregroundStyle(.tertiary) }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .frame(height: 29)
            .background(selected ? Color.accentColor.opacity(0.28) : .clear, in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help(result.path)
    }

    private func fileSymbol(_ url: URL) -> String {
        switch CodeLanguage.forFile(url) {
        case .markdown: return "doc.richtext"
        case .json, .yaml: return "curlybraces"
        case .plain: return "doc"
        default: return "chevron.left.forwardslash.chevron.right"
        }
    }
}
