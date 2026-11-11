import SwiftUI
import AppKit

struct CommandDraft: Identifiable {
    var id: UUID { command.id }
    var command: SavedCommand
    let workspaceID: UUID
}

struct ServiceDraft: Identifiable {
    var id: UUID { service.id }
    var service: WorkspaceService
    let workspaceID: UUID
    let isNew: Bool
}

struct CommandSidebar: View {
    @ObservedObject private var languagePreferences = LanguagePreferences.shared
    @ObservedObject var model: WindowModel
    @ObservedObject var library: CommandLibrary
    let workspace: Workspace
    @State private var draft: CommandDraft?
    @State private var serviceDraft: ServiceDraft?
    @State private var logService: WorkspaceService?
    @State private var query = ""
    @State private var servicesExpanded = true
    @State private var commandsExpanded = true
    @State private var quickTunnelPort = ""
    @State private var quickTunnelInstallPresented = false
    @State private var quickTunnelConfirmationPresented = false
    @State private var requestedTunnelPort: Int?
    @State private var cloudflaredURL: URL?
    private var commands: [SavedCommand] { library.commands(in: workspace.id) }
    private var filteredCommands: [SavedCommand] {
        commands.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.command.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        let _ = languagePreferences.language
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                quickTunnelSection
                Divider().padding(.vertical, 4)
                serviceSection
                Divider().padding(.vertical, 4)
                commandSection
            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }.background(Color(nsColor: .controlBackgroundColor))
            .sheet(item: $draft) { value in CommandEditor(library: library, draft: value, workspaceName: workspace.name) }
            .sheet(item: $serviceDraft) { value in ServiceEditor(model: model, draft: value, workspaceName: workspace.name) }
            .sheet(item: $logService) { service in ServiceLogView(model: model, service: service) }
            .sheet(isPresented: $quickTunnelInstallPresented) {
                CloudflaredInstallSheet(onCheckAgain: checkForCloudflared)
            }
            .confirmationDialog(L("公网隧道"), isPresented: $quickTunnelConfirmationPresented, titleVisibility: .visible) {
                Button(L("继续并公开"), role: .destructive) { startRequestedTunnel() }
                Button(L("取消"), role: .cancel) {}
            } message: {
                if let requestedTunnelPort {
                    Text(L("端口 \(requestedTunnelPort) 将通过公网地址开放。任何拿到链接的人都可能访问此服务。"))
                }
            }
    }
    @ViewBuilder private var quickTunnelSection: some View {
        let status = model.quickTunnelStatuses[workspace.id]
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                sectionTitle(L("公网隧道"))
                Spacer(minLength: 0)
                if let status, status.phase == .starting || status.phase == .running || status.phase == .stopping {
                    Text(status.phase.title).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            if let status, status.phase == .starting || status.phase == .running || status.phase == .stopping {
                HStack(spacing: 7) {
                    if status.phase == .starting || status.phase == .stopping {
                        ProgressView().controlSize(.small).scaleEffect(0.75).frame(width: 12, height: 12)
                    } else {
                        Image(systemName: "globe").font(.system(size: 11)).foregroundStyle(.green)
                    }
                    Text("localhost:\(status.port)").font(.system(size: 11, design: .monospaced))
                    Spacer(minLength: 0)
                    IconButton(symbol: "stop.fill", help: L("停止 Quick Tunnel")) {
                        model.stopQuickTunnel(in: workspace.id)
                    }.disabled(status.phase == .stopping)
                }
                if let address = status.publicURL {
                    HStack(alignment: .top, spacing: 5) {
                        Text(address).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        IconButton(symbol: "doc.on.doc", help: L("复制公网地址")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(address, forType: .string)
                        }
                    }
                }
            } else {
                HStack(spacing: 7) {
                    TextField(L("本地端口"), text: $quickTunnelPort)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: quickTunnelPort) { _, value in
                            quickTunnelPort = String(value.filter { $0.isASCII && $0.isNumber }.prefix(5))
                        }
                    Button(L("公开端口"), systemImage: "globe") { requestQuickTunnel() }
                        .buttonStyle(.bordered).controlSize(.mini).pointingHandCursor()
                }
                if let status, status.phase == .failed, let detail = status.detail {
                    Text(detail).font(.system(size: 10)).foregroundStyle(.red).textSelection(.enabled).lineLimit(3)
                }
            }
        }
    }

    private func requestQuickTunnel() {
        guard let port = CloudflaredQuickTunnel.port(from: quickTunnelPort) else {
            model.error = L("请输入 1 到 65535 之间的端口号。")
            return
        }
        guard let executable = CloudflaredQuickTunnel.executableURL(environment: ShellEnvironment.shared.resolve()) else {
            quickTunnelInstallPresented = true
            return
        }
        requestedTunnelPort = port
        cloudflaredURL = executable
        quickTunnelConfirmationPresented = true
    }

    private func checkForCloudflared() {
        guard let executable = CloudflaredQuickTunnel.executableURL(environment: ShellEnvironment.shared.resolve()) else { return }
        cloudflaredURL = executable
        quickTunnelInstallPresented = false
        if CloudflaredQuickTunnel.port(from: quickTunnelPort) != nil {
            requestedTunnelPort = CloudflaredQuickTunnel.port(from: quickTunnelPort)
            DispatchQueue.main.async { quickTunnelConfirmationPresented = true }
        }
    }

    private func startRequestedTunnel() {
        guard let port = requestedTunnelPort, let executable = cloudflaredURL else { return }
        model.startQuickTunnel(in: workspace.id, port: port, executableURL: executable)
    }
    @ViewBuilder private var commandSection: some View {
        HStack(spacing: 7) {
            sectionTitle(L("常用命令"))
            Spacer(minLength: 0)
            Menu {
                Button(L("导入 JSON…")) { library.importFile(into: workspace.id) }
                Button(L("导出 JSON…")) { library.exportFile(from: workspace.id, name: workspace.name) }
            } label: { Image(systemName: "ellipsis").frame(width: 22) }.menuStyle(.borderlessButton).menuIndicator(.hidden).pointingHandCursor().fixedSize().help(L("当前工作区的命令库管理"))
            SectionDisclosureButton(title: L("常用命令"), expanded: $commandsExpanded)
            IconButton(symbol: "plus", help: L("添加常用命令")) {
                draft = CommandDraft(command: SavedCommand(name: "", command: ""), workspaceID: workspace.id)
            }
        }.frame(minHeight: 27)
        if commandsExpanded {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                TextField(L("搜索命令"), text: $query).textFieldStyle(.plain)
                if !query.isEmpty { IconButton(symbol: "xmark.circle.fill", help: L("清除搜索")) { query = "" } }
            }.font(.system(size: 12)).padding(.horizontal, 9).frame(height: 29).background(Color(nsColor: .quaternaryLabelColor).opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
            ForEach(filteredCommands) { command in commandRow(command) }
            if commands.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("当前工作区暂无常用命令")).font(.system(size: 13, weight: .medium))
                    Text(L("添加后仅保存在此工作区，切换工作区会显示各自的命令。")).font(.system(size: 12)).foregroundStyle(.secondary)
                    Button(L("添加命令…")) { draft = CommandDraft(command: SavedCommand(name: "", command: ""), workspaceID: workspace.id) }.pointingHandCursor()
                }.padding(10)
            } else if filteredCommands.isEmpty {
                Text(L("没有匹配的命令")).font(.system(size: 12)).foregroundStyle(.secondary).padding(10)
            }
        }
    }
    @ViewBuilder private var serviceSection: some View {
        HStack(spacing: 7) {
            sectionTitle(L("服务"))
            Spacer(minLength: 0)
            Button { model.startServices(in: workspace.id) } label: {
                Label(L("一键启动"), systemImage: "play.fill")
            }.buttonStyle(.bordered).controlSize(.mini).pointingHandCursor()
                .help(L("启动当前工作区所有未运行的服务"))
                .disabled(workspace.services.allSatisfy { model.serviceProcesses[$0.id] != nil })
            SectionDisclosureButton(title: L("服务"), expanded: $servicesExpanded)
            IconButton(symbol: "plus", help: L("添加服务")) {
                serviceDraft = ServiceDraft(service: WorkspaceService(name: "", command: ""), workspaceID: workspace.id, isNew: true)
            }
        }.frame(minHeight: 27)
        if servicesExpanded {
            if workspace.services.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("当前工作区暂无服务")).font(.system(size: 13, weight: .medium))
                    Text(L("服务会在后台运行，不显示终端窗口。")).font(.system(size: 12)).foregroundStyle(.secondary)
                    Button(L("添加服务…")) { serviceDraft = ServiceDraft(service: WorkspaceService(name: "", command: ""), workspaceID: workspace.id, isNew: true) }.pointingHandCursor()
                }.padding(10)
            } else {
                ForEach(workspace.services) { service in serviceRow(service) }
            }
        }
    }
    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1).fixedSize()
            .frame(minHeight: 27, alignment: .leading)
    }
    private func serviceRow(_ service: WorkspaceService) -> some View {
        let status = model.serviceStatuses[service.id] ?? .stopped
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Circle().fill(status == .failed ? Color.red : (status == .running ? Color.green : (status == .starting || status == .stopping ? Color.orange : Color.gray))).frame(width: 8, height: 8)
                Text(service.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
                Text(status.title).font(.system(size: 10)).foregroundStyle(.secondary)
                Menu {
                    Button(L("编辑…")) { serviceDraft = ServiceDraft(service: service, workspaceID: workspace.id, isNew: false) }
                    Button(L("查看日志")) { logService = service }
                    Divider()
                    Button(status == .running ? L("停止") : L("启动")) { status == .running ? model.stopService(service.id) : model.startService(service.id) }
                    Button(L("重启")) { model.restartService(service.id) }.disabled(status != .running)
                    Divider()
                    Button(L("删除…")) {
                        if confirm(title: L("删除“\(service.name)”？"), detail: L("此操作将停止服务并从当前工作区移除。"), action: L("删除")) { model.deleteService(service.id, from: workspace.id) }
                    }
                } label: { Image(systemName: "ellipsis").font(.system(size: 11)).frame(width: 15) }.menuStyle(.borderlessButton).menuIndicator(.hidden).pointingHandCursor().fixedSize()
            }
            Text(service.command).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            if let path = service.workingDirectory, !path.isEmpty {
                Label(path, systemImage: "folder").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    .help(service.directory(in: workspace.directory).path)
            }
            HStack {
                Button(L("查看日志")) { logService = service }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary).pointingHandCursor()
                Spacer()
                Button(status == .running ? L("停止") : L("启动")) { status == .running ? model.stopService(service.id) : model.startService(service.id) }.buttonStyle(.bordered).controlSize(.mini).pointingHandCursor().disabled(status == .starting || status == .stopping)
                Button(L("重启")) { model.restartService(service.id) }.buttonStyle(.bordered).controlSize(.mini).pointingHandCursor().disabled(status != .running)
            }
        }.padding(10).background(Color(nsColor: .windowBackgroundColor).opacity(0.7), in: RoundedRectangle(cornerRadius: 6)).overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 0.5).allowsHitTesting(false) }
    }
    private func commandRow(_ command: SavedCommand) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 4) {
                Text(command.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
                Menu {
                    Button(L("编辑…")) { draft = CommandDraft(command: command, workspaceID: workspace.id) }
                    Button(L("复制")) { copy(command.command) }
                    Divider()
                    Button(L("删除…")) {
                        if confirm(title: L("删除“\(command.name)”？"), detail: L("此操作将从当前工作区移除此命令。"), action: L("删除")) {
                            library.deleteCommand(command.id, in: workspace.id)
                        }
                    }
                } label: { Image(systemName: "ellipsis").font(.system(size: 11)).frame(width: 15) }.menuStyle(.borderlessButton).menuIndicator(.hidden).pointingHandCursor().fixedSize()
            }
            Text(command.command).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            HStack(spacing: 7) {
                Spacer()
                Button { copy(command.command) } label: { Image(systemName: "doc.on.doc").frame(width: 22, height: 22).contentShape(Rectangle()) }.buttonStyle(.plain).pointingHandCursor().help(L("复制命令")).accessibilityLabel(L("复制\(command.name)"))
                Button(L("填入终端")) {
                    if model.selectedWorkspaceID == workspace.id { model.insertCommand(command.command) }
                }.buttonStyle(.bordered).pointingHandCursor().controlSize(.mini).help(L("填入当前聚焦的终端，不执行"))
            }.foregroundStyle(.secondary)
        }.padding(10).background(Color(nsColor: .windowBackgroundColor).opacity(0.7), in: RoundedRectangle(cornerRadius: 6)).overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 0.5).allowsHitTesting(false) }
    }
    private func copy(_ value: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }
}

private struct CloudflaredInstallSheet: View {
    let onCheckAgain: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("需要安装 cloudflared")).font(.system(size: 17, weight: .semibold))
            Text(L("安装 cloudflared 后才能创建临时公网地址。")).font(.system(size: 12)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text(L("brew install cloudflared"))
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                IconButton(symbol: "doc.on.doc", help: L("复制安装命令")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(CloudflaredQuickTunnel.installationCommand, forType: .string)
                }
            }.padding(9).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
            Button(L("打开官方安装说明"), systemImage: "arrow.up.right.square") {
                NSWorkspace.shared.open(CloudflaredQuickTunnel.installationGuide)
            }.buttonStyle(.link).pointingHandCursor()
            HStack {
                Spacer()
                Button(L("取消")) { dismiss() }.pointingHandCursor()
                Button(L("重新检测")) { onCheckAgain() }.buttonStyle(.borderedProminent).pointingHandCursor()
            }
        }.padding(22).frame(width: 390).workbenchSheetZoom()
    }
}

struct SectionDisclosureButton: View {
    let title: String
    @Binding var expanded: Bool

    var body: some View {
        Button { expanded.toggle() } label: {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 11, weight: .semibold)).frame(width: 28, height: 27).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(Color.accentColor).pointingHandCursor()
            .accessibilityIdentifier("collapse-section-\(title)")
            .help((expanded ? L("折叠") : L("展开")) + title)
            .accessibilityLabel((expanded ? L("折叠") : L("展开")) + title)
    }
}

struct ServiceEditor: View {
    @ObservedObject private var languagePreferences = LanguagePreferences.shared
    @ObservedObject var model: WindowModel
    @State var draft: ServiceDraft
    let workspaceName: String
    @Environment(\.dismiss) var dismiss
    var body: some View {
        let _ = languagePreferences.language
        VStack(alignment: .leading, spacing: 16) {
            Text(draft.isNew ? L("添加服务") : L("编辑服务")).font(.system(size: 17, weight: .semibold))
            Text(L("工作区：\(workspaceName)")).font(.system(size: 12)).foregroundStyle(.secondary)
            LabeledContent(L("名称")) { TextField(L("例如：后端"), text: $draft.service.name).textFieldStyle(.roundedBorder) }
            Text(L("运行目录")).font(.system(size: 12, weight: .medium))
            HStack {
                TextField(L("留空使用工作区目录，例如 apps/server"), text: Binding(get: { draft.service.workingDirectory ?? "" }, set: { draft.service.workingDirectory = $0 }))
                    .textFieldStyle(.roundedBorder)
                Button(L("选择目录…")) {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
                    if let workspace = model.workspaces.first(where: { $0.id == draft.workspaceID }) {
                        panel.directoryURL = draft.service.directory(in: workspace.directory)
                    }
                    if panel.runModal() == .OK, let url = panel.url { draft.service.workingDirectory = url.path }
                }.pointingHandCursor()
            }
            Text(L("启动命令")).font(.system(size: 12, weight: .medium))
            TextEditor(text: $draft.service.command).font(.system(size: 13, design: .monospaced)).scrollContentBackground(.hidden).padding(8).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5)).overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(.gray.opacity(0.3)).allowsHitTesting(false) }.frame(height: 130)
            Text(L("服务在指定目录中后台运行；相对路径以工作区目录为起点。")) .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack { Spacer(); Button(L("取消")) { dismiss() }.pointingHandCursor(); Button(L("保存")) {
                if draft.isNew { model.addService(draft.service, to: draft.workspaceID) } else { model.updateService(draft.service, in: draft.workspaceID) }
                dismiss()
            }.pointingHandCursor().keyboardShortcut(.defaultAction).disabled(draft.service.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.service.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(24).frame(width: 480).workbenchSheetZoom()
    }
}

struct ServiceLogView: View {
    @ObservedObject private var languagePreferences = LanguagePreferences.shared
    @ObservedObject var model: WindowModel
    let service: WorkspaceService
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let _ = languagePreferences.language
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(service.name).font(.headline)
                    Spacer()
                    Text((model.serviceStatuses[service.id] ?? .stopped).title).font(.caption).foregroundStyle(.secondary)
                }
                ServiceOutputView(output: model.output(for: service.id))
                HStack {
                    Button { proxy.scrollTo(ServiceLogScrollTarget.output, anchor: .topLeading) } label: {
                        Label(L("滚动到顶部"), systemImage: "arrow.up.to.line")
                    }.pointingHandCursor()
                    Button { proxy.scrollTo(ServiceLogScrollTarget.output, anchor: .bottomLeading) } label: {
                        Label(L("滚动到底部"), systemImage: "arrow.down.to.line")
                    }.pointingHandCursor()
                    Spacer()
                    Button(L("完成")) { dismiss() }.keyboardShortcut(.cancelAction).pointingHandCursor()
                }
            }.padding(20).frame(width: 720, height: 480).workbenchSheetZoom()
                .onAppear {
                    // Wait for the sheet's scroll content to finish its initial layout.
                    DispatchQueue.main.async { proxy.scrollTo(ServiceLogScrollTarget.output, anchor: .bottomLeading) }
                }
        }
    }
}

private enum ServiceLogScrollTarget: Hashable { case output }

private struct ServiceOutputView: View {
    @ObservedObject var output: ServiceOutput
    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Text(output.text.isEmpty ? L("暂无日志，启动服务后显示输出。") : output.text)
                .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading).padding(10)
                .id(ServiceLogScrollTarget.output)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .textBackgroundColor))
    }
}

struct CommandEditor: View {
    @ObservedObject private var languagePreferences = LanguagePreferences.shared
    @ObservedObject var library: CommandLibrary
    @State var draft: CommandDraft
    let workspaceName: String
    @Environment(\.dismiss) var dismiss
    var body: some View {
        let _ = languagePreferences.language
        VStack(alignment: .leading, spacing: 16) {
            Text(draft.command.name.isEmpty ? L("添加常用命令") : L("编辑常用命令")).font(.system(size: 17, weight: .semibold))
            Text(L("工作区：\(workspaceName)")).font(.system(size: 12)).foregroundStyle(.secondary)
            LabeledContent(L("名称")) { TextField(L("例如：查看监听端口"), text: $draft.command.name).textFieldStyle(.roundedBorder) }
            Text(L("命令正文")).font(.system(size: 12, weight: .medium))
            TextEditor(text: $draft.command.command).font(.system(size: 13, design: .monospaced)).scrollContentBackground(.hidden).padding(8).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5)).overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(.gray.opacity(0.3)).allowsHitTesting(false) }.frame(height: 160)
            Text(L("可保存多行命令。填入终端后由你确认执行。")).font(.system(size: 11)).foregroundStyle(.secondary)
            if let error = library.error { Text(error).font(.system(size: 11)).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button(L("取消")) { dismiss() }.pointingHandCursor().keyboardShortcut(.cancelAction)
                Button(L("保存")) {
                    if library.put(draft.command, in: draft.workspaceID) { dismiss() }
                }.pointingHandCursor().keyboardShortcut(.defaultAction)
                    .disabled(draft.command.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.command.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 480).workbenchSheetZoom()
    }
}

struct SettingsView: View {
    @ObservedObject private var languagePreferences = LanguagePreferences.shared
    @ObservedObject var preferences: Preferences
    @ObservedObject private var shortcuts = ShortcutPreferences.shared
    @State private var selectedTab = 0
    @Environment(\.dismiss) var dismiss
    init(preferences: Preferences, initialTab: Int = 0) {
        self.preferences = preferences
        _selectedTab = State(initialValue: initialTab)
    }
    var body: some View {
        let _ = languagePreferences.language
        VStack(alignment: .leading, spacing: 18) {
            Text(L("设置")).font(.system(size: 18, weight: .semibold))
            TabView(selection: $selectedTab) {
                Form {
                    Picker(L("界面语言"), selection: $languagePreferences.language) {
                        ForEach(AppLanguage.allCases) { language in Text(language.title).tag(language) }
                    }.pointingHandCursor()
                    Text(L("切换后立即生效，无需重启。")).font(.caption).foregroundStyle(.secondary)
                    Picker(L("应用外观"), selection: $preferences.appearance) {
                        ForEach(AppAppearance.allCases) { mode in Text(mode.title).tag(mode) }
                    }.pointingHandCursor()
                    Stepper(L("界面缩放  \(preferences.zoomPercentage)%"), value: Binding(
                        get: { preferences.interfaceZoomLevel }, set: { preferences.setInterfaceZoomLevel($0) }
                    ), in: WorkbenchZoom.levels).pointingHandCursor()
                    Text(L("缩放整个界面的文字、图标和布局。")).font(.caption).foregroundStyle(.secondary)
                    TextField(L("字体名称"), text: $preferences.terminal.fontName)
                    Stepper(L("终端与编辑器字号  \(Int(preferences.terminal.fontSize)) pt"), value: $preferences.terminal.fontSize, in: 9...40).pointingHandCursor()
                    Picker(L("光标"), selection: $preferences.terminal.cursor) { Text(L("方块")).tag("block"); Text(L("竖线")).tag("bar"); Text(L("下划线")).tag("underline") }.pointingHandCursor()
                    Toggle(L("光标闪烁"), isOn: $preferences.terminal.cursorBlink).pointingHandCursor()
                    Stepper(L("终端边距  \(preferences.terminal.padding) pt"), value: $preferences.terminal.padding, in: 0...40).pointingHandCursor()
                    Slider(value: $preferences.terminal.opacity, in: 0.5...1) { Text(L("不透明度")) }.pointingHandCursor()
                    Toggle(L("背景模糊"), isOn: $preferences.terminal.blur).pointingHandCursor()
                    Toggle(L("将 Option 用作 Alt"), isOn: $preferences.terminal.optionAsAlt).pointingHandCursor()
                    Stepper(L("滚屏缓冲区  \(preferences.terminal.scrollbackMB) MB"), value: $preferences.terminal.scrollbackMB, in: 1...128).pointingHandCursor()
                }.formStyle(.grouped).tabItem { Text(L("通用")) }.tag(0)
                ShortcutSettingsView(shortcuts: shortcuts).tabItem { Text(L("快捷键")) }.tag(1)
            }
            HStack { Button(L("恢复默认")) { if selectedTab == 1 { shortcuts.resetAll() } else { preferences.terminal = TerminalSettings(); preferences.appearance = .system; preferences.setInterfaceZoomLevel(0) } }.pointingHandCursor(); Spacer(); Button(L("完成")) { dismiss() }.pointingHandCursor().keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 610, height: 700)
            .modifier(ZoomedSheetContent(preferences: preferences))
    }
}
