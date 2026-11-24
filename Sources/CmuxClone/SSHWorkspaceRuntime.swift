import AppKit
import Combine

@MainActor
final class SSHWorkspaceRuntime: ObservableObject {
    struct Session: Identifiable {
        let id: UUID
        let connection: SSHConnection
        let terminal: GhosttyTerminalView
        var ended = false
    }
    @Published private(set) var sessions: [Session] = []
    @Published private(set) var selectedSessionID: UUID?
    @Published private(set) var isPresented = false
    @Published var error: String?
    var selectedSession: Session? { sessions.first { $0.id == selectedSessionID } }

    let workspaceID: UUID
    private let credentials: SSHCredentialStore
    private let confirmTermination: @MainActor () -> Bool
    private var replacements: [UUID: UUID] = [:]

    init(workspaceID: UUID = UUID(), credentials: SSHCredentialStore = SSHKeychain(),
         confirmTermination: @escaping @MainActor () -> Bool = {
             confirm(title: L("关闭 SSH 会话？"), detail: L("SSH 连接仍在运行，关闭后远程进程可能结束。"), action: L("关闭"))
         }) {
        self.workspaceID = workspaceID; self.credentials = credentials
        self.confirmTermination = confirmTermination
    }

    var terminals: [GhosttyTerminalView] { sessions.map(\.terminal) }
    var needsConfirmation: Bool { sessions.contains { !$0.ended && $0.terminal.surface != nil } }
    func owns(_ terminal: GhosttyTerminalView) -> Bool { sessions.contains { $0.terminal === terminal } }
    func select(_ id: UUID) {
        if sessions.contains(where: { $0.id == id }) { selectedSessionID = id; isPresented = true }
    }
    func showLocalTerminal() { isPresented = false }
    var presentedSession: Session? { isPresented ? selectedSession : nil }

    func reconnect(_ id: UUID, using connection: SSHConnection, directory: String) {
        guard let original = sessions.first(where: { $0.id == id }), original.ended else { return }
        start(connection, directory: directory, replacing: id)
    }

    func connect(_ connection: SSHConnection, directory: String) {
        if let existing = sessions.first(where: { $0.connection.id == connection.id && !$0.ended }) {
            select(existing.id)
            return
        }
        start(connection, directory: directory)
    }

    private func start(_ connection: SSHConnection, directory: String, replacing original: UUID? = nil) {
        do {
            let command = try connection.launchCommand()
            var environment: [String: String] = [:]
            if connection.authentication == .password, let reference = connection.credentialReference {
                guard reference.workspaceID == workspaceID, reference.connectionID == connection.id else {
                    throw SSHConnectionError.invalid
                }
                guard try credentials.password(for: reference) != nil else { throw SSHCredentialError.missing }
                guard let executable = Bundle.main.executablePath else { throw SSHCredentialError.missing }
                environment = SSHAskpass.environment(for: reference, executable: executable)
            }
            if connection.authentication == .privateKey {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: connection.expandedKeyPath, isDirectory: &isDirectory),
                      !isDirectory.boolValue, FileManager.default.isReadableFile(atPath: connection.expandedKeyPath) else {
                    throw SSHConnectionError.keyMissing
                }
            }
            let id = UUID()
            let cwd = FileManager.default.fileExists(atPath: directory) ? directory : NSHomeDirectory()
            let terminal = GhosttyTerminalView(paneID: id, directory: cwd, command: command, environment: environment)
            terminal.setAccessibilityLabel("SSH · \(connection.name)")
            terminal.onProcessExit = { [weak self] in self?.markEnded(id) }
            terminal.onSurfaceFailure = { [weak self] in
                self?.error = L("无法创建 Ghostty 终端。")
                self?.surfaceFailed(id)
            }
            terminal.onSurfaceReady = { [weak self] in
                DispatchQueue.main.async { self?.surfaceReady(id) }
            }
            if let original { replacements[id] = original }
            sessions.append(Session(id: id, connection: connection, terminal: terminal))
            select(id)
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func surfaceReady(_ id: UUID) {
        guard sessions.contains(where: { $0.id == id }), let original = replacements.removeValue(forKey: id) else { return }
        remove(original)
    }

    private func surfaceFailed(_ id: UUID) {
        if let original = replacements.removeValue(forKey: id) {
            // Surface creation is invoked during a SwiftUI update.
            DispatchQueue.main.async { [weak self] in
                self?.remove(id); self?.select(original)
            }
        } else { markEnded(id) }
    }

    func markEnded(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        // Keep the output visible for authentication failures and remote exits.
        sessions[index].ended = true
    }

    func disconnect(_ id: UUID) {
        sessions.first { $0.id == id }?.terminal.shutdown()
        markEnded(id)
    }

    func close(_ id: UUID) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        if !session.ended && session.terminal.surface != nil && !confirmTermination() { return }
        remove(id)
    }

    private func remove(_ id: UUID) {
        replacements.removeValue(forKey: id)
        sessions.first { $0.id == id }?.terminal.shutdown()
        sessions.removeAll { $0.id == id }
        if selectedSessionID == id { selectedSessionID = sessions.last?.id }
        if sessions.isEmpty { isPresented = false }
    }

    func removeConnection(_ id: UUID) {
        for session in sessions.filter({ $0.connection.id == id }) { remove(session.id) }
    }

    func dispose() {
        sessions.forEach { $0.terminal.shutdown() }
        sessions.removeAll(); selectedSessionID = nil; isPresented = false; replacements.removeAll()
    }
}
