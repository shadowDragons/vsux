import SwiftUI
import AppKit

struct SSHSection: View {
    @ObservedObject private var languagePreferences = LanguagePreferences.shared
    @ObservedObject var model: WindowModel
    let workspace: Workspace
    @ObservedObject var runtime: SSHWorkspaceRuntime
    @State private var draft: SSHConnection?
    @State private var query = ""
    @State private var expanded = true
    private var connections: [SSHConnection] {
        workspace.sshConnections.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.address.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        let _ = languagePreferences.language
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Text(L("SSH 连接")).font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                SectionDisclosureButton(title: L("SSH 连接"), expanded: $expanded)
                IconButton(symbol: "plus", help: L("添加 SSH 连接")) { draft = SSHConnection() }
            }.frame(minHeight: 27)
            if expanded {
                if !workspace.sshConnections.isEmpty {
                    TextField(L("搜索服务器"), text: $query).textFieldStyle(.roundedBorder)
                }
                if workspace.sshConnections.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("当前项目暂无 SSH 连接")).font(.system(size: 13, weight: .medium))
                        Text(L("服务器配置和终端会话仅属于此项目。切换项目不会断开连接。")).font(.system(size: 12)).foregroundStyle(.secondary)
                        Button(L("添加 SSH 连接")) { draft = SSHConnection() }.pointingHandCursor()
                    }.padding(10)
                } else if connections.isEmpty {
                    Text(L("没有匹配的服务器")).font(.system(size: 12)).foregroundStyle(.secondary).padding(10)
                }
                ForEach(connections) { connection in connectionRow(connection) }
                if let error = runtime.error {
                    HStack(alignment: .top) {
                        Text(error).font(.system(size: 12)).foregroundStyle(.red).textSelection(.enabled)
                        Spacer()
                        IconButton(symbol: "xmark", help: L("关闭")) { runtime.error = nil }
                    }.padding(12)
                }
            }
        }
        .sheet(item: $draft) { connection in
            SSHConnectionEditor(model: model, workspaceID: workspace.id, workspaceName: workspace.name, connection: connection)
        }
    }

    private func connectionRow(_ connection: SSHConnection) -> some View {
        let active = runtime.sessions.contains { $0.connection.id == connection.id && !$0.ended }
        return HStack(spacing: 8) {
            Image(systemName: "server.rack").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(connection.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(connection.address).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button(active ? L("打开会话") : L("连接")) {
                model.openSSHConnection(connection, in: workspace.id)
            }.controlSize(.small).pointingHandCursor()
            Menu {
                Button(L("编辑…")) { draft = connection }
                Button(L("删除…")) {
                    if confirm(title: L("删除“\(connection.name)”？"), detail: L("此操作将断开相关会话，并从当前项目移除此连接。"), action: L("删除")) {
                        model.deleteSSHConnection(connection.id, in: workspace.id)
                    }
                }
            } label: { Image(systemName: "ellipsis").frame(width: 16) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().pointingHandCursor()
        }.padding(10).background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
    }

}

struct SSHConnectionEditor: View {
    @ObservedObject private var languagePreferences = LanguagePreferences.shared
    @ObservedObject var model: WindowModel
    let workspaceID: UUID
    let workspaceName: String
    @State var connection: SSHConnection
    @State private var port = ""
    @State private var password = ""
    @State private var rememberPassword = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let _ = languagePreferences.language
        VStack(alignment: .leading, spacing: 16) {
            Text(L("SSH 连接设置")).font(.system(size: 17, weight: .semibold))
            Text(L("工作区：\(workspaceName)")).font(.system(size: 12)).foregroundStyle(.secondary)
            Form {
                TextField(L("名称"), text: $connection.name)
                TextField(L("主机 / IP 地址"), text: $connection.host)
                TextField(L("端口"), text: $port)
                TextField(L("用户名"), text: $connection.username)
                Picker(L("认证方式"), selection: $connection.authentication) {
                    ForEach(SSHConnection.Authentication.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if connection.authentication == .password {
                    Toggle(L("在钥匙串中记住密码"), isOn: $rememberPassword)
                    if rememberPassword {
                        SecureField(connection.credentialReference == nil ? L("密码") : L("留空保留已保存的密码"), text: $password)
                    }
                }
                if connection.authentication == .privateKey {
                    HStack {
                        TextField(L("私钥路径"), text: $connection.privateKeyPath)
                        Button(L("选择…")) { chooseKey() }.pointingHandCursor()
                    }
                }
            }.textFieldStyle(.roundedBorder)
            Text(L("密码按项目保存在 macOS 钥匙串中，不写入项目配置。未保存的密码在终端输入；使用已保存密码时，额外认证和主机指纹确认会弹窗提示。"))
                .font(.system(size: 12)).foregroundStyle(.secondary)
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button(L("取消")) { dismiss() }.keyboardShortcut(.cancelAction).pointingHandCursor()
                Button(L("保存")) { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).pointingHandCursor()
            }
        }.padding(22).frame(width: 440).workbenchSheetZoom()
            .onAppear { port = String(connection.port); rememberPassword = connection.credentialReference != nil }
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.allowsMultipleSelection = false; panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh")
        if panel.runModal() == .OK, let url = panel.url { connection.privateKeyPath = url.path }
    }

    private func save() {
        do {
            connection.name = connection.name.trimmingCharacters(in: .whitespacesAndNewlines)
            connection.host = connection.host.trimmingCharacters(in: .whitespacesAndNewlines)
            connection.username = connection.username.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let value = Int(port.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw SSHConnectionError.invalid }
            connection.port = value
            let update: SSHPasswordUpdate = !rememberPassword ? .remove : (password.isEmpty ? .keep : .replace(password))
            if rememberPassword && password.isEmpty && connection.credentialReference == nil { throw SSHCredentialError.invalidPassword }
            if try model.saveSSHConnection(connection, in: workspaceID, passwordUpdate: update) { password = ""; dismiss() }
        } catch { self.error = error.localizedDescription }
    }
}

/// The sidebar owns connection management; the main terminal area presents the
/// existing surface, so tab/project switches never recreate an SSH process.
struct SSHSessionContent: View {
    @ObservedObject var runtime: SSHWorkspaceRuntime
    let session: SSHWorkspaceRuntime.Session
    let workspace: Workspace

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(session.connection.address).font(.system(size: 11, design: .monospaced)).lineLimit(1)
                Spacer()
                if session.ended {
                    Text(L("会话已结束")).font(.system(size: 11)).foregroundStyle(.secondary)
                    Button(L("重新连接")) {
                        let connection = workspace.sshConnections.first { $0.id == session.connection.id } ?? session.connection
                        runtime.reconnect(session.id, using: connection, directory: workspace.directory)
                    }.controlSize(.small).pointingHandCursor()
                } else {
                    Button(L("断开")) { runtime.disconnect(session.id) }.controlSize(.small).pointingHandCursor()
                }
            }.padding(8)
            Divider()
            GhosttyView(terminal: session.terminal).id(session.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear {
                    DispatchQueue.main.async {
                        guard runtime.presentedSession?.id == session.id else { return }
                        session.terminal.window?.makeFirstResponder(session.terminal)
                    }
                }
        }
    }
}
