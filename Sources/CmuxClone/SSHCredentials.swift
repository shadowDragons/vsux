import AppKit
import Security

struct SSHCredentialReference: Codable, Equatable {
    let workspaceID: UUID
    let connectionID: UUID
    var account: String { workspaceID.uuidString + "/" + connectionID.uuidString }
}

protocol SSHCredentialStore {
    func password(for reference: SSHCredentialReference) throws -> String?
    func setPassword(_ password: String?, for reference: SSHCredentialReference) throws
}

struct SSHKeychain: SSHCredentialStore {
    private let service = "local.vsux.ssh-password"
    private func query(_ reference: SSHCredentialReference) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: reference.account]
    }
    func password(for reference: SSHCredentialReference) throws -> String? {
        var query = query(reference)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { throw KeychainError(status: status) }
        return value
    }
    func setPassword(_ password: String?, for reference: SSHCredentialReference) throws {
        let query = query(reference)
        guard let password else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
            return
        }
        let attributes = [kSecValueData as String: Data(password.utf8)]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query.merging(attributes) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }
    private struct KeychainError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { L("无法访问 SSH 密码钥匙串：\(status)") }
    }
}

enum SSHPasswordUpdate {
    case keep, replace(String), remove
}

/// OpenSSH invokes this app as its askpass helper. Only identifiers enter the
/// environment; the password travels from Keychain to OpenSSH over stdout.
/// Host-key questions are always displayed, never answered with a credential.
enum SSHAskpass {
    static func environment(for reference: SSHCredentialReference, executable: String) -> [String: String] {
        ["SSH_ASKPASS": executable, "SSH_ASKPASS_REQUIRE": "force", "DISPLAY": "vsux", "LC_ALL": "C",
         "VSUX_SSH_ASKPASS": "1", "VSUX_SSH_WORKSPACE": reference.workspaceID.uuidString,
         "VSUX_SSH_CONNECTION": reference.connectionID.uuidString]
    }

    static func savedPassword(prompt: String, reference: SSHCredentialReference,
                              credentials: SSHCredentialStore) throws -> String? {
        let isPasswordPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().hasSuffix("password:")
        guard isPasswordPrompt else { return nil }
        return try credentials.password(for: reference)
    }

    @MainActor static func runIfRequested() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard environment["VSUX_SSH_ASKPASS"] == "1" else { return false }
        guard let workspace = environment["VSUX_SSH_WORKSPACE"].flatMap(UUID.init(uuidString:)),
              let connection = environment["VSUX_SSH_CONNECTION"].flatMap(UUID.init(uuidString:)) else { exit(1) }
        let prompt = CommandLine.arguments.dropFirst().joined(separator: " ")
        if environment["SSH_ASKPASS_PROMPT"] != "confirm" {
            do {
                if let password = try savedPassword(prompt: prompt,
                    reference: SSHCredentialReference(workspaceID: workspace, connectionID: connection),
                    credentials: SSHKeychain()) {
                    FileHandle.standardOutput.write(Data((password + "\n").utf8))
                    return true
                }
            } catch { exit(1) }
        }
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("SSH 身份验证")
        alert.informativeText = prompt
        alert.addButton(withTitle: L("继续")); alert.addButton(withTitle: L("取消"))
        let confirmation = environment["SSH_ASKPASS_PROMPT"] == "confirm" || prompt.contains("yes/no")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        if !confirmation { alert.accessoryView = field; alert.window.initialFirstResponder = field }
        guard alert.runModal() == .alertFirstButtonReturn else { exit(1) }
        FileHandle.standardOutput.write(Data(((confirmation ? "yes" : field.stringValue) + "\n").utf8))
        return true
    }
}

enum SSHCredentialError: LocalizedError {
    case missing, endpointChanged, invalidPassword
    var errorDescription: String? {
        switch self {
        case .missing: return L("找不到已保存的 SSH 密码，请重新保存或取消记住密码。")
        case .endpointChanged: return L("连接地址或用户名已改变，请重新输入密码或取消记住密码。")
        case .invalidPassword: return L("密码不能为空，也不能包含换行或空字符。")
        }
    }
}
