import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct IconButton: View {
    @ObservedObject private var languagePreferences = LanguagePreferences.shared
    let symbol: String
    let help: String
    var action: () -> Void
    var body: some View {
        let _ = languagePreferences.language
        Button(action: action) { Image(systemName: symbol).font(.system(size: 12, weight: .medium)).frame(width: 26, height: 26).contentShape(Rectangle()) }
            .buttonStyle(.plain).pointingHandCursor().foregroundStyle(.secondary).help(help).accessibilityLabel(help)
    }
}

private struct WorkspaceContentSwitcher: View {
    @ObservedObject private var languagePreferences = LanguagePreferences.shared
    @ObservedObject var model: WindowModel
    @ObservedObject var tools: WorkspaceToolsState

    var body: some View {
        let _ = languagePreferences.language
        HStack(spacing: 2) {
            modeButton(.terminal, title: L("终端"), symbol: "terminal", help: L("显示终端")) {
                tools.content = .terminal
                model.focusTerminal()
            }
            modeButton(.editor, title: L("编辑器"), symbol: "doc.text", help: L("显示文件编辑器")) {
                tools.sidebar = .files
                model.showSidebar = true
                tools.content = .editor
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
        .fixedSize()
    }

    private func modeButton(_ mode: WorkspaceContentMode, title: String, symbol: String, help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: tools.content == mode ? .semibold : .medium))
                .padding(.horizontal, 12)
                .frame(height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(WorkspaceModeButtonStyle(selected: tools.content == mode))
        .pointingHandCursor()
        .help(help)
        .accessibilityAddTraits(tools.content == mode ? [.isSelected] : [])
    }
}

private struct WorkspaceModeButtonStyle: ButtonStyle {
    let selected: Bool
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .background {
                RoundedRectangle(cornerRadius: 5)
                    .fill(selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(hovered ? 0.06 : 0))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.45) : .clear, lineWidth: 1)
            }
            .opacity(configuration.isPressed ? 0.7 : 1)
            .onHover { hovered = $0 }
    }
}

struct RootView: View {
    @ObservedObject private var languagePreferences = LanguagePreferences.shared
    @ObservedObject var model: WindowModel
    @ObservedObject var tools: WorkspaceToolsState
    @ObservedObject var library = CommandLibrary.shared
    @ObservedObject var preferences = Preferences.shared
    @State private var sidebarWidth = 198.0
    @State private var gitSidebarWidth = 360.0
    @State private var searchSidebarWidth = 360.0
    @State private var commandsWidth = 280.0
    init(model: WindowModel) {
        self.model = model
        self.tools = model.tools
    }
    var body: some View {
        let _ = languagePreferences.language
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                IconButton(symbol: "sidebar.left", help: L("显示 / 隐藏工作区")) { model.showSidebar.toggle() }
                Text(model.title).font(.system(size: 13, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle).layoutPriority(-1)
                Divider().frame(height: 18).padding(.horizontal, 4)
                WorkspaceContentSwitcher(model: model, tools: tools)
                Spacer()
                LanguageMenu()
                AppearanceMenu(preferences: preferences)
                Menu {
                    Button(L("向右分屏")) { model.split(.horizontal) }
                    Button(L("向左分屏")) { model.split(.horizontal, before: true) }
                    Button(L("向下分屏")) { model.split(.vertical) }
                    Button(L("向上分屏")) { model.split(.vertical, before: true) }
                    Divider()
                    Button(L("均分分屏")) { model.equalize() }
                } label: { Image(systemName: "rectangle.split.2x1").frame(width: 28) }.menuStyle(.borderlessButton).pointingHandCursor().fixedSize().help(L("分屏"))
                IconButton(symbol: "magnifyingglass", help: L("查找终端内容")) { model.showFind.toggle() }
                IconButton(symbol: "sidebar.right", help: L("显示 / 隐藏常用命令")) { model.showCommands.toggle() }
            }.padding(.horizontal, 12).frame(height: 40).background(.bar)
            Divider()
            GeometryReader { geometry in
                let searchingFiles = tools.sidebar == .files && tools.showFileSearch
                let wideSidebar = tools.sidebar == .git || searchingFiles
                let sidebarMinimum = wideSidebar ? 280.0 : (tools.sidebar == .files ? 220.0 : 150.0)
                let sidebarMaximum = max(sidebarMinimum, min(wideSidebar ? 620.0 : 300.0, geometry.size.width - (model.showCommands ? commandsWidth : 0) - 370))
                let displayedSidebarWidth = min(sidebarMaximum, max(sidebarMinimum, searchingFiles ? searchSidebarWidth : (tools.sidebar == .git ? gitSidebarWidth : sidebarWidth)))
                HStack(spacing: 0) {
                    if model.showSidebar {
                        VStack(spacing: 0) {
                            SidebarSectionPicker(tools: tools)
                            Divider()
                            if let workspace = model.workspace {
                                switch tools.sidebar {
                                case .workspaces: WorkspaceSidebar(model: model)
                                case .files:
                                    if tools.showFileSearch {
                                        WorkspaceSearchPanel(model: tools.files(workspace).search, onOpen: { tools.content = .editor },
                                            onBack: { tools.showFileSearch = false }).id(workspace.id)
                                    } else {
                                        FileExplorerView(model: tools.files(workspace), onOpen: { tools.content = .editor },
                                            onSearch: { tools.showFileSearch = true })
                                    }
                                case .git:
                                    SourceControlPanel(model: tools.git(workspace), openFile: { url in
                                        tools.files(workspace).open(url, preview: false); tools.content = .editor
                                    }, showDiff: { tools.content = .diff })
                                }
                            }
                        }.frame(width: displayedSidebarWidth)
                        PanelDivider(width: searchingFiles ? $searchSidebarWidth : (tools.sidebar == .git ? $gitSidebarWidth : $sidebarWidth), maximum: sidebarMaximum, minimum: sidebarMinimum, direction: 1)
                    }
                    Group {
                        if let workspace = model.workspace {
                            switch tools.content {
                            case .terminal: TerminalArea(model: model)
                            case .editor: FileEditorArea(model: tools.files(workspace))
                            case .diff: LocalDiffArea(model: tools.git(workspace), showTerminal: { tools.content = .terminal; model.focusTerminal() })
                            }
                        }
                    }.frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity).layoutPriority(1)
                    if model.showCommands, let workspace = model.workspace {
                        PanelDivider(width: $commandsWidth, maximum: min(420, geometry.size.width - (model.showSidebar ? displayedSidebarWidth : 0) - 370), minimum: 240, direction: -1)
                        CommandSidebar(model: model, library: library, workspace: workspace)
                            .id(workspace.id).frame(width: commandsWidth)
                    }
                }
                .onChange(of: geometry.size.width) { _, width in
                    commandsWidth = min(commandsWidth, max(240, width - displayedSidebarWidth - 370))
                    sidebarWidth = min(sidebarWidth, max(150, width - commandsWidth - 370))
                    gitSidebarWidth = min(gitSidebarWidth, max(280, width - commandsWidth - 370))
                    searchSidebarWidth = min(searchSidebarWidth, max(280, width - commandsWidth - 370))
                }
            }
            .overlay(alignment: .bottomTrailing) {
                GitNotificationOverlay(store: tools.notifications, showOutput: showNotificationOutput)
            }
            Divider()
            GitNotificationStatusBar(store: tools.notifications)
        }
        .overlay {
            if model.showQuickOpen, let workspace = model.workspace {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.22).ignoresSafeArea().onTapGesture { model.showQuickOpen = false }
                    QuickOpenPanel(files: tools.files(workspace), onOpen: {
                        tools.sidebar = .files
                        tools.showFileSearch = false
                        tools.content = .editor
                        model.showQuickOpen = false
                    }, onDismiss: { model.showQuickOpen = false })
                        .padding(.top, 48)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(.blue)
        .environment(\.locale, languagePreferences.language.locale)
        .sheet(isPresented: $model.showSettings) { SettingsView(preferences: preferences) }
        .alert(L("操作未完成"), isPresented: Binding(get: { model.error != nil || library.error != nil }, set: { if !$0 { model.error = nil; library.error = nil } })) {
            Button(L("好")) { model.error = nil; library.error = nil }
        } message: { Text(model.error ?? library.error ?? "") }
    }

    private func showNotificationOutput(_ notice: GitNotice) {
        guard let workspace = model.workspaces.first(where: { $0.id == notice.workspaceID }) else { return }
        model.selectWorkspace(workspace.id)
        model.showSidebar = true; tools.sidebar = .git; tools.content = .diff
        tools.notifications.isCenterVisible = false
        tools.notifications.hideToast(notice.id)
        let git = tools.git(workspace)
        git.selectRepository(notice.repositoryURL)
        Task { await git.showGitOutput() }
    }
}

struct WorkspaceSidebar: View {
    @ObservedObject private var languagePreferences = LanguagePreferences.shared
    @ObservedObject var model: WindowModel
    static let colors: [(String, Color)] = [("blue", .blue), ("green", .green), ("orange", .orange), ("purple", .purple), ("red", .red), ("gray", .gray)]
    static func colorTitle(_ name: String) -> String {
        switch name {
        case "blue": return L("蓝色")
        case "green": return L("绿色")
        case "orange": return L("橙色")
        case "purple": return L("紫色")
        case "red": return L("红色")
        default: return L("灰色")
        }
    }
    var body: some View {
        let _ = languagePreferences.language
        VStack(spacing: 0) {
            HStack { Text(L("工作区")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary); Spacer(); IconButton(symbol: "plus", help: L("新建工作区")) { model.addWorkspace() } }.padding(.leading, 14).padding(.trailing, 8).frame(height: 39)
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(model.workspaces) { workspace in
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 2).fill(Self.colors.first { $0.0 == workspace.color }?.1 ?? .blue).frame(width: 4, height: 25)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(workspace.name).font(.system(size: 13, weight: model.selectedWorkspaceID == workspace.id ? .semibold : .regular)).lineLimit(1)
                                if !workspace.description.isEmpty { Text(workspace.description).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
                            }
                            Spacer(minLength: 0)
                            if workspace.services.contains(where: { model.serviceStatuses[$0.id] == .running }) {
                                Circle().fill(.green).frame(width: 8, height: 8).help(L("有运行中的服务"))
                            }
                            if workspace.isPinned { Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(.secondary) }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 10)
                        .background(model.selectedWorkspaceID == workspace.id ? Color.blue.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle()).pointingHandCursor().onTapGesture { model.selectWorkspace(workspace.id) }
                        .accessibilityElement(children: .combine).accessibilityAddTraits(.isButton)
                        .onDrag { NSItemProvider(object: ("workspace:" + workspace.id.uuidString) as NSString) }
                        .onDrop(of: [.text], isTargeted: nil) { providers in loadDrop(providers, prefix: "workspace:") { model.moveWorkspace($0, to: workspace.id) } }
                        .contextMenu {
                            Button(L("重命名…")) { model.renameWorkspace(workspace.id) }
                            Button(L("编辑描述…")) { model.describeWorkspace(workspace.id) }
                            Button(workspace.isPinned ? L("取消置顶") : L("置顶")) { model.pinWorkspace(workspace.id) }
                            Menu(L("颜色")) { ForEach(Self.colors, id: \.0) { color in Button(Self.colorTitle(color.0)) { model.colorWorkspace(workspace.id, color: color.0) } } }
                            Button(L("移至新窗口")) { AppDelegate.shared.moveWorkspace(workspace.id, from: model) }
                            Divider()
                            Button(L("关闭工作区")) { model.closeWorkspace(workspace.id) }
                        }
                    }
                }.padding(.horizontal, 7)
            }
            Spacer(minLength: 0)
            Divider()
            HStack {
                IconButton(symbol: "gearshape", help: L("设置")) { model.showSettings = true }
                Text(L("仅本地")).font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
            }.padding(8)
        }.background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }
}

struct TerminalArea: View {
    @ObservedObject private var languagePreferences = LanguagePreferences.shared
    @ObservedObject var model: WindowModel
    var body: some View {
        let _ = languagePreferences.language
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(model.workspace?.tabs ?? []) { tab in
                            HStack(spacing: 7) {
                                Image(systemName: tab.isPinned ? "pin.fill" : "terminal").font(.system(size: 11)).foregroundStyle(.secondary)
                                Text(tab.displayTitle).lineLimit(1).frame(maxWidth: 155, alignment: .leading)
                                Button { model.closeTab(tab.id) } label: { Image(systemName: "xmark").font(.system(size: 9)).padding(4).contentShape(Rectangle()) }.buttonStyle(.plain).pointingHandCursor().help(L("关闭终端"))
                            }.font(.system(size: 12)).padding(.horizontal, 12).frame(height: 38)
                                .background(model.workspace?.selectedTabID == tab.id ? Color(nsColor: .textBackgroundColor) : Color.clear)
                                .overlay(alignment: .bottom) { if model.workspace?.selectedTabID == tab.id { Rectangle().fill(.blue).frame(height: 2).allowsHitTesting(false) } }
                                .contentShape(Rectangle()).pointingHandCursor().onTapGesture { model.selectTab(tab.id) }
                                .onDrag { NSItemProvider(object: ("tab:" + tab.id.uuidString) as NSString) }
                                .onDrop(of: [.text], isTargeted: nil) { providers in loadDrop(providers, prefix: "tab:") { model.moveTab($0, to: tab.id) } }
                                .contextMenu {
                                    Button(L("重命名…")) { model.renameTab(tab.id) }
                                    Button(tab.isPinned ? L("取消置顶") : L("置顶")) { model.pinTab(tab.id) }
                                    Button(L("拆离到新窗口")) { AppDelegate.shared.detachTab(tab.id, from: model) }
                                    if model.workspace?.selectedTabID != tab.id { Button(L("合并到当前 Tab 的右侧")) { model.mergeTab(tab.id) } }
                                    Menu(L("移动到工作区")) {
                                        ForEach(model.workspaces.filter { $0.id != model.selectedWorkspaceID }) { workspace in
                                            Button(workspace.name) { model.moveTabToWorkspace(tab.id, destination: workspace.id) }
                                        }
                                    }.disabled(model.workspaces.count < 2)
                                    Divider(); Button(L("关闭")) { model.closeTab(tab.id) }
                                }
                        }
                    }
                }
                IconButton(symbol: "plus", help: L("新建终端 Tab")) { model.addTab() }.padding(.horizontal, 5)
            }.background(.bar)
            Divider()
            if model.showFind {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(L("查找滚屏内容"), text: $model.findText).textFieldStyle(.roundedBorder).onSubmit { model.find() }
                    Button(L("查找")) { model.find() }.pointingHandCursor()
                    IconButton(symbol: "chevron.up", help: L("上一个")) { model.find("previous") }
                    IconButton(symbol: "chevron.down", help: L("下一个")) { model.find("next") }
                    IconButton(symbol: "xmark", help: L("关闭查找")) { model.focusedTerminal?.action("end_search"); model.showFind = false; model.focusTerminal() }
                }.padding(7)
                Divider()
            }
            if let tab = model.selectedTab, !model.isDisposed {
                PaneTree(layout: tab.zoomedPane.map { .leaf($0) } ?? tab.layout, model: model).id(tab.id)
            }
        }
    }
}

struct PaneTree: View {
    @ObservedObject private var languagePreferences = LanguagePreferences.shared
    let layout: PaneLayout
    @ObservedObject var model: WindowModel
    var body: some View {
        let _ = languagePreferences.language
        switch layout {
        case .leaf(let id):
            VStack(spacing: 0) {
                PaneTabBar(pane: id, model: model)
                GhosttyView(terminal: model.terminal(model.activeTerminalID(id))).frame(maxWidth: .infinity, maxHeight: .infinity)
            }.overlay { if model.selectedTab?.focusedPane == id && (model.selectedTab?.layout.leaves.count ?? 0) > 1 { Rectangle().strokeBorder(Color.blue.opacity(0.6), lineWidth: 1).allowsHitTesting(false) } }
        case .split(let id, let axis, let fraction, let first, let second):
            GeometryReader { geometry in
                let total = axis == .horizontal ? geometry.size.width : geometry.size.height
                let firstSize = max(0, (total - 5) * fraction)
                if axis == .horizontal {
                    HStack(spacing: 0) {
                        AnyView(PaneTree(layout: first, model: model)).frame(width: firstSize)
                        divider(id, axis, total, firstSize)
                        AnyView(PaneTree(layout: second, model: model))
                    }
                } else {
                    VStack(spacing: 0) {
                        AnyView(PaneTree(layout: first, model: model)).frame(height: firstSize)
                        divider(id, axis, total, firstSize)
                        AnyView(PaneTree(layout: second, model: model))
                    }
                }
            }
        }
    }
    private func divider(_ id: UUID, _ axis: SplitAxis, _ total: Double, _ start: Double) -> some View {
        SplitHandle(axis: axis, fraction: (total - 5) > 0 ? start / (total - 5) : 0.5) { fraction in model.resize(id, fraction: fraction) }
            .frame(width: axis == .horizontal ? 5 : nil, height: axis == .vertical ? 5 : nil)
            .environment(\.splitDimension, total - 5)
    }
}
private struct SplitDimension: EnvironmentKey { static let defaultValue = 1.0 }
private extension EnvironmentValues { var splitDimension: Double { get { self[SplitDimension.self] } set { self[SplitDimension.self] = newValue } } }
private struct SplitHandle: View {
    @ObservedObject private var languagePreferences = LanguagePreferences.shared
    let axis: SplitAxis
    let fraction: Double
    let resize: (Double) -> Void
    @Environment(\.splitDimension) var dimension
    @State private var initial: Double?
    var body: some View {
        let _ = languagePreferences.language
        Rectangle().fill(Color(nsColor: .separatorColor)).contentShape(Rectangle())
            .onHover { inside in if inside { (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                if initial == nil { initial = fraction }
                resize((initial ?? fraction) + (axis == .horizontal ? value.translation.width : value.translation.height) / max(1, dimension))
            }.onEnded { _ in initial = nil })
            .onTapGesture(count: 2) { resize(0.5) }
    }
}

@MainActor
func loadDrop(_ providers: [NSItemProvider], prefix: String, action: @escaping (UUID) -> Void) -> Bool {
    guard let provider = providers.first else { return false }
    _ = provider.loadObject(ofClass: NSString.self) { value, _ in
        guard let string = value as? String, string.hasPrefix(prefix), let id = UUID(uuidString: String(string.dropFirst(prefix.count))) else { return }
        DispatchQueue.main.async { action(id) }
    }
    return true
}

private struct PanelDivider: View {
    @ObservedObject private var languagePreferences = LanguagePreferences.shared
    @Binding var width: Double
    let maximum: Double
    let minimum: Double
    let direction: Double
    @State private var initial: Double?
    var body: some View {
        let _ = languagePreferences.language
        Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.5)).frame(width: 1).frame(width: 5).contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                if initial == nil { initial = width }
                width = max(minimum, min(maximum, (initial ?? width) + direction * value.translation.width))
            }.onEnded { _ in initial = nil })
    }
}

struct PaneTabBar: View {
    @ObservedObject private var languagePreferences = LanguagePreferences.shared
    let pane: UUID
    @ObservedObject var model: WindowModel
    var body: some View {
        let _ = languagePreferences.language
        HStack(spacing: 1) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(model.localTabs(pane)) { tab in
                        HStack(spacing: 5) {
                            Image(systemName: "terminal").font(.system(size: 9))
                            Text(tab.displayTitle).font(.system(size: 10)).lineLimit(1).frame(maxWidth: 115)
                            if model.localTabs(pane).count > 1 {
                                Button { model.closeLocalTab(tab.id, pane: pane) } label: { Image(systemName: "xmark").font(.system(size: 8)).padding(3).contentShape(Rectangle()) }.buttonStyle(.plain).pointingHandCursor().help(L("关闭此分屏 Tab"))
                            }
                        }.padding(.horizontal, 8).frame(height: 27)
                        .background(model.activeTerminalID(pane) == tab.id ? Color.blue.opacity(0.07) : .clear)
                        .contentShape(Rectangle()).pointingHandCursor().onTapGesture { model.selectLocalTab(tab.id, pane: pane) }
                        .onDrag { NSItemProvider(object: ("pane-tab:" + pane.uuidString + ":" + tab.id.uuidString) as NSString) }
                        .onDrop(of: [.text], isTargeted: nil) { providers in loadDrop(providers, prefix: "pane-tab:" + pane.uuidString + ":") { model.reorderLocalTab($0, pane: pane, target: tab.id) } }
                        .contextMenu {
                            Button(L("重命名…")) { model.renameLocalTab(tab.id, pane: pane) }
                            Button(L("拆离为工作区 Tab")) { model.extractLocalTab(tab.id, pane: pane) }.disabled(model.localTabs(pane).count < 2)
                            Divider()
                            Button(L("关闭")) { model.closeLocalTab(tab.id, pane: pane) }
                        }
                    }
                }
            }
            IconButton(symbol: "plus", help: L("在此分屏新增终端 Tab")) { model.addLocalTab(pane) }
            Menu {
                Button(L("向右分屏")) { model.focusPane(pane); model.split(.horizontal) }
                Button(L("向下分屏")) { model.focusPane(pane); model.split(.vertical) }
                Button(L("拆分为工作区 Tab")) { model.extractPane(pane) }.disabled((model.selectedTab?.layout.leaves.count ?? 0) < 2)
            } label: { Image(systemName: "ellipsis").font(.system(size: 10)).frame(width: 17) }.menuStyle(.borderlessButton).pointingHandCursor().fixedSize()
            if (model.selectedTab?.layout.leaves.count ?? 0) > 1 {
                IconButton(symbol: model.selectedTab?.zoomedPane == pane ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", help: L("放大 / 还原分屏")) { model.zoom(pane) }
                IconButton(symbol: "xmark", help: L("关闭整个分屏")) { model.closePane(pane) }
            }
        }.foregroundStyle(.secondary).frame(height: 27).background(.bar)
    }
}
