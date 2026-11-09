import Foundation
import Darwin

/// Environment used by GUI-launched Git and its hooks.
final class ShellEnvironment: @unchecked Sendable {
    static let shared = ShellEnvironment()
    private let base: [String: String]
    private let shell: URL
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var cached: [String: String]?

    init(base: [String: String] = ProcessInfo.processInfo.environment, shell: URL? = nil, timeout: TimeInterval = 8) {
        self.base = base
        self.shell = shell ?? URL(fileURLWithPath: base["SHELL"] ?? "/bin/zsh")
        self.timeout = timeout
    }

    func resolve() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let resolved = load() ?? base
        cached = resolved
        return resolved
    }

    private func load() -> [String: String]? {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("cmux-shell-env-" + UUID().uuidString)
        let outputURL = directory.appendingPathComponent("environment")
        guard (try? manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])) != nil else { return nil }
        defer { try? manager.removeItem(at: directory) }
        guard manager.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let output = try? FileHandle(forWritingTo: outputURL) else { return nil }
        defer { try? output.close() }

        let token = UUID().uuidString
        let process = Process()
        process.executableURL = shell
        // Only this fixed command is interpreted by a shell. Git argv and
        // repository paths never pass through it. NUL framing ignores startup
        // banners and preserves exported values with spaces or newlines.
        process.arguments = ["-ilc", "/usr/bin/printf '\\000CMUX_\(token)_BEGIN\\000'; /usr/bin/env -0; /usr/bin/printf '\\000CMUX_\(token)_END\\000'"]
        var environment = base
        environment["TERM"] = "dumb"
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: base["HOME"] ?? NSHomeDirectory(), isDirectory: true)
        process.standardInput = FileHandle.nullDevice
        // Use a file rather than a pipe: startup output or inherited child FDs
        // cannot block the reader indefinitely. Never log captured env values.
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning {
            // SIGKILL also handles shells that trap/ignore TERM. This is only
            // our private environment probe, never a user's terminal session.
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let size = try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4_194_304,
              let data = try? Data(contentsOf: outputURL),
              let start = data.range(of: Data("\0CMUX_\(token)_BEGIN\0".utf8)),
              let end = data.range(of: Data("\0CMUX_\(token)_END\0".utf8), in: start.upperBound..<data.endIndex) else { return nil }
        var resolved = base
        for record in data[start.upperBound..<end.lowerBound].split(separator: 0) {
            guard let equals = record.firstIndex(of: 61), equals != record.startIndex,
                  let key = String(data: record[..<equals], encoding: .utf8),
                  let value = String(data: record[record.index(after: equals)...], encoding: .utf8) else { continue }
            resolved[key] = value
        }
        guard let path = resolved["PATH"], !path.isEmpty else { return nil }
        // TERM=dumb belongs to the probe, not the Git/hook process.
        resolved["TERM"] = base["TERM"]
        return resolved
    }
}
