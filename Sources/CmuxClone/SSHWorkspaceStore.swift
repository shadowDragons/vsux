import AppKit

/// Owns runtime lifetime and transfer; callers never mutate its session map.
@MainActor
final class SSHWorkspaceStore {
    private var runtimes: [UUID: SSHWorkspaceRuntime] = [:]
    let credentials: SSHCredentialStore
    init(credentials: SSHCredentialStore = SSHKeychain()) { self.credentials = credentials }
    var isEmpty: Bool { runtimes.isEmpty }
    var terminals: [GhosttyTerminalView] { runtimes.values.flatMap(\.terminals) }
    var needsConfirmation: Bool { runtimes.values.contains { $0.needsConfirmation } }
    func existing(_ id: UUID) -> SSHWorkspaceRuntime? { runtimes[id] }
    func runtime(for id: UUID) -> SSHWorkspaceRuntime {
        if let runtime = runtimes[id] { return runtime }
        let runtime = SSHWorkspaceRuntime(workspaceID: id, credentials: credentials)
        runtimes[id] = runtime
        return runtime
    }
    func dispose(_ id: UUID) { runtimes.removeValue(forKey: id)?.dispose() }
    func disposeAll() { runtimes.values.forEach { $0.dispose() }; runtimes.removeAll() }
    func transfer(_ id: UUID, to destination: SSHWorkspaceStore) {
        guard let runtime = runtimes.removeValue(forKey: id) else { return }
        destination.dispose(id)
        runtime.terminals.forEach { $0.removeFromSuperview() }
        destination.runtimes[id] = runtime
    }
    func closeFocused(_ responder: NSResponder?) -> Bool {
        guard let terminal = responder as? GhosttyTerminalView,
              let runtime = runtimes.values.first(where: { $0.owns(terminal) }) else { return false }
        runtime.close(terminal.paneID)
        return true // Cancellation must not fall through to the local terminal.
    }
}

extension WindowModel {
    var allTerminals: [GhosttyTerminalView] { Array(terminals.values) + ssh.terminals }
    func closeFocusedSSHSession() -> Bool {
        if tools.content == .terminal, let runtime = ssh.existing(selectedWorkspaceID), let session = runtime.presentedSession {
            runtime.close(session.id)
            focusTerminal()
            return true
        }
        return ssh.closeFocused(window?.firstResponder)
    }
    func openSSHConnection(_ connection: SSHConnection, in workspaceID: UUID) {
        guard !isDisposed, let workspace = workspaces.first(where: { $0.id == workspaceID }),
              workspace.sshConnections.contains(where: { $0.id == connection.id }) else { return }
        let runtime = sshRuntime(for: workspaceID)
        runtime.connect(connection, directory: workspace.directory)
        guard runtime.presentedSession != nil else { return }
        selectedWorkspaceID = workspaceID; tools.content = .terminal; showFind = false
        focusTerminal()
    }
    func transferSSH(in id: UUID, to destination: WindowModel) { ssh.transfer(id, to: destination.ssh) }

    func sshRuntime(for workspaceID: UUID) -> SSHWorkspaceRuntime {
        ssh.runtime(for: workspaceID)
    }

    @discardableResult
    func saveSSHConnection(_ connection: SSHConnection, in workspaceID: UUID, passwordUpdate: SSHPasswordUpdate = .keep) throws -> Bool {
        guard !isDisposed, let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return false }
        var connection = connection
        try connection.validate()
        let existing = workspaces[index].sshConnections.first { $0.id == connection.id }
        guard existing != nil || workspaces[index].sshConnections.count < 500 else { throw SSHConnectionError.invalid }
        let reference = SSHCredentialReference(workspaceID: workspaceID, connectionID: connection.id)
        // Never trust an archived or caller-supplied reference to another project.
        connection.credentialReference = existing?.credentialReference == reference ? reference : nil
        let update: SSHPasswordUpdate = connection.authentication == .password ? passwordUpdate : .remove
        switch update {
        case .keep:
            if let existing, existing.host != connection.host || existing.port != connection.port || existing.username != connection.username,
               connection.credentialReference != nil { throw SSHCredentialError.endpointChanged }
        case .replace(let password):
            guard !password.isEmpty, !password.contains("\n"), !password.contains("\0") else { throw SSHCredentialError.invalidPassword }
            try ssh.credentials.setPassword(password, for: reference)
            connection.credentialReference = reference
        case .remove:
            if existing?.credentialReference != nil { try ssh.credentials.setPassword(nil, for: reference) }
            connection.credentialReference = nil
        }
        if let connectionIndex = workspaces[index].sshConnections.firstIndex(where: { $0.id == connection.id }) {
            workspaces[index].sshConnections[connectionIndex] = connection
        } else {
            guard workspaces[index].sshConnections.count < 500 else { throw SSHConnectionError.invalid }
            workspaces[index].sshConnections.append(connection)
        }
        return true
    }

    func deleteSSHConnection(_ id: UUID, in workspaceID: UUID) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        guard workspaces[index].sshConnections.contains(where: { $0.id == id }) else { return }
        do {
            if workspaces[index].sshConnections.first(where: { $0.id == id })?.credentialReference != nil {
                try ssh.credentials.setPassword(nil, for: SSHCredentialReference(workspaceID: workspaceID, connectionID: id))
            }
        } catch { self.error = error.localizedDescription; return }
        ssh.existing(workspaceID)?.removeConnection(id)
        workspaces[index].sshConnections.removeAll { $0.id == id }
    }
}
