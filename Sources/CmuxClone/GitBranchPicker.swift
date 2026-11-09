import SwiftUI

enum GitBranchPickerPurpose: String, Identifiable {
    case checkout, merge, rebase
    var id: String { rawValue }

    /// Keep full ref names, so a branch and a tag with the same name cannot be confused.
    func operation(for reference: GitCheckoutReference) -> LocalGitOperation? {
        switch self {
        case .checkout: return nil
        case .merge: return .mergeBranch(reference.id)
        case .rebase: return .rebaseBranch(reference.id)
        }
    }

    func references(_ references: [GitCheckoutReference], currentBranch: String?, query: String) -> [GitCheckoutReference] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return references.filter { ref in
            let eligible = self == .checkout || (ref.kind != .tag && !(ref.kind == .local && ref.name == currentBranch))
            return eligible && (query.isEmpty || [ref.name, ref.subject, ref.author, ref.shortHash]
                .contains { $0.localizedStandardContains(query) })
        }.sorted { left, right in
            let leftCurrent = left.kind == .local && left.name == currentBranch
            let rightCurrent = right.kind == .local && right.name == currentBranch
            if leftCurrent != rightCurrent { return leftCurrent }
            if left.kind != right.kind {
                return GitCheckoutReference.Kind.allCases.firstIndex(of: left.kind)! < GitCheckoutReference.Kind.allCases.firstIndex(of: right.kind)!
            }
            if left.timestamp != right.timestamp { return (left.timestamp ?? .distantPast) > (right.timestamp ?? .distantPast) }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
    }
}

/// Every action retains the repository that opened it, even when another row was selected.
struct GitBranchPicker: View {
    @ObservedObject private var languagePreferences = LanguagePreferences.shared
    @ObservedObject var model: SourceControlModel
    let repository: LocalGitSnapshot
    var purpose: GitBranchPickerPurpose = .checkout
    @Environment(\.dismiss) private var dismiss
    @State private var references: [GitCheckoutReference] = []
    @State private var query = ""
    @State private var branchName = ""
    @State private var selectedID: String?
    @State private var mode: Mode = .checkout
    @State private var loading = true
    @State private var loadError: String?
    @FocusState private var inputFocused: Bool
    @FocusState private var nameFocused: Bool

    private enum Mode: Equatable {
        case checkout, chooseBase, detached, name(String?)
    }
    private struct Item: Identifiable {
        let id: String
        let title: String
        let reference: GitCheckoutReference?
        static func action(_ id: String, _ title: String) -> Item { Item(id: id, title: title, reference: nil) }
    }
    private var items: [Item] {
        var result: [Item] = []
        if mode == .checkout && purpose == .checkout {
            result = [.action("create", L("新建分支…")), .action("from", L("从指定分支或标签新建…")), .action("detached", L("以游离 HEAD 检出…"))]
        }
        result += purpose.references(references, currentBranch: repository.branch, query: query)
            .map { Item(id: $0.id, title: $0.name, reference: $0) }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return result }
        return result.filter { item in
            [item.title, item.reference?.subject ?? "", item.reference?.author ?? "", item.reference?.shortHash ?? ""]
                .contains { $0.localizedStandardContains(query) }
        }
    }
    private var title: String {
        switch mode {
        case .checkout:
            switch purpose {
            case .checkout: return L("选择要切换的分支或标签")
            case .merge: return L("选择要合并到当前分支的分支")
            case .rebase: return L("选择当前分支的变基目标")
            }
        case .chooseBase: return L("选择新分支的起点")
        case .detached: return L("选择引用，以游离 HEAD 检出")
        case .name: return L("新建并切换分支")
        }
    }

    private var footer: String {
        switch purpose {
        case .merge: return L("将所选分支合并到当前分支 \(repository.branch ?? "HEAD")。")
        case .rebase: return L("将当前分支 \(repository.branch ?? "HEAD") 变基到所选分支。")
        case .checkout: return mode == .detached ? L("检出后不关联任何分支；新提交需另建分支保存。") : L("远程分支会建立本地跟踪分支，标签会以游离 HEAD 检出。")
        }
    }

    var body: some View {
        let _ = languagePreferences.language
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(repository.rootURL.lastPathComponent + " · " + (repository.branch ?? L("游离 HEAD")))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("关闭")) { dismiss() }.pointingHandCursor().keyboardShortcut(.cancelAction)
            }.padding(16)
            if case .name(let base) = mode {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L("起点：") + (base ?? repository.branch ?? "HEAD")).font(.caption).foregroundStyle(.secondary)
                    TextField(L("输入新分支名称"), text: $branchName).textFieldStyle(.roundedBorder)
                        .focused($nameFocused).onSubmit { createBranch(from: base) }
                        .task {
                            // Wait for the sheet's replacement field to enter the key-view loop.
                            try? await Task.sleep(for: .milliseconds(100))
                            if !Task.isCancelled { nameFocused = true }
                        }
                    HStack {
                        Button(L("返回")) { reset() }.pointingHandCursor()
                        Spacer()
                        Button(L("创建并切换")) { createBranch(from: base) }.buttonStyle(.borderedProminent).pointingHandCursor()
                            .disabled(branchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isBusy)
                    }
                }.padding(16)
                Spacer()
            } else {
                TextField(purpose == .checkout ? L("搜索分支、标签或提交信息") : L("搜索分支或提交信息"), text: $query)
                    .textFieldStyle(.roundedBorder).focused($inputFocused)
                    .onAppear { inputFocused = true }
                    .padding(.horizontal, 16).padding(.bottom, 10)
                    .onSubmit { activateSelected() }
                    .onKeyPress(.downArrow) { moveSelection(1); return .handled }
                    .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
                Divider()
                if loading {
                    ProgressView(L("正在读取分支…")).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let loadError {
                    VStack(spacing: 12) {
                        Text(loadError).foregroundStyle(.red).textSelection(.enabled)
                        Button(L("重试")) { Task { await load() } }.pointingHandCursor()
                    }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        List(selection: $selectedID) {
                            ForEach(items) { item in
                                row(item).pointingHandCursor().tag(item.id).id(item.id)
                                    .onTapGesture { activate(item) }
                                    .accessibilityAddTraits(.isButton)
                                    .accessibilityAction { activate(item) }
                            }
                        }.listStyle(.plain)
                            .overlay { if items.isEmpty { Text(purpose == .checkout ? L("没有匹配的分支或标签") : L("没有可选择的匹配分支")).foregroundStyle(.secondary) } }
                            .onKeyPress(.return) { activateSelected(); return .handled }
                            .onChange(of: selectedID) { _, id in if let id { proxy.scrollTo(id) } }
                    }
                }
                Divider()
                HStack {
                    if mode != .checkout { Button(L("返回")) { reset() }.pointingHandCursor() }
                    Text(footer)
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text(L("↑↓ 选择  ↩ 确认")).font(.caption).foregroundStyle(.tertiary)
                }.padding(12)
            }
        }.frame(width: 720, height: 560)
            .background(Color(nsColor: .windowBackgroundColor))
            .task { await load(); inputFocused = true }
            .onChange(of: query) { _, _ in selectedID = items.first?.id }
    }

    private func row(_ item: Item) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if let ref = item.reference, ref.kind != .tag { GitBranchIcon() }
                else { Image(systemName: item.reference == nil ? "plus" : "tag") }
            }.foregroundStyle(.secondary).frame(width: 17).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(item.title).lineLimit(1)
                    if let ref = item.reference {
                        if ref.kind == .local && ref.name == repository.branch {
                            Image(systemName: "checkmark").foregroundStyle(Color.accentColor).accessibilityLabel(L("当前分支"))
                        }
                        if let date = ref.timestamp { Text(date, style: .relative).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Text(ref.kind.title).font(.caption).foregroundStyle(.tertiary)
                    }
                }
                if let ref = item.reference {
                    Text([ref.author, ref.shortHash, ref.subject].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }.padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }
    private func load() async {
        loading = true; loadError = nil
        do { references = try await model.checkoutReferences(in: repository.rootURL) }
        catch { loadError = error.localizedDescription }
        loading = false; selectedID = items.first?.id
    }
    private func moveSelection(_ offset: Int) {
        let options = items
        guard !options.isEmpty else { return }
        let index = options.firstIndex { $0.id == selectedID } ?? (offset > 0 ? -1 : options.count)
        selectedID = options[min(max(index + offset, 0), options.count - 1)].id
    }
    private func activateSelected() {
        guard !loading, loadError == nil, let item = items.first(where: { $0.id == selectedID }) ?? items.first else { return }
        activate(item)
    }
    private func reset() {
        mode = .checkout; query = ""; branchName = ""; selectedID = items.first?.id; inputFocused = true
    }
    private func activate(_ item: Item) {
        guard !model.isBusy else { return }
        guard let ref = item.reference else {
            query = ""; branchName = ""
            switch item.id {
            case "create": mode = .name(nil)
            case "from": mode = .chooseBase
            default: mode = .detached
            }
            selectedID = items.first?.id; inputFocused = true
            return
        }
        if let operation = purpose.operation(for: ref) {
            if purpose == .rebase && !confirm(title: L("变基到 \(ref.name)？"), detail: L("变基会重写当前分支上的提交；如有冲突，可在菜单中继续或中止。"), action: L("变基")) { return }
            dismiss()
            Task { await model.perform(operation, in: repository.rootURL) }
            return
        }
        if mode == .chooseBase { mode = .name(ref.id); inputFocused = true; return }
        let detached = mode == .detached
        dismiss()
        Task {
            if detached { await model.perform(.checkoutDetached(ref.id), in: repository.rootURL) }
            else {
                switch ref.kind {
                case .local: await model.switchBranch(ref.name, in: repository.rootURL)
                case .remote: await model.perform(.checkoutRemote(ref.name), in: repository.rootURL)
                case .tag: await model.perform(.checkoutTag(ref.name), in: repository.rootURL)
                }
            }
        }
    }
    private func createBranch(from base: String?) {
        let name = branchName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !model.isBusy else { return }
        dismiss()
        Task { await model.switchBranch(name, create: true, startPoint: base, in: repository.rootURL) }
    }
}
