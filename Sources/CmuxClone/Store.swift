import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()
    private let defaults: UserDefaults
    private var appearanceObservation: NSKeyValueObservation?
    private var lastAppliedDark: Bool?
    @Published var appearance: AppAppearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: "appAppearance")
            applyApplicationAppearance()
            applyTerminalSettings()
        }
    }
    @Published var terminal: TerminalSettings {
        didSet {
            if let data = try? JSONEncoder().encode(terminal) { defaults.set(data, forKey: "terminalSettings") }
            applyTerminalSettings()
        }
    }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let settings = defaults.data(forKey: "terminalSettings").flatMap { try? JSONDecoder().decode(TerminalSettings.self, from: $0) } ?? TerminalSettings()
        terminal = settings
        // Retain an explicit dark terminal choice from older versions.
        appearance = defaults.string(forKey: "appAppearance").flatMap(AppAppearance.init(rawValue:)) ?? (settings.theme == "dark" ? .dark : .system)
    }
    var effectiveTerminalSettings: TerminalSettings {
        terminalSettings(for: NSApp.effectiveAppearance)
    }
    func terminalSettings(for systemAppearance: NSAppearance) -> TerminalSettings {
        var settings = terminal
        settings.theme = appearance.isDark(systemAppearance: systemAppearance) ? "dark" : (terminal.theme == "paper" ? "paper" : "light")
        return settings
    }
    func adjustFontSize(by delta: Double) {
        let size = min(40, max(9, terminal.fontSize + delta))
        guard size != terminal.fontSize else { return }
        terminal.fontSize = size
    }
    func applyApplicationAppearance() { NSApp.appearance = appearance.nativeAppearance }
    func observeSystemAppearance() {
        applyApplicationAppearance()
        lastAppliedDark = effectiveTerminalSettings.theme == "dark"
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.systemAppearanceDidChange() }
        }
    }
    private func systemAppearanceDidChange() {
        guard appearance == .system, lastAppliedDark != (effectiveTerminalSettings.theme == "dark") else { return }
        applyTerminalSettings()
    }
    private func applyTerminalSettings() {
        let settings = effectiveTerminalSettings
        lastAppliedDark = settings.theme == "dark"
        GhosttyEngine.shared.apply(settings)
    }
}

@MainActor
final class WindowModel: ObservableObject {
    let tools = WorkspaceToolsState()
    let shellCommandOverride: String?
    var onWorkspaceChange: (() -> Void)?
    @Published var isDisposed = false
    @Published var workspaces: [Workspace] { didSet { onWorkspaceChange?() } }
    @Published var selectedWorkspaceID: UUID { didSet { onWorkspaceChange?() } }
    @Published var showCommands = true
    @Published var showSidebar = true
    @Published var showSettings = false
    @Published var showFind = false
    @Published var showQuickOpen = false
    @Published var findText = ""
    @Published var error: String?
    @Published var serviceStatuses: [UUID: ServiceStatus] = [:]
    @Published var quickTunnelStatuses: [UUID: QuickTunnelStatus] = [:]
    var serviceOutputs: [UUID: ServiceOutput] = [:]
    var terminals: [UUID: GhosttyTerminalView] = [:]
    var serviceProcesses: [UUID: ServiceProcess] = [:]
    var quickTunnelProcesses: [UUID: QuickTunnelProcess] = [:]
    @Published var paneTabs: [UUID: [PaneTerminalTab]] = [:] { didSet { if !isDisposed { onWorkspaceChange?() } } }
    @Published var paneSelection: [UUID: UUID] = [:] { didSet { if !isDisposed { onWorkspaceChange?() } } }
    var terminalDirectories: [UUID: String] = [:] { didSet { if !isDisposed { onWorkspaceChange?() } } }
    weak var window: NSWindow?

    init(workspaces initial: [Workspace]? = nil, shellCommand: String? = nil) {
        shellCommandOverride = shellCommand
        if let initial, !initial.isEmpty {
            workspaces = initial; selectedWorkspaceID = initial[0].id
        } else {
            let directory = NSHomeDirectory()
            let workspace = Workspace(name: L("本地终端"), directory: directory)
            workspaces = [workspace]; selectedWorkspaceID = workspace.id
        }
        tools.onSessionChange = { [weak self] in
            guard let self, !self.isDisposed else { return }
            self.onWorkspaceChange?()
        }
    }
    var workspaceIndex: Int? { workspaces.firstIndex { $0.id == selectedWorkspaceID } }
    var workspace: Workspace? { workspaces.first { $0.id == selectedWorkspaceID } }
    var selectedTab: TerminalTab? { workspace?.tabs.first { $0.id == workspace?.selectedTabID } }
    var focusedTerminal: GhosttyTerminalView? { selectedTab.flatMap { terminals[activeTerminalID($0.focusedPane)] } }
    var title: String { workspace?.name ?? "vsux" }

    func terminal(_ id: UUID) -> GhosttyTerminalView {
        if let view = terminals[id] { return view }
        let view = GhosttyTerminalView(paneID: id, directory: startingDirectory(for: id), command: shellCommandOverride)
        view.model = self
        if isDisposed { view.shutdown(); return view }
        terminals[id] = view
        return view
    }
    func startingDirectory(for terminalID: UUID) -> String {
        // A restored inactive workspace may create its views before selection changes.
        let owner = workspaces.first { workspace in
            workspace.tabs.contains { tab in tab.layout.leaves.contains { localTabs($0).contains { $0.id == terminalID } } }
        }
        for path in [terminalDirectories[terminalID], owner?.directory, NSHomeDirectory()].compactMap({ $0 }) {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue { return path }
        }
        return NSHomeDirectory()
    }
    func updateDirectory(terminalID: UUID, directory: String) {
        guard !isDisposed, (directory as NSString).isAbsolutePath, !directory.contains("\0"), terminalDirectories[terminalID] != directory else { return }
        terminalDirectories[terminalID] = directory
    }
    func mutateTab(_ change: (inout TerminalTab) -> Void) {
        guard let wi = workspaceIndex, let ti = workspaces[wi].tabs.firstIndex(where: { $0.id == workspaces[wi].selectedTabID }) else { return }
        change(&workspaces[wi].tabs[ti])
    }
    func focus(_ terminalOrPane: UUID) {
        let pane = paneContaining(terminalOrPane)
        if terminalOrPane != pane && paneSelection[pane] != terminalOrPane { paneSelection[pane] = terminalOrPane }
        focusPane(pane)
    }
    func focusPane(_ pane: UUID) {
        if selectedTab?.focusedPane != pane { mutateTab { $0.focusedPane = pane } }
    }
    func focusTerminal() {
        guard tools.content == .terminal else { return }
        guard let pane = selectedTab?.focusedPane else { return }
        let id = activeTerminalID(pane)
        DispatchQueue.main.async { [weak self] in
            guard let self, let view = self.terminals[id], view.window != nil else { return }
            view.window?.makeFirstResponder(view)
        }
    }
    func selectWorkspace(_ id: UUID) {
        selectedWorkspaceID = id; showFind = false; window?.title = title; focusTerminal()
    }
    func selectTab(_ id: UUID) {
        guard let wi = workspaceIndex else { return }
        workspaces[wi].selectedTabID = id; showFind = false; focusTerminal()
    }
    func addWorkspace() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = L("创建工作区"); panel.message = L("选择新工作区的启动目录")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addWorkspace(at: url)
    }
    func addWorkspace(at url: URL) {
        let value = Workspace(name: url.lastPathComponent, directory: url.path)
        workspaces.append(value); selectWorkspace(value.id)
    }
    func renameWorkspace(_ id: UUID) {
        guard let wi = workspaces.firstIndex(where: { $0.id == id }), let name = askText(title: L("重命名工作区"), value: workspaces[wi].name) else { return }
        workspaces[wi].name = name; window?.title = title
    }
    func describeWorkspace(_ id: UUID) {
        guard let wi = workspaces.firstIndex(where: { $0.id == id }), let text = askText(title: L("工作区描述"), value: workspaces[wi].description, allowEmpty: true) else { return }
        workspaces[wi].description = text
    }
    func closeWorkspace(_ id: UUID) {
        guard let wi = workspaces.firstIndex(where: { $0.id == id }) else { return }
        let ids = workspaces[wi].tabs.flatMap { $0.layout.leaves }
        guard confirmClose(ids, title: L("关闭“\(workspaces[wi].name)”？")) else { return }
        stopServices(in: id)
        stopQuickTunnel(in: id)
        quickTunnelStatuses.removeValue(forKey: id)
        dispose(ids); workspaces.remove(at: wi)
        if workspaces.isEmpty {
            let value = Workspace(name: L("本地终端"), directory: NSHomeDirectory()); workspaces.append(value)
        }
        if selectedWorkspaceID == id { selectWorkspace(workspaces[min(wi, workspaces.count - 1)].id) }
    }
    func pinWorkspace(_ id: UUID) {
        guard let i = workspaces.firstIndex(where: { $0.id == id }) else { return }
        workspaces[i].isPinned.toggle()
        workspaces = workspaces.filter(\.isPinned) + workspaces.filter { !$0.isPinned }
    }
    func colorWorkspace(_ id: UUID, color: String) {
        guard let i = workspaces.firstIndex(where: { $0.id == id }) else { return }
        workspaces[i].color = color
    }
    func moveWorkspace(_ id: UUID, to target: UUID) {
        guard let from = workspaces.firstIndex(where: { $0.id == id }), let to = workspaces.firstIndex(where: { $0.id == target }), from != to else { return }
        let value = workspaces.remove(at: from); workspaces.insert(value, at: to)
    }
    func addTab() {
        guard let wi = workspaceIndex else { return }
        let tab = TerminalTab()
        workspaces[wi].tabs.append(tab); workspaces[wi].selectedTabID = tab.id; focusTerminal()
    }
    func renameTab(_ id: UUID) {
        guard let wi = workspaceIndex, let ti = workspaces[wi].tabs.firstIndex(where: { $0.id == id }), let name = askText(title: L("重命名终端"), value: workspaces[wi].tabs[ti].title) else { return }
        workspaces[wi].tabs[ti].title = name; workspaces[wi].tabs[ti].customTitle = true
    }
    func pinTab(_ id: UUID) {
        guard let wi = workspaceIndex, let ti = workspaces[wi].tabs.firstIndex(where: { $0.id == id }) else { return }
        workspaces[wi].tabs[ti].isPinned.toggle()
        workspaces[wi].tabs = workspaces[wi].tabs.filter(\.isPinned) + workspaces[wi].tabs.filter { !$0.isPinned }
    }
    func closeTab(_ id: UUID) {
        guard let wi = workspaceIndex, let ti = workspaces[wi].tabs.firstIndex(where: { $0.id == id }) else { return }
        let ids = workspaces[wi].tabs[ti].layout.leaves
        guard confirmClose(ids, title: L("关闭终端？")) else { return }
        dispose(ids); workspaces[wi].tabs.remove(at: ti)
        if workspaces[wi].tabs.isEmpty { workspaces[wi].tabs.append(TerminalTab()) }
        if workspaces[wi].selectedTabID == id { workspaces[wi].selectedTabID = workspaces[wi].tabs[min(ti, workspaces[wi].tabs.count - 1)].id }
        focusTerminal()
    }
    func moveTab(_ id: UUID, to target: UUID) {
        guard let wi = workspaceIndex, let from = workspaces[wi].tabs.firstIndex(where: { $0.id == id }), let to = workspaces[wi].tabs.firstIndex(where: { $0.id == target }), from != to else { return }
        let tab = workspaces[wi].tabs.remove(at: from); workspaces[wi].tabs.insert(tab, at: to)
    }
    func moveTabToWorkspace(_ id: UUID, destination: UUID) {
        guard let wi = workspaceIndex, let to = workspaces.firstIndex(where: { $0.id == destination }), wi != to, let ti = workspaces[wi].tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = workspaces[wi].tabs.remove(at: ti)
        workspaces[to].tabs.append(tab); workspaces[to].selectedTabID = id
        if workspaces[wi].tabs.isEmpty { workspaces[wi].tabs.append(TerminalTab()) }
        if workspaces[wi].selectedTabID == id { workspaces[wi].selectedTabID = workspaces[wi].tabs[0].id }
        selectWorkspace(destination)
    }
    func split(_ axis: SplitAxis, before: Bool = false) {
        guard let tab = selectedTab else { return }
        let new = UUID()
        let directory = focusedTerminal?.directory ?? workspace?.directory ?? NSHomeDirectory()
        let view = GhosttyTerminalView(paneID: new, directory: directory, command: shellCommandOverride); view.model = self; terminals[new] = view
        mutateTab { $0.layout = $0.layout.splitting(tab.focusedPane, new: new, axis: axis, before: before); $0.focusedPane = new; $0.zoomedPane = nil }
        focusTerminal()
    }
    func closePane(_ id: UUID) {
        guard let tab = selectedTab else { return }
        if tab.layout.leaves.count == 1 { closeTab(tab.id); return }
        guard confirmClose([id], title: L("关闭此分屏？")), let next = tab.layout.removing(id) else { return }
        dispose([id]); mutateTab { $0.layout = next; $0.focusedPane = next.leaves[0]; $0.zoomedPane = nil }; focusTerminal()
    }
    func zoom(_ id: UUID) { mutateTab { $0.zoomedPane = $0.zoomedPane == id ? nil : id; $0.focusedPane = id }; focusTerminal() }
    func equalize() { mutateTab { $0.layout = $0.layout.equalized() } }
    func resize(_ id: UUID, fraction: Double) { mutateTab { $0.layout = $0.layout.resized(id, fraction: fraction) } }
    func extractPane(_ id: UUID) {
        guard let wi = workspaceIndex, let tab = selectedTab, tab.layout.leaves.count > 1, let remaining = tab.layout.removing(id) else { return }
        mutateTab { $0.layout = remaining; $0.focusedPane = remaining.leaves[0]; $0.zoomedPane = nil }
        let new = TerminalTab(pane: id); workspaces[wi].tabs.append(new); workspaces[wi].selectedTabID = new.id; focusTerminal()
    }
    func mergeTab(_ id: UUID) {
        guard let wi = workspaceIndex, let selected = selectedTab, id != selected.id, let other = workspaces[wi].tabs.first(where: { $0.id == id }) else { return }
        // Publish the move atomically: no snapshot may contain the same pane twice.
        var tabs = workspaces[wi].tabs
        guard let index = tabs.firstIndex(where: { $0.id == selected.id }) else { return }
        tabs[index].layout = .split(id: UUID(), axis: .horizontal, fraction: 0.5, first: selected.layout, second: other.layout)
        tabs[index].zoomedPane = nil
        tabs.removeAll { $0.id == id }
        workspaces[wi].tabs = tabs
    }
    func insertCommand(_ command: String) {
        guard let pane = selectedTab?.focusedPane else { error = L("请先选择一个终端。"); return }
        tools.content = .terminal
        let view = terminal(activeTerminalID(pane))
        view.pasteText(commandForInsertion(command))
        focusTerminal()
    }
    func updateTitle(pane terminalID: UUID, title: String) {
        let pane = paneContaining(terminalID)
        let clean = String(title.components(separatedBy: .controlCharacters).joined().prefix(70))
        if let index = paneTabs[pane]?.firstIndex(where: { $0.id == terminalID }), paneTabs[pane]?[index].customTitle != true {
            paneTabs[pane]?[index].title = clean
        }
        for wi in workspaces.indices {
            if let ti = workspaces[wi].tabs.firstIndex(where: { $0.layout.leaves.contains(pane) }), !workspaces[wi].tabs[ti].customTitle {
                workspaces[wi].tabs[ti].title = clean; return
            }
        }
    }
    func confirmClose(_ ids: [UUID], title: String) -> Bool {
        guard surfaceIDs(for: ids).contains(where: { terminals[$0]?.needsConfirmation == true }) else { return true }
        return confirm(title: title, detail: L("终端中仍有运行的进程，关闭后进程将结束。"), action: L("关闭"))
    }
    func canCloseWindow() -> Bool {
        guard terminals.values.contains(where: { $0.needsConfirmation }) else { return true }
        return confirm(title: L("关闭窗口和全部终端？"), detail: L("终端中仍有运行的进程，关闭后进程将结束。"), action: L("关闭"))
    }
    func dispose(_ ids: [UUID]) {
        for id in surfaceIDs(for: ids) { terminals[id]?.shutdown(); terminals.removeValue(forKey: id); terminalDirectories.removeValue(forKey: id) }
        for id in ids { paneTabs.removeValue(forKey: id); paneSelection.removeValue(forKey: id) }
    }
    func disposeAll() {
        isDisposed = true
        stopAllServices()
        stopAllQuickTunnels()
        terminals.values.forEach { $0.shutdown() }; terminals.removeAll()
        terminalDirectories.removeAll()
        paneTabs.removeAll(); paneSelection.removeAll()
    }
    func find(_ direction: String? = nil) {
        guard let terminal = focusedTerminal else { return }
        if let direction { terminal.action("navigate_search:\(direction)") }
        else { terminal.action("search:\(findText)") }
    }
}

@MainActor
func askText(title: String, value: String, allowEmpty: Bool = false) -> String? {
    let alert = NSAlert(); alert.messageText = title; alert.addButton(withTitle: L("保存")); alert.addButton(withTitle: L("取消"))
    let field = NSTextField(string: value); field.frame = NSRect(x: 0, y: 0, width: 300, height: 26); alert.accessoryView = field
    alert.window.initialFirstResponder = field
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    let result = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    return allowEmpty || !result.isEmpty ? result : nil
}

@MainActor
func confirm(title: String, detail: String, action: String) -> Bool {
    let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = title; alert.informativeText = detail
    alert.addButton(withTitle: action); alert.addButton(withTitle: L("取消"))
    return alert.runModal() == .alertFirstButtonReturn
}

extension WindowModel {
    func processExited(_ terminalID: UUID) {
        guard !isDisposed else { return }
        let id = paneContaining(terminalID)
        if localTabs(id).count > 1 { removeLocalTab(terminalID, pane: id); return }
        for wi in workspaces.indices {
            guard let ti = workspaces[wi].tabs.firstIndex(where: { $0.layout.leaves.contains(id) }) else { continue }
            let tab = workspaces[wi].tabs[ti]
            dispose([id])
            if let layout = tab.layout.removing(id) {
                workspaces[wi].tabs[ti].layout = layout
                workspaces[wi].tabs[ti].focusedPane = layout.leaves[0]
                workspaces[wi].tabs[ti].zoomedPane = nil
            } else {
                workspaces[wi].tabs.remove(at: ti)
                if workspaces[wi].tabs.isEmpty { workspaces[wi].tabs = [TerminalTab()] }
                if workspaces[wi].selectedTabID == tab.id { workspaces[wi].selectedTabID = workspaces[wi].tabs[0].id }
            }
            focusTerminal(); return
        }
    }
}

@MainActor
extension WindowModel {
    func paneContaining(_ terminal: UUID) -> UUID {
        paneTabs.first(where: { $0.value.contains(where: { $0.id == terminal }) })?.key ?? terminal
    }
    func localTabs(_ pane: UUID) -> [PaneTerminalTab] { paneTabs[pane] ?? [PaneTerminalTab(id: pane)] }
    func activeTerminalID(_ pane: UUID) -> UUID { paneSelection[pane] ?? localTabs(pane).first!.id }
    func surfaceIDs(for panes: [UUID]) -> [UUID] { Array(Set(panes.flatMap { paneTabs[$0]?.map(\.id) ?? [$0] })) }
    func addLocalTab(_ pane: UUID) {
        var tabs = localTabs(pane)
        let id = UUID()
        let cwd = terminals[activeTerminalID(pane)]?.directory ?? workspace?.directory ?? NSHomeDirectory()
        let view = GhosttyTerminalView(paneID: id, directory: cwd, command: shellCommandOverride); view.model = self; terminals[id] = view
        tabs.append(PaneTerminalTab(id: id))
        paneTabs[pane] = tabs; paneSelection[pane] = id
        focusPane(pane); focusTerminal()
    }
    func selectLocalTab(_ id: UUID, pane: UUID) { paneSelection[pane] = id; focusPane(pane); focusTerminal() }
    func closeLocalTab(_ id: UUID, pane: UUID) {
        if localTabs(pane).count == 1 { closePane(pane); return }
        if terminals[id]?.needsConfirmation == true && !confirm(title: L("关闭分屏中的终端？"), detail: L("仍有运行的进程，关闭后进程将结束。"), action: L("关闭")) { return }
        removeLocalTab(id, pane: pane)
    }
    func removeLocalTab(_ id: UUID, pane: UUID) {
        let tabs = localTabs(pane).filter { $0.id != id }
        terminals[id]?.shutdown(); terminals.removeValue(forKey: id)
        terminalDirectories.removeValue(forKey: id)
        paneTabs[pane] = tabs
        if activeTerminalID(pane) == id || !tabs.contains(where: { $0.id == activeTerminalID(pane) }) { paneSelection[pane] = tabs.first?.id }
        focusTerminal()
    }
    func renameLocalTab(_ id: UUID, pane: UUID) {
        var tabs = localTabs(pane)
        guard let index = tabs.firstIndex(where: { $0.id == id }), let name = askText(title: L("重命名分屏 Tab"), value: tabs[index].title) else { return }
        tabs[index].title = name; tabs[index].customTitle = true; paneTabs[pane] = tabs
    }
    func reorderLocalTab(_ id: UUID, pane: UUID, target: UUID) {
        var tabs = localTabs(pane)
        guard let from = tabs.firstIndex(where: { $0.id == id }), let to = tabs.firstIndex(where: { $0.id == target }), from != to else { return }
        let tab = tabs.remove(at: from); tabs.insert(tab, at: to); paneTabs[pane] = tabs
    }
    func extractLocalTab(_ id: UUID, pane: UUID) {
        guard localTabs(pane).count > 1, let wi = workspaceIndex else { return }
        let extracted = localTabs(pane).first { $0.id == id }
        let remaining = localTabs(pane).filter { $0.id != id }
        paneTabs[pane] = remaining
        if paneSelection[pane] == id { paneSelection[pane] = remaining[0].id }
        // The pane ID stays stable; extracted surfaces receive a new pane identity.
        let newPane = UUID()
        paneTabs[newPane] = [extracted ?? PaneTerminalTab(id: id)]
        paneSelection[newPane] = id
        let tab = TerminalTab(pane: newPane)
        workspaces[wi].tabs.append(tab); workspaces[wi].selectedTabID = tab.id; focusTerminal()
    }
    func transferPanes(_ panes: [UUID], to destination: WindowModel) {
        let ids = surfaceIDs(for: panes)
        for pane in panes {
            destination.paneTabs[pane] = paneTabs.removeValue(forKey: pane)
            destination.paneSelection[pane] = paneSelection.removeValue(forKey: pane)
        }
        for id in ids {
            destination.terminalDirectories[id] = terminalDirectories.removeValue(forKey: id)
            if let terminal = terminals.removeValue(forKey: id) {
                terminal.removeFromSuperview(); terminal.model = destination; destination.terminals[id] = terminal
            }
        }
    }
}
