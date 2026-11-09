import Foundation

/// Persists workspaces, terminal structure and editor tabs, without live processes.
@MainActor
final class WorkspaceSession {
    let fileURL: URL
    private var windows: [WeakWindow] = []
    private var lastSavedData: Data?
    private var loadError: String?
    private(set) var isSuspended = false

    init(directory: URL? = nil) {
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CmuxLocal", isDirectory: true)
        fileURL = root.appendingPathComponent("workspaces.json")
    }

    func restore(shellCommand: String? = nil) -> [WindowModel] {
        do {
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                lastSavedData = nil; loadError = nil
                return []
            }
            let data = try Data(contentsOf: fileURL)
            guard data.count <= 4_194_304 else { throw WorkspaceArchiveError.invalid }
            let archive = try JSONDecoder().decode(WorkspaceArchive.self, from: data)
            try archive.validate()
            lastSavedData = data
            loadError = nil
            return archive.windows.map { saved in
                let model = WindowModel(workspaces: saved.workspaces.map { $0.restore() }, shellCommand: shellCommand)
                if model.workspaces.contains(where: { $0.id == saved.selectedWorkspaceID }) {
                    model.selectedWorkspaceID = saved.selectedWorkspaceID
                }
                for workspace in saved.workspaces {
                    if let files = workspace.files { model.tools.restoreFiles(files, for: workspace.id) }
                    for pane in workspace.panes ?? [] {
                        model.paneTabs[pane.id] = pane.terminals.map(\.tab)
                        model.paneSelection[pane.id] = pane.selectedTerminalID
                        for terminal in pane.terminals { model.terminalDirectories[terminal.tab.id] = terminal.directory }
                    }
                }
                model.tools.sidebar = saved.sidebar ?? .workspaces
                // Diff text is transient; return to the terminal rather than an empty diff.
                model.tools.content = saved.content == .diff ? .terminal : (saved.content ?? .terminal)
                return model
            }
        } catch {
            // Preserve unreadable/future data instead of replacing it with defaults.
            loadError = L("无法读取工作区，原文件已保留：\(error.localizedDescription)")
            return []
        }
    }

    func register(_ model: WindowModel) {
        windows.removeAll { $0.model == nil }
        guard !windows.contains(where: { $0.model === model }) else { return }
        windows.append(WeakWindow(model))
        model.onWorkspaceChange = { [weak self] in self?.save() }
        if let loadError { model.error = loadError }
    }

    /// Closing the last window keeps its workspace list available for reopening.
    func unregister(_ model: WindowModel) {
        let live = windows.compactMap(\.model)
        if live.count == 1, live.first === model { save() }
        model.onWorkspaceChange = nil
        windows.removeAll { $0.model == nil || $0.model === model }
        if !windows.isEmpty { save() }
    }

    /// Called before disposing shells on application termination.
    func finish() {
        save()
        isSuspended = true
    }

    func save() {
        guard !isSuspended else { return }
        windows.removeAll { $0.model == nil }
        let models = windows.compactMap(\.model)
        guard !models.isEmpty else { return }
        if let loadError {
            models.first?.error = loadError
            return
        }
        let savedWindows = models.compactMap { model -> SavedWorkspaceWindow? in
            guard !model.workspaces.isEmpty else { return nil }
            return SavedWorkspaceWindow(
                workspaces: model.workspaces.map { SavedWorkspace($0, model: model) },
                selectedWorkspaceID: model.workspace?.id ?? model.workspaces[0].id,
                sidebar: model.tools.sidebar, content: model.tools.content
            )
        }
        guard !savedWindows.isEmpty else { return }
        do {
            let archive = WorkspaceArchive(windows: savedWindows)
            try archive.validate()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(archive)
            guard data.count <= 4_194_304 else { throw WorkspaceArchiveError.invalid }
            // Automatic shell titles are transient; renamed titles and layout persist.
            guard data != lastSavedData else { return }
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            lastSavedData = data
        } catch {
            models.first?.error = L("无法保存工作区：\(error.localizedDescription)")
        }
    }

    private final class WeakWindow {
        weak var model: WindowModel?
        init(_ model: WindowModel) { self.model = model }
    }
}

private struct WorkspaceArchive: Codable {
    var version = 3
    var windows: [SavedWorkspaceWindow]

    func validate() throws {
        guard (1...3).contains(version) else { throw WorkspaceArchiveError.version }
        guard windows.count <= 100, windows.allSatisfy({ window in
            !window.workspaces.isEmpty && window.workspaces.count <= 1000 &&
            Set(window.workspaces.map(\.id)).count == window.workspaces.count &&
            window.workspaces.allSatisfy {
                !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                ($0.directory as NSString).isAbsolutePath && !$0.directory.contains("\0")
            }
        }) else { throw WorkspaceArchiveError.invalid }
        for window in windows {
            var tabIDs = Set<UUID>(), paneIDs = Set<UUID>(), terminalIDs = Set<UUID>(), splitIDs = Set<UUID>()
            for workspace in window.workspaces {
                try workspace.files?.validate()
                if let services = workspace.services {
                    guard services.count <= 500,
                          Set(services.map(\.id)).count == services.count,
                          services.allSatisfy({
                              !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                              !$0.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          }) else { throw WorkspaceArchiveError.invalid }
                }
                // Version 1 saved workspace metadata only.
                if version == 1 { continue }
                guard let tabs = workspace.tabs, !tabs.isEmpty, tabs.count <= 1000,
                      tabs.contains(where: { $0.id == workspace.selectedTabID }),
                      let panes = workspace.panes, panes.count <= 1000 else { throw WorkspaceArchiveError.invalid }
                var leaves: [UUID] = []
                func validateLayout(_ layout: PaneLayout, depth: Int = 0) throws {
                    guard depth <= 32 else { throw WorkspaceArchiveError.invalid }
                    switch layout {
                    case .leaf(let id):
                        guard paneIDs.insert(id).inserted else { throw WorkspaceArchiveError.invalid }
                        leaves.append(id)
                    case .split(let id, _, let fraction, let first, let second):
                        guard splitIDs.insert(id).inserted, fraction.isFinite, (0.15...0.85).contains(fraction) else { throw WorkspaceArchiveError.invalid }
                        try validateLayout(first, depth: depth + 1); try validateLayout(second, depth: depth + 1)
                    }
                }
                for tab in tabs {
                    guard tabIDs.insert(tab.id).inserted, !tab.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WorkspaceArchiveError.invalid }
                    try validateLayout(tab.layout)
                    guard tab.layout.leaves.contains(tab.focusedPane), tab.zoomedPane.map({ tab.layout.leaves.contains($0) }) ?? true else { throw WorkspaceArchiveError.invalid }
                }
                guard Set(panes.map(\.id)) == Set(leaves), panes.count == leaves.count else { throw WorkspaceArchiveError.invalid }
                for pane in panes {
                    guard !pane.terminals.isEmpty, pane.terminals.count <= 1000,
                          pane.terminals.contains(where: { $0.tab.id == pane.selectedTerminalID }) else { throw WorkspaceArchiveError.invalid }
                    for terminal in pane.terminals {
                        guard terminalIDs.insert(terminal.tab.id).inserted,
                              !terminal.tab.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                              (terminal.directory as NSString).isAbsolutePath, !terminal.directory.contains("\0") else { throw WorkspaceArchiveError.invalid }
                    }
                }
            }
        }
    }
}

private struct SavedWorkspaceWindow: Codable {
    var workspaces: [SavedWorkspace]
    var selectedWorkspaceID: UUID
    var sidebar: WorkspaceSidebarSection?
    var content: WorkspaceContentMode?
}

private struct SavedWorkspace: Codable {
    var id: UUID
    var name: String
    var description: String
    var directory: String
    var color: String
    var isPinned: Bool
    var services: [WorkspaceService]?
    var tabs: [TerminalTab]?
    var selectedTabID: UUID?
    var panes: [SavedPane]?
    var files: FileWorkspaceSession?

    @MainActor init(_ workspace: Workspace, model: WindowModel) {
        id = workspace.id; name = workspace.name; description = workspace.description
        directory = workspace.directory; color = workspace.color; isPinned = workspace.isPinned
        services = workspace.services
        files = model.tools.fileSession(for: workspace.id)
        // Mutations can briefly remove a selected tab/pane before updating selection.
        // Snapshot a valid fallback during these synchronous intermediate states.
        let savedTabs = (workspace.tabs.isEmpty ? [TerminalTab()] : workspace.tabs).map { original in
            var tab = original
            if !tab.customTitle { tab.title = "终端" }
            if !tab.layout.leaves.contains(tab.focusedPane) { tab.focusedPane = tab.layout.leaves[0] }
            if let zoomed = tab.zoomedPane, !tab.layout.leaves.contains(zoomed) { tab.zoomedPane = nil }
            return tab
        }
        tabs = savedTabs
        selectedTabID = savedTabs.contains(where: { $0.id == workspace.selectedTabID }) ? workspace.selectedTabID : savedTabs[0].id
        panes = savedTabs.flatMap(\.layout.leaves).map { pane in
            let local = model.localTabs(pane)
            let localTabs = local.isEmpty ? [PaneTerminalTab(id: pane)] : local
            let selected = model.paneSelection[pane] ?? localTabs[0].id
            return SavedPane(id: pane, terminals: localTabs.map { original in
                var tab = original
                if !tab.customTitle { tab.title = "终端" }
                let cwd = model.terminals[tab.id]?.directory ?? model.terminalDirectories[tab.id] ?? workspace.directory
                return SavedTerminal(tab: tab, directory: cwd)
            }, selectedTerminalID: localTabs.contains(where: { $0.id == selected }) ? selected : localTabs[0].id)
        }
    }

    func restore() -> Workspace {
        var workspace = Workspace(name: name, directory: directory)
        workspace.id = id; workspace.description = description
        workspace.color = color; workspace.isPinned = isPinned
        workspace.services = services ?? []
        if let tabs, !tabs.isEmpty {
            workspace.tabs = tabs
            workspace.selectedTabID = selectedTabID.flatMap { id in tabs.contains(where: { $0.id == id }) ? id : nil } ?? tabs[0].id
        }
        return workspace
    }
}

private struct SavedPane: Codable {
    var id: UUID
    var terminals: [SavedTerminal]
    var selectedTerminalID: UUID
}

private struct SavedTerminal: Codable {
    var tab: PaneTerminalTab
    var directory: String
}

private enum WorkspaceArchiveError: LocalizedError {
    case invalid, version
    var errorDescription: String? {
        switch self {
        case .invalid: return L("工作区配置格式不正确或超过大小限制。")
        case .version: return L("不支持此工作区配置版本。")
        }
    }
}
