import AppKit
import Combine
import Foundation

struct FileTreeItem: Identifiable, Equatable {
    var id: String { url.path }
    let url: URL
    let isDirectory: Bool
    let isSymbolicLink: Bool
    var name: String { url.lastPathComponent }
}

struct FileTreeRow: Identifiable {
    var id: String { item.id }
    let item: FileTreeItem
    let depth: Int
}

enum LocalFileError: LocalizedError {
    case invalidName, outsideRoot, symbolicLink, tooLarge, binary, unsaved, changedOnDisk
    var errorDescription: String? {
        switch self {
        case .invalidName: return L("名称不能为空，且不能包含 /、换行或使用 .、..。")
        case .outsideRoot: return L("此操作仅允许在当前工作区目录内进行。")
        case .symbolicLink: return L("为避免修改链接目标，请在 Finder 中打开此符号链接。")
        case .tooLarge: return L("文件超过 4 MB，请使用外部编辑器打开。")
        case .binary: return L("此文件不是 UTF-8 文本，无法在代码编辑器中打开。")
        case .unsaved: return L("文件有未保存的更改，请先保存或关闭该文件。")
        case .changedOnDisk: return L("文件已被其他程序修改。请重新载入，或明确选择覆盖磁盘文件。")
        }
    }
}

@MainActor
final class LocalFileDocument: ObservableObject, Identifiable {
    let id = UUID()
    @Published var url: URL { didSet { if url != oldValue { onSessionChange?() } } }
    @Published var text: String
    @Published var savedText: String
    @Published var isPreview: Bool { didSet { if isPreview != oldValue { onSessionChange?() } } }
    @Published var externalChange = false
    @Published var markdownPreview = false { didSet { if markdownPreview != oldValue { onSessionChange?() } } }
    @Published var markdownAnchor: String?
    @Published var searchSelection: EditorSelectionRequest?
    @Published var findRequest: UUID?
    let findSession = EditorFindSession()
    var diskData: Data
    var onSessionChange: (() -> Void)?
    var isDirty: Bool { text != savedText }
    var language: CodeLanguage { CodeLanguage.forFile(url, firstLine: String(text.prefix(512).prefix(while: { !$0.isNewline }))) }

    init(url: URL, text: String, data: Data, isPreview: Bool) {
        self.url = url; self.text = text; savedText = text; diskData = data; self.isPreview = isPreview
    }
}

/// A local, workspace-scoped file service. Opening never launches executable file contents.
@MainActor
final class FileWorkspaceModel: ObservableObject {
    let rootURL: URL
    @Published var children: [String: [FileTreeItem]] = [:]
    @Published var expandedPaths: Set<String> = []
    @Published var selectedPath: String?
    @Published var documents: [LocalFileDocument] = [] { didSet { onSessionChange?() } }
    @Published var selectedDocumentID: UUID? {
        didSet {
            selectedPath = selectedDocument?.url.path
            if selectedDocumentID != oldValue { onSessionChange?() }
        }
    }
    @Published var showHidden = true { didSet { refresh() } }
    @Published var filter = ""
    @Published var error: String?
    private var documentObservers: [UUID: AnyCancellable] = [:]
    private var refreshTimer: Timer?
    let fileManager: FileManager
    var onSessionChange: (() -> Void)?

    init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        self.fileManager = fileManager
        expandedPaths = [self.rootURL.path]
        loadChildren(self.rootURL)
    }
    lazy var search = WorkspaceSearchModel(files: self)
    deinit { refreshTimer?.invalidate() }
    var selectedDocument: LocalFileDocument? { documents.first { $0.id == selectedDocumentID } }
    var rows: [FileTreeRow] {
        func flatten(_ directory: URL, depth: Int) -> [FileTreeRow] {
            (children[directory.path] ?? []).flatMap { item -> [FileTreeRow] in
                let row = FileTreeRow(item: item, depth: depth)
                let descendants = item.isDirectory && expandedPaths.contains(item.id) ? flatten(item.url, depth: depth + 1) : []
                guard !filter.isEmpty else { return [row] + descendants }
                let matches = relativePath(item.url).localizedCaseInsensitiveContains(filter)
                if item.isDirectory { return matches || !descendants.isEmpty ? [row] + descendants : [] }
                return matches ? [row] : []
            }
        }
        return flatten(rootURL, depth: 0)
    }
    func startWatching() {
        guard refreshTimer == nil else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }
    func stopWatching() { refreshTimer?.invalidate(); refreshTimer = nil }
    func toggle(_ item: FileTreeItem) {
        guard item.isDirectory, !item.isSymbolicLink else { return }
        if expandedPaths.remove(item.id) == nil { expandedPaths.insert(item.id); loadChildren(item.url) }
    }
    func collapseAll() { expandedPaths = [rootURL.path] }
    func refresh() {
        for path in expandedPaths { loadChildren(URL(fileURLWithPath: path)) }
        for document in documents { checkExternalChange(document) }
    }
    func loadChildren(_ directory: URL) {
        do {
            let urls = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: showHidden ? [] : [.skipsHiddenFiles])
            let items = try urls.map { url -> FileTreeItem in
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                return FileTreeItem(url: url.standardizedFileURL, isDirectory: values.isDirectory == true, isSymbolicLink: values.isSymbolicLink == true)
            }.sorted { left, right in
                if left.isDirectory != right.isDirectory { return left.isDirectory }
                return left.name.localizedStandardCompare(right.name) == .orderedAscending
            }
            if children[directory.path] != items { children[directory.path] = items }
        } catch { self.error = L("无法读取目录：\(error.localizedDescription)") }
    }
    func open(_ url: URL, preview: Bool = true) {
        do {
            let url = try checked(url)
            if let current = documents.first(where: { $0.url == url }) {
                if !preview { current.isPreview = false }
                selectedDocumentID = current.id; selectedPath = url.path; return
            }
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw LocalFileError.symbolicLink }
            guard (values.fileSize ?? 0) <= 4 * 1024 * 1024 else { throw LocalFileError.tooLarge }
            let data = try Data(contentsOf: url)
            guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { throw LocalFileError.binary }
            let document = LocalFileDocument(url: url, text: text, data: data, isPreview: preview)
            document.onSessionChange = { [weak self] in self?.onSessionChange?() }
            if let previous = documents.first(where: { $0.isPreview && !$0.isDirty }) {
                documentObservers[previous.id] = nil; documents.removeAll { $0.id == previous.id }
            }
            documents.append(document); selectedDocumentID = document.id; selectedPath = url.path
            documentObservers[document.id] = document.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        } catch { self.error = L("打开失败：\(error.localizedDescription)") }
    }
    func update(_ document: LocalFileDocument, text: String) {
        document.text = text
        if document.isDirty { document.isPreview = false }
    }
    func saveSelected() { guard let document = selectedDocument else { return }; save(document) }
    @discardableResult
    func save(_ document: LocalFileDocument, overwrite: Bool = false) -> Bool {
        do {
            _ = try checked(document.url)
            let disk = try Data(contentsOf: document.url)
            guard overwrite || disk == document.diskData else { document.externalChange = true; throw LocalFileError.changedOnDisk }
            let data = Data(document.text.utf8)
            try data.write(to: document.url, options: .atomic)
            document.savedText = document.text; document.diskData = data; document.externalChange = false; document.isPreview = false
            return true
        } catch { self.error = L("保存失败：\(error.localizedDescription)"); return false }
    }
    func reload(_ document: LocalFileDocument) {
        do {
            let data = try Data(contentsOf: try checked(document.url))
            guard data.count <= 4 * 1024 * 1024, !data.contains(0), let text = String(data: data, encoding: .utf8) else { throw LocalFileError.binary }
            document.text = text; document.savedText = text; document.diskData = data; document.externalChange = false
        } catch { self.error = L("重新载入失败：\(error.localizedDescription)") }
    }
    func checkExternalChange(_ document: LocalFileDocument) {
        guard let data = try? Data(contentsOf: document.url), data != document.diskData else { return }
        if !document.isDirty { reload(document) } else { document.externalChange = true }
    }
    func close(_ document: LocalFileDocument, discard: Bool = false) -> Bool {
        guard discard || !document.isDirty else { return false }
        let index = documents.firstIndex { $0.id == document.id } ?? 0
        documents.removeAll { $0.id == document.id }; documentObservers[document.id] = nil
        if selectedDocumentID == document.id { selectedDocumentID = documents.isEmpty ? nil : documents[min(index, documents.count - 1)].id }
        return true
    }
    func closeWithPrompt(_ document: LocalFileDocument) {
        if document.isDirty {
            let alert = NSAlert(); alert.messageText = L("保存对“\(document.url.lastPathComponent)”的更改？"); alert.informativeText = L("关闭前未保存的更改将丢失。")
            alert.addButton(withTitle: L("保存")); alert.addButton(withTitle: L("不保存")); alert.addButton(withTitle: L("取消"))
            switch alert.runModal() {
            case .alertFirstButtonReturn: guard save(document) else { return }
            case .alertSecondButtonReturn: break
            default: return
            }
        }
        _ = close(document, discard: true)
    }
    @discardableResult
    func create(name: String, directory: Bool, in parent: URL? = nil) throws -> URL {
        let name = try checkedName(name)
        let parent = try checked(parent ?? rootURL)
        let url = parent.appendingPathComponent(name, isDirectory: directory)
        if directory { try fileManager.createDirectory(at: url, withIntermediateDirectories: false) }
        else { try Data().write(to: url, options: .withoutOverwriting) }
        expandedPaths.insert(parent.path); loadChildren(parent)
        if !directory { open(url, preview: false) }
        return url
    }
    func rename(_ item: FileTreeItem, to name: String) throws {
        let source = try checked(item.url)
        let destination = source.deletingLastPathComponent().appendingPathComponent(try checkedName(name), isDirectory: item.isDirectory)
        if source == destination { return }
        try fileManager.moveItem(at: source, to: destination)
        for document in documents where document.url.path == source.path || document.url.path.hasPrefix(source.path + "/") {
            let suffix = String(document.url.path.dropFirst(source.path.count))
            document.url = URL(fileURLWithPath: destination.path + suffix)
        }
        expandedPaths = Set(expandedPaths.map { $0 == source.path || $0.hasPrefix(source.path + "/") ? destination.path + $0.dropFirst(source.path.count) : $0 })
        children = children.filter { $0.key != source.path && !$0.key.hasPrefix(source.path + "/") }
        refresh()
    }
    func trash(_ item: FileTreeItem) throws {
        let url = try checked(item.url, permitSymlink: true)
        let affected = documents.filter { $0.url.path == url.path || $0.url.path.hasPrefix(url.path + "/") }
        guard !affected.contains(where: \.isDirty) else { throw LocalFileError.unsaved }
        try fileManager.trashItem(at: url, resultingItemURL: nil)
        for document in affected { _ = close(document) }
        expandedPaths = Set(expandedPaths.filter { $0 != url.path && !$0.hasPrefix(url.path + "/") })
        refresh()
    }
    func relativePath(_ url: URL) -> String {
        let path = url.path
        return path.hasPrefix(rootURL.path + "/") ? String(path.dropFirst(rootURL.path.count + 1)) : url.lastPathComponent
    }
    private func checkedName(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\n"), !name.contains("\r"), !name.contains("\0") else { throw LocalFileError.invalidName }
        return name
    }
    private func checked(_ url: URL, permitSymlink: Bool = false) throws -> URL {
        let normalized = url.standardizedFileURL
        guard normalized.path == rootURL.path || normalized.path.hasPrefix(rootURL.path + "/") else { throw LocalFileError.outsideRoot }
        if !permitSymlink {
            let resolved = normalized.resolvingSymlinksInPath()
            guard resolved == normalized else { throw LocalFileError.symbolicLink }
        }
        return normalized
    }
}
