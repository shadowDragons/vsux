import AppKit
import SwiftUI

enum WorkspaceSidebarSection: String, CaseIterable, Codable {
    case workspaces = "工作区", files = "文件", git = "源代码管理"
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        // Previous sessions may have saved the former standalone Search section.
        if value == "搜索" { self = .files; return }
        guard let section = Self(rawValue: value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown sidebar section")
        }
        self = section
    }
    var title: String {
        switch self { case .workspaces: return L("工作区"); case .files: return L("文件"); case .git: return L("源代码管理") }
    }
    var symbol: String {
        switch self { case .workspaces: return "square.stack"; case .files: return "doc.on.doc"; case .git: return "arrow.triangle.branch" }
    }
}
enum WorkspaceContentMode: String, Codable { case terminal, editor, diff }

@MainActor
final class WorkspaceToolsState: ObservableObject {
    @Published var sidebar: WorkspaceSidebarSection = .workspaces { didSet { if sidebar != oldValue { onSessionChange?() } } }
    @Published var showFileSearch = false
    @Published var content: WorkspaceContentMode = .terminal { didSet { if content != oldValue { onSessionChange?() } } }
    var onSessionChange: (() -> Void)?
    private var fileModels: [UUID: FileWorkspaceModel] = [:]
    private var savedFileSessions: [UUID: FileWorkspaceSession] = [:]
    private var gitModels: [UUID: SourceControlModel] = [:]
    let notifications = GitNotificationStore()

    func files(_ workspace: Workspace) -> FileWorkspaceModel {
        if let model = fileModels[workspace.id] { return model }
        let model = FileWorkspaceModel(rootURL: URL(fileURLWithPath: workspace.directory, isDirectory: true))
        fileModels[workspace.id] = model
        if let session = savedFileSessions.removeValue(forKey: workspace.id) { model.restoreSession(session) }
        model.onSessionChange = { [weak self] in self?.onSessionChange?() }
        return model
    }
    func fileSession(for workspaceID: UUID) -> FileWorkspaceSession? {
        fileModels[workspaceID]?.sessionSnapshot ?? savedFileSessions[workspaceID]
    }
    func restoreFiles(_ session: FileWorkspaceSession, for workspaceID: UUID) {
        savedFileSessions[workspaceID] = session
    }
    func transferFiles(for workspaceID: UUID, to destination: WorkspaceToolsState) {
        if let model = fileModels.removeValue(forKey: workspaceID) {
            destination.fileModels[workspaceID] = model
            model.onSessionChange = { [weak destination] in destination?.onSessionChange?() }
        }
        if let saved = savedFileSessions.removeValue(forKey: workspaceID) { destination.savedFileSessions[workspaceID] = saved }
    }
    func git(_ workspace: Workspace) -> SourceControlModel {
        if let model = gitModels[workspace.id] { return model }
        let model = SourceControlModel(directory: URL(fileURLWithPath: workspace.directory, isDirectory: true),
            notifications: notifications, workspaceID: workspace.id)
        gitModels[workspace.id] = model
        return model
    }
}

@MainActor
final class SourceControlModel: ObservableObject {
    let directory: URL
    let notifications: GitNotificationStore
    let workspaceID: UUID?
    @Published private(set) var repositories: [LocalGitSnapshot] = []
    @Published private(set) var selectedRepositoryPath: String?
    @Published private(set) var isBusy = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var refreshingRepositoryPaths: Set<String> = []
    @Published var error: String?
    @Published var commitMessage = ""
    @Published private var diffTitleOverride: String?
    @Published private var diffTextOverride: String?
    var diffTitle: String {
        get { diffTitleOverride ?? L("变更") }
        set { diffTitleOverride = newValue }
    }
    var diffText: String {
        get { diffTextOverride ?? L("选择一个变更文件以查看差异。") }
        set { diffTextOverride = newValue }
    }
    @Published var diffLoading = false
    private var additionalRepositoryRoots: [URL] = []
    private var repositoryByPath: [String: LocalGitRepository] = [:]
    private var commitMessages: [String: String] = [:]
    private var diffRequest = UUID()
    private var refreshGeneration = 0
    private var activationRefreshInProgress = false
    private var lastActivationRefresh: ContinuousClock.Instant?
    @Published private(set) var fetchingRemotePaths: Set<String> = []
    private var lastRemoteRefresh: [String: ContinuousClock.Instant] = [:]

    init(directory: URL, notifications: GitNotificationStore? = nil, workspaceID: UUID? = nil) {
        self.directory = directory
        self.notifications = notifications ?? GitNotificationStore()
        self.workspaceID = workspaceID
    }
    private func report(_ detail: String, in root: URL? = nil, kind: GitNoticeKind = .operation, background: Bool = false) {
        let repository = root ?? snapshot?.rootURL ?? directory
        let detail = LocalGitRepository.redact(detail)
        error = detail
        notifications.post(detail: detail, repository: repository, workspaceID: workspaceID, kind: kind,
            severity: background ? .warning : .error, silent: background,
            canShowOutput: repositoryByPath[repository.standardizedFileURL.path] != nil)
    }
    var snapshot: LocalGitSnapshot? {
        guard let selectedRepositoryPath else { return nil }
        return repositories.first { $0.rootURL.standardizedFileURL.path == selectedRepositoryPath }
    }
    var staged: [LocalGitChange] { snapshot?.changes.filter(\.isStaged) ?? [] }
    var unstaged: [LocalGitChange] { snapshot?.changes.filter(\.isUnstaged) ?? [] }
    var canCommit: Bool { !isBusy && !(snapshot?.changes.isEmpty ?? true) && !(snapshot?.changes.contains(where: \.isConflicted) ?? false) && !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var canCommitStaged: Bool { canCommit && !staged.isEmpty }

    func selectRepository(_ rootURL: URL) {
        let path = rootURL.standardizedFileURL.path
        guard !isBusy, repositoryByPath[path] != nil, path != selectedRepositoryPath else { return }
        changeSelection(to: path)
    }

    private func changeSelection(to path: String?) {
        if let previous = selectedRepositoryPath { commitMessages[previous] = commitMessage }
        selectedRepositoryPath = path
        commitMessage = path.flatMap { commitMessages[$0] } ?? ""
        diffRequest = UUID()
        diffLoading = false
        diffTitleOverride = nil
        diffTextOverride = nil
        error = nil
    }

    func refresh() async {
        guard !isBusy else { return }
        refreshGeneration += 1
        isBusy = true
        defer { isBusy = false; hasLoaded = true }
        do {
            var discovered = try await LocalGitRepository.discoverAll(in: directory)
            for root in additionalRepositoryRoots where !discovered.contains(where: { $0.rootURL == root }) {
                if let repository = try? await LocalGitRepository.discover(at: root) { discovered.append(repository) }
            }
            var newRepositories: [LocalGitSnapshot] = []
            var newRepositoryByPath: [String: LocalGitRepository] = [:]
            var failures: [String] = []
            for discoveredRepository in discovered {
                let path = discoveredRepository.rootURL.standardizedFileURL.path
                let repository = repositoryByPath[path] ?? discoveredRepository
                do {
                    newRepositories.append(try await repository.snapshot())
                    newRepositoryByPath[path] = repository
                } catch {
                    failures.append("\(repository.rootURL.lastPathComponent)：\(error.localizedDescription)")
                    report(error.localizedDescription, in: repository.rootURL, kind: .refresh)
                }
            }
            repositories = newRepositories
            repositoryByPath = newRepositoryByPath
            if !newRepositories.contains(where: { $0.rootURL.standardizedFileURL.path == selectedRepositoryPath }) {
                changeSelection(to: newRepositories.first?.rootURL.standardizedFileURL.path)
            }
            error = failures.isEmpty ? nil : failures.joined(separator: "\n")
        } catch {
            repositories = []; repositoryByPath = [:]; changeSelection(to: nil)
            report(error.localizedDescription, in: directory, kind: .scan)
        }
    }
    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await refresh()
    }

    func refreshRepository(_ root: URL) async {
        let path = root.standardizedFileURL.path
        guard !isBusy, !refreshingRepositoryPaths.contains(path), let repo = repositoryByPath[path] else { return }
        refreshGeneration += 1
        let generation = refreshGeneration
        refreshingRepositoryPaths.insert(path)
        defer { refreshingRepositoryPaths.remove(path) }
        do {
            let updated = try await repo.snapshot()
            guard generation == refreshGeneration, let index = repositories.firstIndex(where: { $0.rootURL.path == path }) else { return }
            repositories[index] = updated
            error = nil
        } catch {
            guard generation == refreshGeneration else { return }
            report(error.localizedDescription, in: root, kind: .refresh)
        }
    }

    /// Returning to an existing window must not rescan the directory tree or
    /// lock its controls. A command invalidates these read results before writing.
    func refreshOnActivation() async {
        guard !isBusy, !activationRefreshInProgress else { return }
        guard hasLoaded else { await loadIfNeeded(); return }
        if let lastActivationRefresh, lastActivationRefresh.duration(to: .now) < .seconds(3) { return }
        activationRefreshInProgress = true
        defer { activationRefreshInProgress = false }
        let generation = refreshGeneration
        let knownRepositories = repositories.compactMap { repositoryByPath[$0.rootURL.standardizedFileURL.path] }
        var updates: [String: LocalGitSnapshot] = [:]
        var failures: [String] = []
        for repo in knownRepositories {
            guard generation == refreshGeneration, !Task.isCancelled else { return }
            do { updates[repo.rootURL.standardizedFileURL.path] = try await repo.snapshot() }
            catch {
                failures.append("\(repo.rootURL.lastPathComponent)：\(error.localizedDescription)")
                report(error.localizedDescription, in: repo.rootURL, kind: .refresh, background: true)
            }
        }
        guard generation == refreshGeneration, !Task.isCancelled else { return }
        // Keep selection, drafts and failed repositories. A slow/removed repo
        // must not clear an already usable sidebar.
        repositories = repositories.map { updates[$0.rootURL.standardizedFileURL.path] ?? $0 }
        if !failures.isEmpty, error == nil { error = failures.joined(separator: "\n") }
        lastActivationRefresh = .now
    }

    /// Fetch only updates remote references; never merges or pushes in the
    /// background. Keep the sidebar usable while a remote is slow/offline.
    func refreshRemoteStatuses(force: Bool = false) async {
        guard !isBusy else { return }
        let roots = repositories.filter { !$0.remotes.isEmpty }.map(\.rootURL)
        for root in roots {
            let path = root.standardizedFileURL.path
            guard !isBusy, !Task.isCancelled else { return }
            guard !fetchingRemotePaths.contains(path), let repo = repositoryByPath[path] else { continue }
            if !force, let last = lastRemoteRefresh[path], last.duration(to: .now) < .seconds(60) { continue }
            fetchingRemotePaths.insert(path)
            lastRemoteRefresh[path] = .now
            let generation = refreshGeneration
            do {
                try await repo.perform(.fetchAll)
                let updated = try await repo.snapshot()
                if generation == refreshGeneration, !Task.isCancelled,
                   let index = repositories.firstIndex(where: { $0.rootURL.standardizedFileURL.path == path }) {
                    repositories[index] = updated
                    notifications.resolveBackgroundFetch(repository: root, workspaceID: workspaceID)
                }
            } catch {
                if generation == refreshGeneration, !Task.isCancelled {
                    report(error.localizedDescription, in: root, kind: .fetch, background: !force)
                }
            }
            fetchingRemotePaths.remove(path)
        }
    }
    func stage(_ changes: [LocalGitChange], in root: URL? = nil) async {
        if let root { selectRepository(root); guard selectedRepositoryPath == root.standardizedFileURL.path else { return } }
        await mutate { repo in try await repo.stage(paths: changes.map(\.path)) }
    }
    func unstage(_ changes: [LocalGitChange], in root: URL? = nil) async {
        if let root { selectRepository(root); guard selectedRepositoryPath == root.standardizedFileURL.path else { return } }
        await mutate { repo in try await repo.unstage(paths: changes.map(\.path)) }
    }
    func discard(_ change: LocalGitChange, in root: URL) async {
        guard !isBusy else { return }
        selectRepository(root)
        guard snapshot?.rootURL.standardizedFileURL == root.standardizedFileURL,
              let current = snapshot?.changes.first(where: { $0.path == change.path }),
              current.isUnstaged, !current.isConflicted else { return }
        let success = await mutate { repo in
            try await repo.perform(current.isUntracked ? .discardUntracked([current.path]) : .discardTracked([current.path]))
        }
        if success {
            diffRequest = UUID()
            diffTitleOverride = nil
            diffTextOverride = nil
            diffLoading = false
        }
    }
    /// Shared by the primary button and Command-Return. Explicit staged-only
    /// actions continue to call commit directly and never expand their scope.
    func requestCommit(in root: URL) async {
        guard snapshot?.rootURL.standardizedFileURL == root.standardizedFileURL, canCommit else { return }
        await commit(stageAll: staged.isEmpty, in: root, message: commitMessage)
    }

    func commit(amend: Bool = false, stageAll: Bool = false, in root: URL? = nil, message suppliedMessage: String? = nil) async {
        if let root { selectRepository(root); guard selectedRepositoryPath == root.standardizedFileURL.path else { return } }
        let message = suppliedMessage ?? commitMessage
        guard !isBusy, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !(snapshot?.changes.contains(where: \.isConflicted) ?? true),
              !staged.isEmpty || (stageAll && !unstaged.isEmpty) || (amend && snapshot?.head != nil) else { return }
        let paths = unstaged.map(\.path)
        let success = await mutate { repo in
            if stageAll { try await repo.stage(paths: paths) }
            try await repo.commit(message: message, amend: amend)
        }
        if success { commitMessage = ""; diffText = L("提交完成。选择变更文件以查看差异。") }
    }
    func switchBranch(_ branch: String, create: Bool = false, startPoint: String? = nil, in root: URL? = nil) async {
        if let root { selectRepository(root); guard selectedRepositoryPath == root.standardizedFileURL.path else { return } }
        await mutate { repo in try await repo.checkout(branch: branch, create: create, startPoint: startPoint) }
    }
    func checkoutReferences(in root: URL) async throws -> [GitCheckoutReference] {
        guard let repo = repositoryByPath[root.standardizedFileURL.path] else { throw LocalGitError.notRepository(root) }
        return try await repo.checkoutReferences()
    }
    func perform(_ operation: LocalGitOperation, in root: URL) async {
        guard !isBusy else { return }
        selectRepository(root)
        guard snapshot?.rootURL == root else { return }
        await mutate { repo in try await repo.perform(operation) }
    }
    func clone(from source: String, to destination: URL) async {
        guard !isBusy else { return }
        refreshGeneration += 1
        isBusy = true
        do {
            let repo = try await LocalGitRepository.clone(from: source, to: destination)
            additionalRepositoryRoots.append(repo.rootURL)
            isBusy = false
            await refresh()
            selectRepository(repo.rootURL)
        } catch { report(error.localizedDescription, in: destination); isBusy = false }
    }
    func remoteURL(_ name: String, in root: URL) async -> String? {
        guard let repo = repositoryByPath[root.standardizedFileURL.path] else { return nil }
        do { return try await repo.remoteURL(name) }
        catch { report(error.localizedDescription, in: root); return nil }
    }
    func showHistory() async {
        guard let path = selectedRepositoryPath, let repo = repositoryByPath[path] else { return }
        let request = UUID(); diffRequest = request
        diffTitle = repo.rootURL.lastPathComponent + L(" · 最近 50 次提交")
        do {
            let text = try await repo.history()
            guard request == diffRequest else { return }
            diffText = text.isEmpty ? L("暂无提交。") : text; diffLoading = false
        } catch {
            guard request == diffRequest else { return }
            diffText = error.localizedDescription; diffLoading = false
        }
    }
    func showRepositoryDiff(staged: Bool) async {
        guard let path = selectedRepositoryPath, let repo = repositoryByPath[path] else { return }
        let request = UUID(); diffRequest = request
        diffTitle = repo.rootURL.lastPathComponent + (staged ? L(" · 全部已暂存更改") : L(" · 全部工作区更改"))
        diffLoading = true
        do {
            let text = try await repo.diff(staged: staged)
            guard request == diffRequest else { return }
            diffText = text.isEmpty ? L("没有可显示的已跟踪文件差异。未跟踪文件请单独选择查看。") : text
        } catch {
            guard request == diffRequest else { return }
            diffText = error.localizedDescription
        }
        if request == diffRequest { diffLoading = false }
    }
    func showGitOutput() async {
        guard let path = selectedRepositoryPath, let repo = repositoryByPath[path] else { return }
        let request = UUID(); diffRequest = request
        diffTitle = repo.rootURL.lastPathComponent + L(" · Git 输出")
        let text = await repo.outputLog()
        guard request == diffRequest else { return }
        diffText = text; diffLoading = false
    }
    @discardableResult private func mutate(_ operation: (LocalGitRepository) async throws -> Void) async -> Bool {
        guard !isBusy, let selectedRepositoryPath, let repo = repositoryByPath[selectedRepositoryPath] else { return false }
        refreshGeneration += 1
        isBusy = true
        defer { isBusy = false }
        do {
            try await operation(repo)
            let updated = try await repo.snapshot()
            if let index = repositories.firstIndex(where: { $0.rootURL.standardizedFileURL.path == selectedRepositoryPath }) {
                repositories[index] = updated
            }
            error = nil
            return true
        } catch {
            report(error.localizedDescription, in: repo.rootURL)
            // Git can change files before reporting a merge/rebase/stash conflict.
            if let updated = try? await repo.snapshot(),
               let index = repositories.firstIndex(where: { $0.rootURL.standardizedFileURL.path == selectedRepositoryPath }) {
                repositories[index] = updated
            }
            return false
        }
    }
    func showDiff(_ change: LocalGitChange, staged: Bool) async {
        guard let selectedRepositoryPath, let repo = repositoryByPath[selectedRepositoryPath] else { return }
        let request = UUID(); diffRequest = request
        diffTitle = repo.rootURL.lastPathComponent + " / " + change.path + (staged ? L(" · 已暂存") : L(" · 工作区"))
        diffLoading = true
        do {
            let result = try await repo.diff(path: change.path, staged: staged)
            guard diffRequest == request else { return }
            diffText = result.isEmpty ? (change.isUntracked ? L("此文件尚未跟踪。打开文件查看内容；暂存后可查看添加差异。") : L("没有可显示的文本差异（可能是二进制文件或仅元数据变化）。")) : result
        } catch {
            guard diffRequest == request else { return }
            diffText = error.localizedDescription
        }
        if diffRequest == request { diffLoading = false }
    }
}

struct SidebarSectionPicker: View {
    @ObservedObject private var languagePreferences = LanguagePreferences.shared
    @ObservedObject var tools: WorkspaceToolsState
    var body: some View {
        let _ = languagePreferences.language
        HStack(spacing: 5) {
            ForEach(WorkspaceSidebarSection.allCases, id: \.self) { section in
                Button { tools.sidebar = section } label: {
                    Image(systemName: section.symbol).font(.system(size: 14)).frame(maxWidth: .infinity).frame(height: 31)
                        .foregroundStyle(tools.sidebar == section ? Color.accentColor : .secondary)
                        .background(tools.sidebar == section ? Color.accentColor.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 5))
                        // Plain buttons otherwise only hit-test the painted symbol.
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).pointingHandCursor().help(section.title).accessibilityLabel(section.title)
            }
        }.padding(.horizontal, 8).padding(.vertical, 5).background(.bar)
    }
}

struct SourceControlPanel: View {
    @ObservedObject private var languagePreferences = LanguagePreferences.shared
    @ObservedObject var model: SourceControlModel
    let openFile: (URL) -> Void
    let showDiff: () -> Void
    @State private var checkoutRepository: LocalGitSnapshot?
    @State private var repositoriesExpanded = true
    @State private var changesExpanded = true
    @State private var stagedExpanded = true
    @State private var unstagedExpanded = true

    var body: some View {
        let _ = languagePreferences.language
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(L("源代码管理")).font(.system(size: 13, weight: .semibold))
                Spacer()
                if model.isBusy { ProgressView().controlSize(.small) }
                Menu {
                    Button(L("刷新所有仓库")) { Task { await model.refresh() } }
                    Button(L("获取远程状态（Fetch）")) { Task { await model.refreshRemoteStatuses(force: true) } }
                    Button(L("克隆 Git 仓库…")) { askCloneRepository(model: model) }
                    if model.snapshot != nil {
                        Divider()
                        Button(L("显示 Git 输出")) { showDiff(); Task { await model.showGitOutput() } }
                    }
                } label: { Image(systemName: "ellipsis").frame(width: 26, height: 28) }
                    .menuStyle(.borderlessButton).pointingHandCursor().menuIndicator(.hidden).fixedSize()
                    .tint(.secondary).disabled(model.isBusy).accessibilityLabel(L("源代码管理操作"))
            }.padding(.horizontal, 16).frame(height: 44)

            if !model.repositories.isEmpty {
                HStack(spacing: 4) {
                    disclosure(L("仓库"), expanded: $repositoriesExpanded)
                    Spacer(minLength: 0)
                    Text("\(model.repositories.count)").font(.system(size: 11)).foregroundStyle(.secondary)
                    Menu {
                        Button(L("刷新所有仓库")) { Task { await model.refresh() } }
                        Button(L("克隆 Git 仓库…")) { askCloneRepository(model: model) }
                    } label: { Image(systemName: "ellipsis").frame(width: 26, height: 28) }
                        .menuStyle(.borderlessButton).pointingHandCursor().menuIndicator(.hidden).fixedSize()
                        .tint(.secondary).disabled(model.isBusy).accessibilityLabel(L("仓库列表操作"))
                }.padding(.leading, 12).padding(.trailing, 10).frame(height: 32)
                if repositoriesExpanded {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(model.repositories) { repository in
                                GitRepositoryRow(model: model, repository: repository, showDetails: showDiff,
                                    checkout: { openCheckout(repository) })
                            }
                        }.padding(.horizontal, 8)
                    }.frame(height: min(CGFloat(model.repositories.count) * 32, 224))
                        .padding(.bottom, 8)
                }
                Divider().padding(.horizontal, 12)
            }

            if let snapshot = model.snapshot {
                HStack {
                    disclosure(L("更改"), expanded: $changesExpanded)
                    Spacer()
                    Text("\(snapshot.changes.count)").font(.system(size: 11)).foregroundStyle(.secondary)
                }.padding(.horizontal, 12).frame(height: 36)
                if changesExpanded {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            commitComposer(snapshot).padding(.horizontal, 18).padding(.top, 6).padding(.bottom, 16)
                            if !model.staged.isEmpty { changeSection(L("已暂存的更改"), changes: model.staged, staged: true, expanded: $stagedExpanded) }
                            if !model.unstaged.isEmpty { changeSection(L("更改"), changes: model.unstaged, staged: false, expanded: $unstagedExpanded) }
                            if snapshot.changes.isEmpty {
                                Label(L("工作区干净"), systemImage: "checkmark.circle").font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.vertical, 8)
                            }
                        }
                    }
                } else { Spacer(minLength: 0) }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 25)).foregroundStyle(.tertiary)
                    Text(model.hasLoaded ? L("当前工作区及子目录没有 Git 仓库") : L("正在扫描工作区中的 Git 仓库…")).font(.system(size: 12, weight: .medium))
                    Button(L("克隆 Git 仓库…")) { askCloneRepository(model: model) }.pointingHandCursor().disabled(model.isBusy)
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                Spacer()
            }
        }.background(Color(nsColor: .controlBackgroundColor))
            .task(id: model.directory) {
                await model.loadIfNeeded()
                while !Task.isCancelled {
                    if NSApp.isActive { await model.refreshRemoteStatuses() }
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await model.refreshOnActivation(); await model.refreshRemoteStatuses() }
            }
            .sheet(item: $checkoutRepository) { repository in GitBranchPicker(model: model, repository: repository) }
    }

    private func disclosure(_ title: String, expanded: Binding<Bool>) -> some View {
        Button { expanded.wrappedValue.toggle() } label: {
            HStack(spacing: 8) {
                Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right").font(.system(size: 11, weight: .medium)).frame(width: 12)
                Text(title).font(.system(size: 13, weight: .semibold))
            }.frame(height: 30).contentShape(Rectangle())
        }.buttonStyle(.plain).pointingHandCursor().accessibilityLabel((expanded.wrappedValue ? L("折叠") : L("展开")) + title)
    }

    private func commitComposer(_ snapshot: LocalGitSnapshot) -> some View {
        VStack(spacing: 10) {
            TextField(L("提交说明（⌘↩ 提交到 \(snapshot.branch ?? L("游离 HEAD"))）"), text: $model.commitMessage, axis: .vertical)
                .lineLimit(1...5).textFieldStyle(.plain).font(.system(size: 12))
                .padding(.horizontal, 10).padding(.vertical, 10)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1).allowsHitTesting(false))
                .accessibilityLabel(L("提交说明"))
                .onKeyPress(keys: [.return], phases: .down) { key in
                    guard key.modifiers.contains(.command), model.canCommit else { return .ignored }
                    Task { await model.requestCommit(in: snapshot.rootURL) }
                    return .handled
                }
            if snapshot.changes.isEmpty && (snapshot.hasSyncChanges || snapshot.canPublishBranch) {
                GitSyncActions(model: model, repository: snapshot, prominent: true)
            } else {
                HStack(spacing: 0) {
                    Button { Task { await model.requestCommit(in: snapshot.rootURL) } } label: {
                        Label(L("提交"), systemImage: "checkmark").font(.system(size: 13, weight: .medium)).frame(maxWidth: .infinity).frame(height: 32).contentShape(Rectangle())
                    }.buttonStyle(.plain).pointingHandCursor().disabled(!model.canCommit)
                        .help(model.staged.isEmpty ? L("提交当前仓库的全部更改") : L("提交已暂存更改"))
                        .accessibilityLabel(L("提交更改"))
                    Rectangle().fill(Color.white.opacity(0.25)).frame(width: 1, height: 20)
                    Menu {
                        Button(L("提交已暂存更改")) { Task { await model.commit(in: snapshot.rootURL) } }.disabled(!model.canCommitStaged)
                        Button(L("暂存全部并提交")) { Task { await model.commit(stageAll: true, in: snapshot.rootURL) } }
                            .disabled(!hasMessage || snapshot.changes.isEmpty || snapshot.changes.contains(where: \.isConflicted))
                        Button(L("修改最近一次提交…")) {
                            if confirm(title: L("修改最近一次提交？"), detail: L("以当前提交说明和暂存区修改最近一次提交。"), action: L("修改提交")) {
                                Task { await model.commit(amend: true, in: snapshot.rootURL) }
                            }
                        }.disabled(!hasMessage || snapshot.head == nil || snapshot.changes.contains(where: \.isConflicted))
                    } label: { Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).frame(width: 30, height: 32) }
                        .menuStyle(.borderlessButton).pointingHandCursor().menuIndicator(.hidden).fixedSize().tint(.white).accessibilityLabel(L("提交选项"))
                }.foregroundStyle(Color.white.opacity(model.canCommit ? 1 : 0.7))
                    .background(Color.accentColor.opacity(model.canCommit ? 1 : 0.55), in: RoundedRectangle(cornerRadius: 4))
                    .disabled(model.isBusy)
            }
            if !snapshot.changes.isEmpty && snapshot.hasSyncChanges {
                GitSyncActions(model: model, repository: snapshot, prominent: true)
            }
        }
    }
    private var hasMessage: Bool { !model.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private func openCheckout(_ repository: LocalGitSnapshot) {
        model.selectRepository(repository.rootURL)
        checkoutRepository = repository
    }
    private func changeSection(_ title: String, changes: [LocalGitChange], staged: Bool, expanded: Binding<Bool>) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button { expanded.wrappedValue.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right").font(.system(size: 9))
                        Text(title).font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Text("\(changes.count)").font(.system(size: 11)).foregroundStyle(.secondary)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).pointingHandCursor().accessibilityLabel((expanded.wrappedValue ? L("折叠") : L("展开")) + title)
                IconButton(symbol: staged ? "minus" : "plus", help: staged ? L("取消全部暂存") : L("暂存全部更改")) {
                    Task { if staged { await model.unstage(changes) } else { await model.stage(changes) } }
                }.disabled(changes.isEmpty || model.isBusy)
            }.foregroundStyle(.secondary).padding(.leading, 12).padding(.trailing, 5).frame(height: 31).background(Color.primary.opacity(0.025))
            if expanded.wrappedValue {
                LazyVStack(spacing: 0) {
                    ForEach(changes) { change in
                        HStack(spacing: 5) {
                            Image(systemName: "doc.text").font(.system(size: 10)).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text((change.path as NSString).lastPathComponent).font(.system(size: 12)).lineLimit(1)
                                let parent = (change.path as NSString).deletingLastPathComponent
                                if !parent.isEmpty { Text(parent).font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1) }
                            }
                            Spacer(minLength: 0)
                            Text(change.isConflicted ? "!" : change.isUntracked ? "U" : String(staged ? change.indexStatus : change.worktreeStatus)).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(change.isConflicted ? .red : change.isUntracked ? .green : .orange)
                            if !staged {
                                IconButton(symbol: "arrow.uturn.backward", help: L("放弃更改")) { askDiscard(change) }
                                    .disabled(model.isBusy || change.isConflicted)
                            }
                            IconButton(symbol: staged ? "minus" : "plus", help: staged ? L("取消暂存") : L("暂存更改")) { Task { if staged { await model.unstage([change]) } else { await model.stage([change]) } } }.disabled(model.isBusy)
                        }.padding(.leading, 15).padding(.trailing, 4).frame(minHeight: 31).contentShape(Rectangle()).pointingHandCursor()
                            .onTapGesture { showDiff(); Task { await model.showDiff(change, staged: staged) } }
                            .contextMenu {
                                Button(L("打开文件")) { if let root = model.snapshot?.rootURL { openFile(root.appendingPathComponent(change.path)) } }
                                Button(staged ? L("取消暂存") : L("暂存更改")) { Task { if staged { await model.unstage([change]) } else { await model.stage([change]) } } }.disabled(model.isBusy)
                                if !staged {
                                    Button(L("放弃更改")) { askDiscard(change) }.disabled(model.isBusy || change.isConflicted)
                                }
                            }.help(change.path)
                    }
                }
            }
        }
    }

    private func askDiscard(_ change: LocalGitChange) {
        guard !model.isBusy, !change.isConflicted, let root = model.snapshot?.rootURL else { return }
        let title = change.isUntracked ? L("将 \(1) 个未跟踪文件移到废纸篓？") : L("放弃 \(1) 个文件的未暂存更改？")
        let detail = change.isUntracked ? L("可在 macOS 废纸篓中恢复。") : L("文件会恢复为暂存区版本，尚未暂存的编辑无法通过此应用恢复。")
        let action = change.isUntracked ? L("移到废纸篓") : L("放弃更改")
        if confirm(title: title, detail: change.path + "\n\n" + detail, action: action) {
            Task { await model.discard(change, in: root) }
        }
    }
}

private struct GitRepositoryRow: View {
    @ObservedObject private var languagePreferences = LanguagePreferences.shared
    @ObservedObject var model: SourceControlModel
    let repository: LocalGitSnapshot
    let showDetails: () -> Void
    let checkout: () -> Void
    @State private var hovered = false
    private var selected: Bool { model.selectedRepositoryPath == repository.rootURL.standardizedFileURL.path }
    var body: some View {
        let _ = languagePreferences.language
        HStack(spacing: 6) {
            Button { model.selectRepository(repository.rootURL) } label: {
                HStack(spacing: 8) {
                    Image(systemName: selected ? "book.closed.fill" : "book.closed")
                        .font(.system(size: 14)).frame(width: 18)
                        .overlay {
                            if selected { Image(systemName: "checkmark").font(.system(size: 7, weight: .bold)).foregroundStyle(Color(nsColor: .controlBackgroundColor)).offset(x: 1, y: -1) }
                        }
                    Text(repository.rootURL.lastPathComponent).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity).frame(height: 30).contentShape(Rectangle())
            }.buttonStyle(.plain).pointingHandCursor().help(repository.rootURL.path).accessibilityLabel(L("Git 仓库 \(repository.rootURL.lastPathComponent)"))
            Button(action: checkout) {
                Label { Text(repository.branchDisplayName) } icon: { GitBranchIcon() }
                    .font(.system(size: 12)).lineLimit(1).truncationMode(.middle).frame(height: 30).contentShape(Rectangle())
            }.buttonStyle(.plain).pointingHandCursor().frame(maxWidth: 110, alignment: .trailing).layoutPriority(1)
                .help(L("切换 \(repository.rootURL.lastPathComponent) 的分支或标签") + (repository.hasUncommittedChanges ? L("（有未提交的改动）") : ""))
                .accessibilityLabel(L("切换 \(repository.rootURL.lastPathComponent) 的分支：\(repository.branch ?? L("游离 HEAD"))") + (repository.hasUncommittedChanges ? L("，有未提交的改动") : ""))
            if repository.canPublishBranch {
                GitSyncActions(model: model, repository: repository)
            } else {
                Button { Task { await model.refreshRepository(repository.rootURL) } } label: {
                    Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 13)).frame(width: 24, height: 28).contentShape(Rectangle())
                }.buttonStyle(.plain).pointingHandCursor()
                    .disabled(model.refreshingRepositoryPaths.contains(repository.rootURL.standardizedFileURL.path))
                    .help(L("刷新 \(repository.rootURL.lastPathComponent) 的本地状态"))
                    .accessibilityLabel(L("刷新 \(repository.rootURL.lastPathComponent) 的本地状态"))
            }
            if repository.hasSyncChanges {
                GitSyncActions(model: model, repository: repository)
            } else if model.fetchingRemotePaths.contains(repository.rootURL.standardizedFileURL.path) {
                ProgressView().controlSize(.mini).help(L("正在获取远程提交状态"))
            }
            RepositoryActionsMenu(model: model, repository: repository, showDetails: showDetails)
                .tint(selected ? Color.primary : Color.secondary)
        }.padding(.horizontal, 8).frame(height: 32)
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .background(Color.primary.opacity(selected ? 0.12 : hovered ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 5))
            .onHover { hovered = $0 }.disabled(model.isBusy)
    }
}

struct GitSyncActions: View {
    @ObservedObject private var languagePreferences = LanguagePreferences.shared
    @ObservedObject var model: SourceControlModel
    let repository: LocalGitSnapshot
    var prominent = false
    @State private var publishHovered = false

    var body: some View {
        let _ = languagePreferences.language
        HStack(spacing: prominent ? 8 : 3) {
            if let tracking = repository.tracking, repository.hasSyncChanges {
                syncButton(count: tracking.behind ?? 0, arrow: "↓", title: L("拉取"), operation: .pull(rebase: false))
                syncButton(count: tracking.ahead ?? 0, arrow: "↑", title: L("推送"), operation: .pushUpstream)
            } else if repository.canPublishBranch {
                Group {
                    if repository.remotes.count == 1, let remote = repository.remotes.first {
                        Button { Task { await model.perform(.push(remote, tags: false), in: repository.rootURL) } } label: {
                            publishLabel
                        }.buttonStyle(.plain)
                            .help(L("将当前分支发布到 \(remote) 并设置上游"))
                            .accessibilityLabel(L("发布 \(repository.rootURL.lastPathComponent) 的分支到 \(remote)"))
                    } else {
                        Menu {
                            ForEach(repository.remotes, id: \.self) { remote in
                                Button(remote) { Task { await model.perform(.push(remote, tags: false), in: repository.rootURL) } }
                            }
                        } label: { publishLabel }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden)
                            .help(L("选择远程以发布当前分支并设置上游"))
                            .accessibilityLabel(L("选择远程以发布 \(repository.rootURL.lastPathComponent) 的分支"))
                    }
                }.frame(maxWidth: prominent ? .infinity : nil)
                    .frame(height: prominent ? 32 : 28).contentShape(Rectangle())
                    .foregroundStyle(prominent ? Color.white : publishIconColor)
                    .tint(prominent ? Color.white : publishIconColor)
                    .background {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(prominent ? Color.accentColor.opacity(model.isBusy ? 0.55 : publishHovered ? 0.85 : 1)
                                  : Color.primary.opacity(publishHovered ? 0.08 : 0))
                    }.pointingHandCursor()
            }
        }.frame(maxWidth: prominent ? .infinity : nil)
            .onHover { publishHovered = $0 }.disabled(model.isBusy)
    }

    private var publishLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: "icloud.and.arrow.up")
            if prominent { Text(L("发布分支")) }
        }.font(.system(size: 13, weight: prominent ? .medium : .regular))
            .frame(maxWidth: prominent ? .infinity : nil)
            .frame(width: prominent ? nil : 24, height: prominent ? 32 : 28)
            .contentShape(Rectangle())
    }

    private var publishIconColor: Color {
        model.selectedRepositoryPath == repository.rootURL.standardizedFileURL.path ? .primary : .secondary
    }

    private func syncButton(count: Int, arrow: String, title: String, operation: LocalGitOperation) -> some View {
        Button { Task { await model.perform(operation, in: repository.rootURL) } } label: {
            Text((prominent ? title + " " : "") + "\(count)\(arrow)")
                .font(.system(size: prominent ? 13 : 12, weight: prominent ? .medium : .regular)).monospacedDigit()
                .padding(.horizontal, prominent ? 10 : 3).frame(maxWidth: prominent ? .infinity : nil)
                .frame(height: prominent ? 32 : 28).contentShape(Rectangle())
        }.buttonStyle(.plain).pointingHandCursor().fixedSize(horizontal: !prominent, vertical: true)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .background(prominent ? Color.accentColor.opacity(count > 0 ? 1 : 0.4) : .clear, in: RoundedRectangle(cornerRadius: 4))
            .disabled(count == 0)
            .help(L("\(title) \(repository.rootURL.lastPathComponent)：\(count) 个提交（\(repository.tracking?.upstream ?? "")）"))
            .accessibilityLabel(L("\(title) \(repository.rootURL.lastPathComponent) 的 \(count) 个提交"))
    }
}

struct LocalDiffArea: View {
    @ObservedObject private var languagePreferences = LanguagePreferences.shared
    @ObservedObject var model: SourceControlModel
    let showTerminal: () -> Void
    var body: some View {
        let _ = languagePreferences.language
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "doc.text.magnifyingglass").foregroundStyle(.secondary)
                Text(model.diffTitle).font(.system(size: 12)).lineLimit(1)
                Spacer()
                if model.diffLoading { ProgressView().controlSize(.small) }
                IconButton(symbol: "terminal", help: L("返回终端"), action: showTerminal)
            }.padding(.horizontal, 12).frame(height: 38).background(.bar)
            Divider()
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.diffText.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : line).font(.system(size: 12, design: .monospaced)).foregroundStyle(lineColor(line)).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).background(lineBackground(line)).textSelection(.enabled)
                    }
                }.padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
            }.background(Color(nsColor: .textBackgroundColor))
        }
    }
    private func lineColor(_ line: String) -> Color { line.hasPrefix("+") ? .green : line.hasPrefix("-") ? .red : line.hasPrefix("@@") ? .blue : .primary }
    private func lineBackground(_ line: String) -> Color { line.hasPrefix("+") ? .green.opacity(0.07) : line.hasPrefix("-") ? .red.opacity(0.07) : .clear }
}
