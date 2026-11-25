import AppKit
import SwiftUI

struct FileExplorerView: View {
    @ObservedObject private var languagePreferences = LanguagePreferences.shared
    @ObservedObject var model: FileWorkspaceModel
    var onOpen: () -> Void = {}
    var onSearch: () -> Void = {}
    @State private var indexedFiles: [URL] = []
    @State private var filteredFiles: [QuickOpenResult] = []
    @State private var indexingFiles = false
    @State private var indexTask: Task<Void, Never>?
    @State private var filterTask: Task<Void, Never>?
    var body: some View {
        let _ = languagePreferences.language
        let rows = model.filter.isEmpty ? model.rows : []
        let items = model.filter.isEmpty ? rows.map(\.item) : filteredFiles.map(filteredItem)
        let selection = items.filter { model.selectedPaths.contains($0.id) }
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                Text(L("文件")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                IconButton(symbol: "magnifyingglass", help: L("在文件中搜索…"), action: onSearch)
                IconButton(symbol: "doc.badge.plus", help: L("新建文件")) { create(directory: false) }
                IconButton(symbol: "folder.badge.plus", help: L("新建文件夹")) { create(directory: true) }
                IconButton(symbol: "arrow.clockwise", help: L("刷新文件树")) { model.refresh() }
                Menu {
                    Toggle(L("显示隐藏文件"), isOn: $model.showHidden)
                    Button(L("折叠所有文件夹")) { model.collapseAll() }
                    Button(L("在 Finder 中显示工作区")) { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: model.rootURL.path) }
                    Divider()
                    trashButton(selection).disabled(selection.isEmpty)
                } label: { Image(systemName: "ellipsis").frame(width: 19) }.menuStyle(.borderlessButton).pointingHandCursor().fixedSize().help(L("文件操作"))
            }.padding(.leading, 12).padding(.trailing, 6).frame(height: 38)
            HStack(spacing: 5) {
                Image(systemName: "folder.fill").foregroundStyle(.secondary)
                Text(model.rootURL.lastPathComponent.isEmpty ? model.rootURL.path : model.rootURL.lastPathComponent).fontWeight(.semibold).lineLimit(1)
                Spacer(minLength: 0)
            }.font(.system(size: 11)).padding(.horizontal, 12).frame(height: 27).help(model.rootURL.path)
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField(L("筛选文件名"), text: $model.filter).textFieldStyle(.plain)
                    .accessibilityIdentifier("file-tree-filter")
                if !model.filter.isEmpty {
                    Button { model.filter = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)) }
                        .buttonStyle(.plain).foregroundStyle(.tertiary).help(L("清除筛选"))
                }
            }
            .font(.system(size: 11)).padding(.horizontal, 8).frame(height: 27)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 4))
            .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(Color(nsColor: .separatorColor)) }
            .padding(.horizontal, 9).padding(.bottom, 5)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if model.filter.isEmpty {
                        ForEach(rows) { row in fileRow(row, items: items, selection: selection) }
                        if rows.isEmpty {
                            Text(L("此目录为空")).font(.system(size: 12)).foregroundStyle(.tertiary).padding(16)
                        }
                    } else {
                        ForEach(filteredFiles) { result in filteredFileRow(result, items: items, selection: selection) }
                        if filteredFiles.isEmpty {
                            Text(indexingFiles ? L("正在读取文件…") : L("未找到文件"))
                                .font(.system(size: 12)).foregroundStyle(.tertiary).padding(16)
                        }
                    }
                }.padding(.vertical, 5)
            }.contextMenu {
                Button(L("新建文件…")) { create(directory: false) }
                Button(L("新建文件夹…")) { create(directory: true) }
                Button(L("刷新")) { model.refresh() }
            }
            FileErrorBanner(model: model)
        }.background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            .onAppear { model.refresh(); model.startWatching(); loadFileIndex() }
            .onChange(of: model.filter) { _, _ in
                filteredFiles = []
                updateFilteredFiles()
            }
            .onDisappear { model.stopWatching(); indexTask?.cancel(); filterTask?.cancel() }
    }
    private func loadFileIndex() {
        indexTask?.cancel()
        filterTask?.cancel()
        indexingFiles = true
        let root = model.rootURL
        indexTask = Task {
            let files = await Task.detached(priority: .userInitiated) { QuickOpenEngine.files(root: root) }.value
            guard !Task.isCancelled else { return }
            indexedFiles = files
            indexingFiles = false
            updateFilteredFiles()
        }
    }
    private func updateFilteredFiles() {
        filterTask?.cancel()
        guard !model.filter.isEmpty else { filteredFiles = []; return }
        let root = model.rootURL
        let candidates = indexedFiles
        let query = model.filter
        filterTask = Task {
            let results = await Task.detached(priority: .userInitiated) {
                QuickOpenEngine.search(query: query, root: root, candidates: candidates, recentPaths: [])
            }.value
            guard !Task.isCancelled else { return }
            filteredFiles = results
        }
    }
    private func filteredItem(_ result: QuickOpenResult) -> FileTreeItem {
        FileTreeItem(url: result.url, isDirectory: false, isSymbolicLink: false)
    }
    private func filteredFileRow(_ result: QuickOpenResult, items: [FileTreeItem], selection: [FileTreeItem]) -> some View {
        let item = filteredItem(result)
        return HStack(spacing: 5) {
            Image(systemName: fileIcon(result.url)).foregroundStyle(fileColor(result.url)).font(.system(size: 12)).frame(width: 14)
            Text(result.url.lastPathComponent).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
            Text((result.path as NSString).deletingLastPathComponent).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }.padding(.leading, 10).padding(.trailing, 10).frame(height: 25)
            .background(model.selectedPaths.contains(item.id) ? Color.accentColor.opacity(0.13) : .clear)
            .contentShape(Rectangle()).pointingHandCursor().help(result.path)
            .overlay { FileRowClick { event in
                click(item, in: items, event: event) { openFilteredFile(result.url, preview: event.clickCount < 2) }
            }.accessibilityHidden(true) }
            .accessibilityAddTraits(model.selectedPaths.contains(item.id) ? .isSelected : [])
            .accessibilityAction { openFilteredFile(result.url, preview: true) }
            .contextMenu {
                let targets = menuSelection(for: item, selection: selection)
                if targets.count == 1 {
                    Button(L("打开并保留")) { openFilteredFile(result.url, preview: false) }
                    Divider()
                }
                trashButton(targets)
            }
    }
    private func openFilteredFile(_ url: URL, preview: Bool) {
        model.open(url, preview: preview)
        if model.selectedDocument?.url == url { onOpen() }
    }
    private func fileRow(_ row: FileTreeRow, items: [FileTreeItem], selection: [FileTreeItem]) -> some View {
        let item = row.item
        return HStack(spacing: 5) {
            if item.isDirectory {
                Image(systemName: model.expandedPaths.contains(item.id) ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .semibold)).frame(width: 10)
            } else { Color.clear.frame(width: 10, height: 1) }
            Image(systemName: item.isSymbolicLink ? "link" : item.isDirectory ? (model.expandedPaths.contains(item.id) ? "folder.fill" : "folder") : fileIcon(item.url))
                .foregroundStyle(item.isDirectory ? Color.secondary : fileColor(item.url)).font(.system(size: 12)).frame(width: 14)
            Text(item.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }.padding(.leading, CGFloat(10 + row.depth * 14)).padding(.trailing, 10).frame(height: 25)
            .background(model.selectedPaths.contains(item.id) ? Color.accentColor.opacity(0.13) : .clear)
            .contentShape(Rectangle()).pointingHandCursor().help(item.url.path)
            .overlay { FileRowClick { event in
                click(item, in: items, event: event) { activate(item, preview: event.clickCount < 2) }
            }.accessibilityHidden(true) }
            .accessibilityElement(children: .combine).accessibilityLabel(item.name + (item.isDirectory ? L("，文件夹") : L("，文件")))
            .accessibilityAddTraits(model.selectedPaths.contains(item.id) ? .isSelected : [])
            .accessibilityAction { activate(item, preview: true) }
            .contextMenu {
                let targets = menuSelection(for: item, selection: selection)
                if targets.count == 1 {
                    if item.isDirectory && !item.isSymbolicLink {
                        Button(L("新建文件…")) { create(directory: false, parent: item.url) }
                        Button(L("新建文件夹…")) { create(directory: true, parent: item.url) }
                        Divider()
                    } else if !item.isSymbolicLink {
                        Button(L("打开并保留")) { model.open(item.url, preview: false); onOpen() }
                    }
                    Button(L("重命名…")) { rename(item) }
                    Button(L("在 Finder 中显示")) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                    Button(L("复制路径")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(item.url.path, forType: .string) }
                    Divider()
                }
                trashButton(targets)
            }
    }
    private func click(_ item: FileTreeItem, in items: [FileTreeItem], event: NSEvent, activate: () -> Void) {
        let modifiers = event.modifierFlags
        guard event.clickCount == 1 || modifiers.intersection([.command, .shift]).isEmpty else { return }
        if modifiers.contains(.shift) {
            model.selectPath(item.id, extending: true, toggling: modifiers.contains(.command), visiblePaths: items.map(\.id))
        } else if modifiers.contains(.command) {
            model.selectPath(item.id, toggling: true)
        } else {
            activate()
        }
    }
    private func menuSelection(for item: FileTreeItem, selection: [FileTreeItem]) -> [FileTreeItem] {
        model.selectedPaths.contains(item.id) ? selection : [item]
    }
    private func activate(_ item: FileTreeItem, preview: Bool) {
        model.selectPath(item.id)
        if item.isSymbolicLink { model.error = LocalFileError.symbolicLink.localizedDescription; return }
        if item.isDirectory {
            if preview { model.toggle(item) }
        } else { model.open(item.url, preview: preview); if model.selectedDocument != nil { onOpen() } }
    }
    private func create(directory: Bool, parent: URL? = nil) {
        var target = parent
        if target == nil, let path = model.selectedPath, let item = model.children.values.flatMap({ $0 }).first(where: { $0.id == path }) {
            target = item.isDirectory ? item.url : item.url.deletingLastPathComponent()
        }
        guard let name = askText(title: directory ? L("新建文件夹") : L("新建文件"), value: "") else { return }
        do { try model.create(name: name, directory: directory, in: target); if !directory { onOpen() } }
        catch { model.error = error.localizedDescription }
    }
    private func rename(_ item: FileTreeItem) {
        guard let name = askText(title: L("重命名"), value: item.name) else { return }
        do { try model.rename(item, to: name) } catch { model.error = error.localizedDescription }
    }
    private func trashButton(_ items: [FileTreeItem]) -> some View {
        Button(L("移到废纸篓…"), role: .destructive) { trash(items) }
    }
    private func trash(_ items: [FileTreeItem]) {
        guard let first = items.first else { return }
        let title = items.count == 1 ? L("将“\(first.name)”移到废纸篓？") : L("将所选的 \(items.count) 项移到废纸篓？")
        let detail = items.count == 1
            ? (first.isDirectory ? L("文件夹及其内容将移到 macOS 废纸篓。") : L("可在 macOS 废纸篓中恢复此文件。"))
            : L("所选文件和文件夹可在 macOS 废纸篓中恢复。")
        guard confirm(title: title, detail: detail, action: L("移到废纸篓")) else { return }
        do { try model.trash(items) } catch { model.error = error.localizedDescription }
        filteredFiles.removeAll { !model.fileManager.fileExists(atPath: $0.url.path) }
        loadFileIndex()
    }
    private func fileIcon(_ url: URL) -> String {
        switch CodeLanguage.forFile(url) {
        case .markdown: return "doc.richtext"
        case .json, .yaml: return "curlybraces"
        case .plain: return "doc"
        default: return "chevron.left.forwardslash.chevron.right"
        }
    }
    private func fileColor(_ url: URL) -> Color {
        switch CodeLanguage.forFile(url) {
        case .swift: return .orange
        case .typescript, .javascript: return .blue
        case .json, .yaml: return .secondary
        case .python: return .yellow
        case .shell: return .green
        default: return .secondary
        }
    }
}

private struct FileRowClick: NSViewRepresentable {
    let action: (NSEvent) -> Void

    func makeNSView(context: Context) -> ClickView { ClickView() }
    func updateNSView(_ view: ClickView, context: Context) { view.action = action }

    final class ClickView: NSView {
        var action: ((NSEvent) -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            // Leave other mouse events to SwiftUI, including the context menu.
            guard NSApp.currentEvent?.type == .leftMouseDown,
                  NSApp.currentEvent?.modifierFlags.contains(.control) != true else { return nil }
            return super.hitTest(point)
        }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {}
        override func mouseUp(with event: NSEvent) {
            if bounds.contains(convert(event.locationInWindow, from: nil)) { action?(event) }
        }
    }
}

struct FileEditorArea: View {
    @ObservedObject private var languagePreferences = LanguagePreferences.shared
    @ObservedObject private var shortcuts = ShortcutPreferences.shared
    @ObservedObject var model: FileWorkspaceModel
    @State private var line = 1
    @State private var column = 1
    var body: some View {
        let _ = languagePreferences.language
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) { ForEach(model.documents) { document in FileDocumentTab(model: model, document: document) } }
                }
                IconButton(symbol: "square.and.arrow.down", help: L("保存当前文件（\(shortcuts.binding(for: .saveFile).display)）")) { model.saveSelected() }.padding(.horizontal, 7).disabled(model.selectedDocument == nil)
            }.frame(height: 38).background(.bar)
            Divider()
            if let document = model.selectedDocument {
                HStack(spacing: 5) {
                    Image(systemName: "folder").foregroundStyle(.tertiary)
                    Text(model.relativePath(document.url)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if document.isDirty { Text(L("未保存")).foregroundStyle(.secondary) }
                    if document.language == .markdown {
                        if document.markdownPreview {
                            MarkdownPreviewControls(document: document).padding(.trailing, 8)
                        }
                        Button { document.markdownPreview.toggle() } label: {
                            Label(document.markdownPreview ? L("关闭预览") : L("侧边预览"), systemImage: "rectangle.split.2x1")
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).pointingHandCursor()
                            .help(L("在右侧打开或关闭 Markdown 预览（\(shortcuts.binding(for: .markdownPreview).display)）"))
                    }
                }.font(.system(size: 11)).padding(.horizontal, 13).frame(height: 28)
                Divider()
                if document.externalChange {
                    HStack {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        Text(L("磁盘文件已更改，当前编辑内容已保留。"))
                        Spacer()
                        Button(L("重新载入")) {
                            if !document.isDirty || confirm(title: L("放弃未保存的编辑？"), detail: L("将使用磁盘上的文件内容。"), action: L("重新载入")) { model.reload(document) }
                        }.pointingHandCursor()
                        Button(L("覆盖磁盘")) {
                            if confirm(title: L("覆盖磁盘文件？"), detail: L("其他程序保存的更改将被当前内容替换。"), action: L("覆盖")) { _ = model.save(document, overwrite: true) }
                        }.pointingHandCursor()
                    }.font(.system(size: 11)).padding(8).background(Color.orange.opacity(0.1))
                    Divider()
                }
                MarkdownEditorPane(model: model, document: document, onSelection: { line = $0; column = $1 }).id(document.id)
                Divider()
                HStack(spacing: 15) {
                    if document.language == .markdown && document.markdownPreview && document.markdownPreviewOnly {
                        Text(L("仅预览"))
                    } else {
                        Text(L("行 \(line)，列 \(column)"))
                    }
                    Spacer()
                    if document.text.utf16.count > 1_000_000 { Text(L("大文件：暂停高亮")) }
                    Text("UTF-8")
                    Text(document.text.contains("\r\n") ? "CRLF" : "LF")
                    Text(document.language.title)
                }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 12).frame(height: 24).background(.bar)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text").font(.system(size: 38, weight: .ultraLight)).foregroundStyle(.tertiary)
                    Text(L("从左侧选择文件开始编辑")).font(.system(size: 14)).foregroundStyle(.secondary)
                    Text(L("单击预览 · 双击保留标签 · 保存：\(shortcuts.binding(for: .saveFile).display)")).font(.system(size: 11)).foregroundStyle(.tertiary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            FileErrorBanner(model: model)
        }.background(Color(nsColor: .textBackgroundColor))
    }
}

private struct FileDocumentTab: View {
    @ObservedObject private var languagePreferences = LanguagePreferences.shared
    @ObservedObject var model: FileWorkspaceModel
    @ObservedObject var document: LocalFileDocument
    var body: some View {
        let _ = languagePreferences.language
        HStack(spacing: 0) {
            Button { model.selectedDocumentID = document.id } label: {
                HStack(spacing: 7) {
                    Image(systemName: "doc.text").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(document.url.lastPathComponent).font(.system(size: 12)).italic(document.isPreview).lineLimit(1)
                }.padding(.leading, 12).padding(.trailing, 7).frame(height: 38).contentShape(Rectangle())
            }.buttonStyle(.plain).pointingHandCursor()
                .simultaneousGesture(TapGesture(count: 2).onEnded { document.isPreview = false })
            Button { model.closeWithPrompt(document) } label: {
                Image(systemName: document.isDirty ? "circle.fill" : "xmark").font(.system(size: document.isDirty ? 6 : 9))
                    .frame(width: 14, height: 22).padding(.trailing, 12).frame(height: 38).contentShape(Rectangle())
            }.buttonStyle(.plain).pointingHandCursor().help(document.isDirty ? L("关闭（有未保存更改）") : L("关闭文件"))
        }.frame(height: 38)
            .background(model.selectedDocumentID == document.id ? Color(nsColor: .textBackgroundColor) : .clear)
            .overlay(alignment: .bottom) { if model.selectedDocumentID == document.id { Rectangle().fill(Color.accentColor).frame(height: 2).allowsHitTesting(false) } }
            .help(document.url.path)
            .contextMenu {
                Button(L("保存")) { _ = model.save(document) }.disabled(!document.isDirty)
                Button(L("保留打开")) { document.isPreview = false }.disabled(!document.isPreview)
                Button(L("在 Finder 中显示")) { NSWorkspace.shared.activateFileViewerSelecting([document.url]) }
                Divider(); Button(L("关闭")) { model.closeWithPrompt(document) }
            }
    }
}

private struct FileErrorBanner: View {
    @ObservedObject private var languagePreferences = LanguagePreferences.shared
    @ObservedObject var model: FileWorkspaceModel
    var body: some View {
        let _ = languagePreferences.language
        if let error = model.error {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                Text(error).font(.system(size: 11)).textSelection(.enabled)
                Spacer(minLength: 0)
                IconButton(symbol: "xmark", help: L("关闭错误信息")) { model.error = nil }
            }.padding(10).background(Color.orange.opacity(0.08))
        }
    }
}

private extension View {
    @ViewBuilder func italic(_ value: Bool) -> some View { if value { self.italic() } else { self } }
}
