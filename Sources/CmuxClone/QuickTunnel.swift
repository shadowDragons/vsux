import Foundation

enum QuickTunnelPhase: Equatable {
    case starting
    case running
    case stopping
    case stopped
    case failed

    var title: String {
        switch self {
        case .starting: return L("启动中")
        case .running: return L("运行中")
        case .stopping: return L("停止中")
        case .stopped: return L("已停止")
        case .failed: return L("异常退出")
        }
    }
}

struct QuickTunnelStatus: Equatable {
    var port: Int
    var phase: QuickTunnelPhase
    var publicURL: String?
    var detail: String?
}

@MainActor
final class QuickTunnelProcess {
    let process: Process
    let output: ServiceOutput

    init(process: Process, output: ServiceOutput) {
        self.process = process
        self.output = output
    }
}

enum CloudflaredQuickTunnel {
    static let installationCommand = "brew install cloudflared"
    static let installationGuide = URL(string: "https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/")!

    static func port(from input: String) -> Int? {
        guard !input.isEmpty,
              input.utf8.allSatisfy({ (48...57).contains($0) }),
              let port = Int(input), (1...65_535).contains(port) else {
            return nil
        }
        return port
    }

    static func executableURL(environment: [String: String], fileManager: FileManager = .default) -> URL? {
        let pathEntries = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let candidates = pathEntries + ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]
        for directory in candidates where !directory.isEmpty {
            let path = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("cloudflared").path
            if fileManager.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    static func arguments(port: Int) -> [String] {
        ["tunnel", "--no-autoupdate", "--url", "http://127.0.0.1:\(port)"]
    }

    static func publicURL(in output: String) -> String? {
        let pattern = #"https://[A-Za-z0-9.-]+\.trycloudflare\.com(?=$|[\s),\]])"#
        guard let range = output.range(of: pattern, options: .regularExpression) else { return nil }
        return String(output[range])
    }
}

@MainActor
extension WindowModel {
    func startQuickTunnel(in workspaceID: UUID, port: Int, executableURL: URL) {
        guard (1...65_535).contains(port), quickTunnelProcesses[workspaceID] == nil else { return }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = CloudflaredQuickTunnel.arguments(port: port)
        process.currentDirectoryURL = workspaces.first(where: { $0.id == workspaceID })
            .map { URL(fileURLWithPath: $0.directory, isDirectory: true) }
        process.standardInput = FileHandle.nullDevice
        process.environment = cloudflaredEnvironment()

        let output = ServiceOutput()
        output.attach(to: process)
        let runtime = QuickTunnelProcess(process: process, output: output)
        quickTunnelProcesses[workspaceID] = runtime
        quickTunnelStatuses[workspaceID] = QuickTunnelStatus(port: port, phase: .starting, publicURL: nil, detail: nil)
        observeQuickTunnelOutput(in: workspaceID, runtime: runtime)
        process.terminationHandler = { [weak self, weak process] _ in
            guard let process else { return }
            Task { @MainActor [weak self] in
                self?.quickTunnelDidTerminate(in: workspaceID, process: process)
            }
        }

        do {
            try process.run()
        } catch {
            quickTunnelProcesses.removeValue(forKey: workspaceID)
            output.onUpdate = nil
            quickTunnelStatuses[workspaceID] = QuickTunnelStatus(
                port: port, phase: .failed, publicURL: nil,
                detail: L("无法启动 cloudflared：\(error.localizedDescription)")
            )
        }
    }

    func stopQuickTunnel(in workspaceID: UUID) {
        guard let runtime = quickTunnelProcesses[workspaceID] else {
            if let status = quickTunnelStatuses[workspaceID] {
                quickTunnelStatuses[workspaceID] = QuickTunnelStatus(port: status.port, phase: .stopped, publicURL: nil, detail: nil)
            }
            return
        }
        quickTunnelStatuses[workspaceID]?.phase = .stopping
        if runtime.process.isRunning {
            runtime.process.terminate()
        } else {
            quickTunnelDidTerminate(in: workspaceID, process: runtime.process)
        }
    }

    func stopAllQuickTunnels() {
        for id in Array(quickTunnelProcesses.keys) { stopQuickTunnel(in: id) }
    }

    func transferQuickTunnel(in workspaceID: UUID, to destination: WindowModel) {
        guard let runtime = quickTunnelProcesses.removeValue(forKey: workspaceID) else { return }
        destination.quickTunnelProcesses[workspaceID] = runtime
        destination.quickTunnelStatuses[workspaceID] = quickTunnelStatuses.removeValue(forKey: workspaceID)
        destination.observeQuickTunnelOutput(in: workspaceID, runtime: runtime)
        runtime.process.terminationHandler = { [weak destination, weak process = runtime.process] _ in
            guard let process else { return }
            Task { @MainActor [weak destination] in
                destination?.quickTunnelDidTerminate(in: workspaceID, process: process)
            }
        }
    }

    private func observeQuickTunnelOutput(in workspaceID: UUID, runtime: QuickTunnelProcess) {
        runtime.output.onUpdate = { [weak self, weak process = runtime.process] text in
            guard let self, let process,
                  self.quickTunnelProcesses[workspaceID]?.process === process,
                  let address = CloudflaredQuickTunnel.publicURL(in: text) else { return }
            self.quickTunnelStatuses[workspaceID]?.phase = .running
            self.quickTunnelStatuses[workspaceID]?.publicURL = address
            self.quickTunnelStatuses[workspaceID]?.detail = nil
        }
    }

    private func quickTunnelDidTerminate(in workspaceID: UUID, process: Process) {
        guard let runtime = quickTunnelProcesses[workspaceID], runtime.process === process else { return }
        let status = quickTunnelStatuses[workspaceID]
        let wasStopping = status?.phase == .stopping
        let detail = runtime.output.text
            .split(whereSeparator: \.isNewline)
            .suffix(3)
            .joined(separator: "\n")
        runtime.output.onUpdate = nil
        quickTunnelProcesses.removeValue(forKey: workspaceID)
        guard !isDisposed, workspaces.contains(where: { $0.id == workspaceID }) else {
            quickTunnelStatuses.removeValue(forKey: workspaceID)
            return
        }
        if wasStopping || process.terminationStatus == 0 {
            quickTunnelStatuses[workspaceID] = QuickTunnelStatus(port: status?.port ?? 0, phase: .stopped, publicURL: nil, detail: nil)
        } else {
            quickTunnelStatuses[workspaceID] = QuickTunnelStatus(
                port: status?.port ?? 0, phase: .failed, publicURL: nil,
                detail: detail.isEmpty ? L("cloudflared 在生成公网地址前退出。") : detail
            )
        }
    }

    private func cloudflaredEnvironment() -> [String: String] {
        let source = ShellEnvironment.shared.resolve()
        let inheritedKeys = ["PATH", "HOME", "TMPDIR", "LANG", "LC_ALL", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "SSL_CERT_FILE", "SSL_CERT_DIR"]
        return source.filter { inheritedKeys.contains($0.key) }
    }
}
