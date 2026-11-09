import AppKit
import SwiftUI
import CGhostty

@main
struct VsuxMain {
    static func main() {
        // Resources belong to this app; the terminal does not depend on an installed cmux.
        let resources = Bundle.main.resourceURL?.appendingPathComponent("ghostty").path
        if let resources, FileManager.default.fileExists(atPath: resources) {
            setenv("GHOSTTY_RESOURCES_DIR", resources, 1)
            setenv("TERMINFO", URL(fileURLWithPath: resources).deletingLastPathComponent().appendingPathComponent("terminfo").path, 1)
        }
        setenv("TERM_PROGRAM", "vsux", 1)
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate.shared
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    static let shared = AppDelegate()
    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(languageDidChange(_:)), name: .appLanguageDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(shortcutsDidChange(_:)), name: .keyboardShortcutsDidChange, object: nil)
    }
    var windows: [TerminalWindowController] = []
    private lazy var workspaceSession = WorkspaceSession()
    private var workspacePersistenceEnabled = false
    var current: WindowModel? { windows.first { $0.window === NSApp.keyWindow }?.model }
    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = LanguagePreferences.shared
        Preferences.shared.observeSystemAppearance()
        _ = GhosttyEngine.shared
        makeMenus()
        workspacePersistenceEnabled = true
        newWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc func newWindow(_ sender: Any?) {
        let restored = workspacePersistenceEnabled && windows.isEmpty ? workspaceSession.restore() : []
        let models = restored.isEmpty ? [WindowModel()] : restored
        if workspacePersistenceEnabled, let workspaceID = models.last?.workspace?.id {
            CommandLibrary.shared.migrateLegacyCommands(to: workspaceID)
        }
        for model in models { presentWindow(TerminalWindowController(model: model), save: false) }
        if workspacePersistenceEnabled { workspaceSession.save() }
    }
    private func presentWindow(_ controller: TerminalWindowController, save: Bool = true) {
        windows.append(controller)
        if workspacePersistenceEnabled { workspaceSession.register(controller.model) }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        if save && workspacePersistenceEnabled { workspaceSession.save() }
    }
    func removeWindow(_ controller: TerminalWindowController) {
        if workspacePersistenceEnabled && !workspaceSession.isSuspended { workspaceSession.unregister(controller.model) }
        windows.removeAll { $0 === controller }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { if !flag { newWindow(nil) }; return true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        for controller in windows where !controller.model.canCloseWindow() { return .terminateCancel }
        if workspacePersistenceEnabled { workspaceSession.finish() }
        windows.forEach { $0.model.disposeAll() }; return .terminateNow
    }
    func applicationDidBecomeActive(_ notification: Notification) { ghostty_app_set_focus(GhosttyEngine.shared.app, true) }
    func applicationDidResignActive(_ notification: Notification) { ghostty_app_set_focus(GhosttyEngine.shared.app, false) }
    func moveWorkspace(_ id: UUID, from source: WindowModel) {
        guard let index = source.workspaces.firstIndex(where: { $0.id == id }) else { return }
        let workspace = source.workspaces[index]
        let destination = WindowModel(workspaces: [workspace], shellCommand: source.shellCommandOverride)
        source.transferServices(in: workspace.id, to: destination)
        source.transferQuickTunnel(in: workspace.id, to: destination)
        source.workspaces.remove(at: index)
        source.tools.transferFiles(for: workspace.id, to: destination.tools)
        source.transferPanes(workspace.tabs.flatMap { $0.layout.leaves }, to: destination)
        let controller = TerminalWindowController(model: destination)
        if source.workspaces.isEmpty {
            let replacement = Workspace(name: L("本地终端"), directory: NSHomeDirectory()); source.workspaces = [replacement]
        }
        source.selectWorkspace(source.workspaces[0].id)
        presentWindow(controller)
    }
    func detachTab(_ id: UUID, from source: WindowModel) {
        guard let wi = source.workspaceIndex, let ti = source.workspaces[wi].tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = source.workspaces[wi].tabs.remove(at: ti)
        var workspace = Workspace(name: tab.title, directory: source.workspace?.directory ?? NSHomeDirectory())
        workspace.tabs = [tab]; workspace.selectedTabID = tab.id
        let destination = WindowModel(workspaces: [workspace], shellCommand: source.shellCommandOverride)
        source.transferPanes(tab.layout.leaves, to: destination)
        let controller = TerminalWindowController(model: destination)
        if source.workspaces[wi].tabs.isEmpty { source.workspaces[wi].tabs = [TerminalTab()] }
        source.workspaces[wi].selectedTabID = source.workspaces[wi].tabs[0].id
        presentWindow(controller)
    }
    @objc func newWorkspace(_ sender: Any?) { current?.addWorkspace() }
    @objc func newTab(_ sender: Any?) { current?.addTab() }
    @objc func closePane(_ sender: Any?) { if let model = current, let pane = model.selectedTab?.focusedPane { model.closeLocalTab(model.activeTerminalID(pane), pane: pane) } }
    @objc func splitRight(_ sender: Any?) { current?.split(.horizontal) }
    @objc func splitBelow(_ sender: Any?) { current?.split(.vertical) }
    @objc func equalize(_ sender: Any?) { current?.equalize() }
    @objc func find(_ sender: Any?) { if let current { beginFind(in: current) } }
    @objc func findFile(_ sender: Any?) { if let current { _ = beginFileFind(in: current) } }
    @discardableResult
    func beginFileFind(in model: WindowModel) -> Bool {
        guard model.tools.content == .editor, let workspace = model.workspace,
              let document = model.tools.files(workspace).selectedDocument else { return false }
        document.findRequest = UUID(); return true
    }
    func beginFind(in model: WindowModel) {
        if model.tools.content == .editor {
            beginFileFind(in: model)
        } else { model.showFind = true }
    }
    @objc func findInFiles(_ sender: Any?) {
        guard let model = current, let workspace = model.workspace else { return }
        model.showSidebar = true; model.tools.sidebar = .files; model.tools.showFileSearch = true
        model.tools.files(workspace).search.focusRequest = UUID()
    }
    @objc func saveFile(_ sender: Any?) {
        guard let model = current, model.tools.content == .editor, let workspace = model.workspace else { return }
        model.tools.files(workspace).saveSelected()
    }
    @objc func quickOpen(_ sender: Any?) { current?.showQuickOpen = true }
    @objc func settings(_ sender: Any?) { current?.showSettings = true }
    @objc func increaseFontSize(_ sender: Any?) { Preferences.shared.adjustFontSize(by: 1) }
    @objc func decreaseFontSize(_ sender: Any?) { Preferences.shared.adjustFontSize(by: -1) }
    @objc func sidebar(_ sender: Any?) { current?.showSidebar.toggle() }
    @objc func commands(_ sender: Any?) { current?.showCommands.toggle() }
    @objc func toggleMarkdownPreview(_ sender: Any?) {
        guard let model = current, model.tools.content == .editor, let workspace = model.workspace,
              let document = model.tools.files(workspace).selectedDocument, document.language == .markdown else { return }
        document.markdownPreview.toggle()
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(findFile(_:)) {
            guard let model = current, model.tools.content == .editor, let workspace = model.workspace else { return false }
            return model.tools.files(workspace).selectedDocument != nil
        }
        if menuItem.action == #selector(saveFile(_:)) {
            guard let model = current, model.tools.content == .editor, let workspace = model.workspace else { return false }
            return model.tools.files(workspace).selectedDocument != nil
        }
        if menuItem.action == #selector(toggleMarkdownPreview(_:)) {
            guard let model = current, model.tools.content == .editor, let workspace = model.workspace,
                  let document = model.tools.files(workspace).selectedDocument, document.language == .markdown else { return false }
            menuItem.state = document.markdownPreview ? .on : .off
        }
        return true
    }
    @discardableResult
    func performShortcut(_ command: AppCommand, in window: NSWindow) -> Bool {
        guard let model = (window.windowController as? TerminalWindowController)?.model else { return false }
        switch command {
        case .quickOpen: model.showQuickOpen = true
        case .settings: model.showSettings = true
        case .newWorkspace: model.addWorkspace()
        case .newTab: model.addTab()
        case .closePane:
            if let pane = model.selectedTab?.focusedPane { model.closeLocalTab(model.activeTerminalID(pane), pane: pane) }
        case .saveFile:
            guard model.tools.content == .editor, let workspace = model.workspace,
                  model.tools.files(workspace).selectedDocument != nil else { return false }
            model.tools.files(workspace).saveSelected()
        case .find: beginFind(in: model)
        case .findFile: return beginFileFind(in: model)
        case .findInFiles:
            guard let workspace = model.workspace else { return false }
            model.showSidebar = true; model.tools.sidebar = .files; model.tools.showFileSearch = true
            model.tools.files(workspace).search.focusRequest = UUID()
        case .splitRight: model.split(.horizontal)
        case .splitBelow: model.split(.vertical)
        case .equalize: model.equalize()
        case .markdownPreview:
            guard model.tools.content == .editor, let workspace = model.workspace,
                  let document = model.tools.files(workspace).selectedDocument, document.language == .markdown else { return false }
            document.markdownPreview.toggle()
        case .increaseFont: Preferences.shared.adjustFontSize(by: 1)
        case .decreaseFont: Preferences.shared.adjustFontSize(by: -1)
        case .sidebar: model.showSidebar.toggle()
        case .commands: model.showCommands.toggle()
        case .closeWindow: window.performClose(nil)
        case .fullScreen: window.toggleFullScreen(nil)
        case .minimize: window.performMiniaturize(nil)
        case .zoom: window.performZoom(nil)
        case .hide: NSApp.hide(nil)
        case .quit: NSApp.terminate(nil)
        case .newWindow: newWindow(nil)
        case .undo, .redo, .cut, .copy, .paste, .selectAll:
            return window.firstResponder?.tryToPerform(command.selector, with: window) ?? false
        }
        return true
    }
    @objc private func shortcutsDidChange(_ notification: Notification) { makeMenus() }
    @objc private func languageDidChange(_ notification: Notification) { makeMenus() }
    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, let language = AppLanguage(rawValue: value) else { return }
        LanguagePreferences.shared.language = language
    }
    func makeMenus() {
        let menu = NSMenu(); NSApp.mainMenu = menu
        func submenu(_ name: String) -> NSMenu { let item = NSMenuItem(); item.title = name; let sub = NSMenu(title: name); item.submenu = sub; menu.addItem(item); return sub }
        func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil) {
            let command = AppCommand.allCases.first { $0.selector == action }
            let binding = command.map { ShortcutPreferences.shared.binding(for: $0) } ?? KeyBinding(key, modifiers)
            let item = NSMenuItem(title: title, action: action, keyEquivalent: binding.key)
            item.keyEquivalentModifierMask = binding.modifiers
            item.target = target
            if let command { item.identifier = NSUserInterfaceItemIdentifier(command.rawValue) }
            menu.addItem(item)
        }
        let app = submenu("vsux")
        add(app, L("关于 vsux"), #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp)
        add(app, L("设置…"), #selector(settings(_:)), ",", target: self)
        let languageItem = NSMenuItem(title: L("界面语言"), action: nil, keyEquivalent: "")
        let languages = NSMenu(title: L("界面语言"))
        for language in AppLanguage.allCases {
            let item = NSMenuItem(title: language.title, action: #selector(selectLanguage(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = language.rawValue
            item.state = LanguagePreferences.shared.language == language ? .on : .off
            languages.addItem(item)
        }
        languageItem.submenu = languages; app.addItem(languageItem)
        app.addItem(.separator())
        add(app, L("隐藏 vsux"), #selector(NSApplication.hide(_:)), "h", target: NSApp)
        add(app, L("退出 vsux"), #selector(NSApplication.terminate(_:)), "q", target: NSApp)
        let file = submenu(L("文件"))
        add(file, L("新建窗口"), #selector(newWindow(_:)), "n", target: self)
        add(file, L("新建工作区…"), #selector(newWorkspace(_:)), "n", [.command, .shift], target: self)
        add(file, L("保存"), #selector(saveFile(_:)), "s", target: self)
        add(file, L("快速打开文件…"), #selector(quickOpen(_:)), "p", [.control], target: self)
        add(file, L("新建终端 Tab"), #selector(newTab(_:)), "t", target: self)
        add(file, L("关闭当前分屏"), #selector(closePane(_:)), "w", target: self)
        add(file, L("关闭窗口"), #selector(NSWindow.performClose(_:)), "w", [.command, .shift])
        let edit = submenu(L("编辑"))
        add(edit, L("撤销"), Selector(("undo:")), "z")
        add(edit, L("重做"), Selector(("redo:")), "z", [.command, .shift])
        edit.addItem(.separator())
        add(edit, L("剪切"), #selector(NSText.cut(_:)), "x")
        add(edit, L("复制"), #selector(NSText.copy(_:)), "c")
        add(edit, L("粘贴"), #selector(NSText.paste(_:)), "v")
        add(edit, L("全选"), #selector(NSText.selectAll(_:)), "a")
        add(edit, L("查找当前内容…"), #selector(find(_:)), "f", target: self)
        add(edit, L("查找当前文件…"), #selector(findFile(_:)), "f", [.control], target: self)
        add(edit, L("在文件中搜索…"), #selector(findInFiles(_:)), "f", [.command, .shift], target: self)
        let view = submenu(L("显示"))
        add(view, L("向右分屏"), #selector(splitRight(_:)), "d", target: self)
        add(view, L("向下分屏"), #selector(splitBelow(_:)), "d", [.command, .shift], target: self)
        add(view, L("均分分屏"), #selector(equalize(_:)), target: self)
        view.addItem(.separator())
        add(view, L("Markdown 侧边预览"), #selector(toggleMarkdownPreview(_:)), "v", [.command, .shift], target: self)
        add(view, L("增大字号"), #selector(increaseFontSize(_:)), "+", [.control], target: self)
        add(view, L("减小字号"), #selector(decreaseFontSize(_:)), "-", [.control], target: self)
        add(view, L("显示 / 隐藏工作区"), #selector(sidebar(_:)), target: self)
        add(view, L("显示 / 隐藏常用命令"), #selector(commands(_:)), target: self)
        add(view, L("进入全屏幕"), #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])
        let window = submenu(L("窗口")); NSApp.windowsMenu = window
        add(window, L("最小化"), #selector(NSWindow.performMiniaturize(_:)), "m")
        add(window, L("缩放"), #selector(NSWindow.performZoom(_:)))
    }
}

@MainActor
final class TerminalWindowController: NSWindowController, NSWindowDelegate {
    let model: WindowModel
    init(model initial: WindowModel? = nil) {
        let model = initial ?? WindowModel()
        self.model = model
        let window = PointerCursorWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.onShortcut = { [weak window] command in
            guard let window else { return false }
            return AppDelegate.shared.performShortcut(command, in: window)
        }
        window.acceptsMouseMovedEvents = true
        super.init(window: window)
        window.title = model.title; window.minSize = NSSize(width: 940, height: 560)
        window.tabbingMode = .disallowed; window.isReleasedWhenClosed = false
        window.center(); window.delegate = self; model.window = window
        window.contentView = NSHostingView(rootView: RootView(model: model))
        window.titlebarAppearsTransparent = true
        window.isOpaque = Preferences.shared.terminal.opacity >= 1
    }
    required init?(coder: NSCoder) { fatalError() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { model.canCloseWindow() }
    func windowWillClose(_ notification: Notification) {
        AppDelegate.shared.removeWindow(self)
        model.disposeAll()
    }
    func windowDidBecomeKey(_ notification: Notification) { model.focusTerminal() }
}
