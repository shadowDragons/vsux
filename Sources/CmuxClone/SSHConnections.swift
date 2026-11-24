import Foundation

/// Only metadata and a Keychain reference are archived; never a password.
struct SSHConnection: Identifiable, Codable, Equatable {
    enum Authentication: String, Codable, CaseIterable {
        case agent, password, privateKey
        var title: String {
            switch self {
            case .agent: return L("SSH Agent / 默认密钥")
            case .password: return L("密码")
            case .privateKey: return L("指定私钥")
            }
        }
    }

    var id = UUID()
    var name = ""
    var host = ""
    var port = 22
    var username = ""
    var authentication: Authentication = .agent
    var privateKeyPath = ""
    var credentialReference: SSHCredentialReference?
    var address: String { "\(username)@\(host):\(port)" }

    func validate() throws {
        let hostCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_:%")
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 256,
              !host.isEmpty, host.utf8.count <= 253, !host.hasPrefix("-"),
              host.unicodeScalars.allSatisfy({ hostCharacters.contains($0) }),
              (1...65535).contains(port), !username.isEmpty, username.utf8.count <= 256,
              !username.hasPrefix("-"), !username.contains(where: { $0.isWhitespace }),
              !username.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              privateKeyPath.utf8.count <= 4096,
              !privateKeyPath.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw SSHConnectionError.invalid
        }
        if authentication == .privateKey {
            guard (expandedKeyPath as NSString).isAbsolutePath else { throw SSHConnectionError.keyPath }
        }
    }

    var expandedKeyPath: String { (privateKeyPath as NSString).expandingTildeInPath }

    func launchCommand() throws -> String {
        try validate()
        // An explicit configuration prevents host aliases, proxy commands and
        // multiplexed connections from silently crossing workspace boundaries.
        var arguments = ["/usr/bin/ssh", "-F", "/dev/null", "-tt",
                         "-o", "StrictHostKeyChecking=ask", "-o", "ControlMaster=no",
                         "-o", "ControlPath=none", "-o", "ForwardAgent=no",
                         "-o", "ClearAllForwardings=yes", "-o", "ConnectTimeout=15",
                         "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=3",
                         "-p", String(port), "-l", username]
        switch authentication {
        case .agent: break
        case .password:
            arguments += ["-o", "PubkeyAuthentication=no", "-o", credentialReference == nil ? "PreferredAuthentications=keyboard-interactive,password" : "PreferredAuthentications=password"]
        case .privateKey:
            arguments += ["-o", "IdentitiesOnly=yes", "-i", expandedKeyPath]
        }
        arguments += ["--", host]
        return arguments.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
    }
}

enum SSHConnectionError: LocalizedError {
    case invalid, keyPath, keyMissing
    var errorDescription: String? {
        switch self {
        case .invalid: return L("请填写连接名称、有效主机、用户名和 1 到 65535 之间的端口。")
        case .keyPath: return L("请选择私钥文件，或填写以 / 或 ~/ 开头的路径。")
        case .keyMissing: return L("无法读取所选私钥文件。")
        }
    }
}

