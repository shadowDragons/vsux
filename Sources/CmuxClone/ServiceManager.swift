import Foundation
import Combine

/// Keeps only the most recent output in memory; draining the pipe prevents
/// verbose services from blocking even when their log window is closed.
@MainActor
final class ServiceOutput: ObservableObject {
    @Published private(set) var text = ""
    var onUpdate: ((String) -> Void)?
    private var bytes = Data()
    private let pipe = Pipe()
    private let limit = 262_144

    init() {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            Task { @MainActor [weak self] in self?.append(data) }
        }
    }

    func attach(to process: Process) {
        process.standardOutput = pipe
        process.standardError = pipe
    }

    func append(_ data: Data) {
        bytes.append(data)
        if bytes.count > limit { bytes = Data(bytes.suffix(limit)) }
        text = String(decoding: bytes, as: UTF8.self)
            .replacingOccurrences(of: "\u{001B}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        onUpdate?(text)
    }

    deinit { pipe.fileHandleForReading.readabilityHandler = nil }
}

/// Runtime handle for a background service; no terminal surface is created.
@MainActor
final class ServiceProcess {
    let serviceID: UUID
    let process: Process

    init(serviceID: UUID, process: Process) {
        self.serviceID = serviceID
        self.process = process
    }
}

@MainActor
extension WindowModel {
    var hasRunningServices: Bool {
        serviceStatuses.values.contains { $0 == .running || $0 == .starting || $0 == .stopping }
    }

    func services(in workspaceID: UUID) -> [WorkspaceService] {
        workspaces.first(where: { $0.id == workspaceID })?.services ?? []
    }

    func output(for serviceID: UUID) -> ServiceOutput {
        if let output = serviceOutputs[serviceID] { return output }
        let output = ServiceOutput()
        serviceOutputs[serviceID] = output
        return output
    }

    func addService(_ service: WorkspaceService, to workspaceID: UUID) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        var value = service
        value.name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
        value.command = value.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.name.isEmpty, !value.command.isEmpty else { return }
        workspaces[index].services.append(value)
    }

    func updateService(_ service: WorkspaceService, in workspaceID: UUID) {
        guard let wi = workspaces.firstIndex(where: { $0.id == workspaceID }),
              let si = workspaces[wi].services.firstIndex(where: { $0.id == service.id }) else { return }
        let wasRunning = serviceProcesses[service.id] != nil
        if wasRunning { stopService(service.id) }
        var value = service
        value.name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
        value.command = value.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.name.isEmpty, !value.command.isEmpty else { return }
        workspaces[wi].services[si] = value
        if wasRunning {
            let deadline = Date().addingTimeInterval(2)
            Task { @MainActor [weak self] in
                guard let self else { return }
                while self.serviceProcesses[value.id] != nil && Date() < deadline {
                    try? await Task.sleep(for: .milliseconds(25))
                }
                guard self.serviceProcesses[value.id] == nil else { return }
                self.startService(value.id)
            }
        }
    }

    func deleteService(_ id: UUID, from workspaceID: UUID) {
        stopService(id)
        guard let wi = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        workspaces[wi].services.removeAll { $0.id == id }
        serviceStatuses.removeValue(forKey: id)
    }

    func startServices(in workspaceID: UUID) {
        for service in services(in: workspaceID) { startService(service.id) }
    }

    func startService(_ id: UUID) {
        guard serviceProcesses[id] == nil,
              let match = workspaces.enumerated().first(where: { $0.element.services.contains(where: { $0.id == id }) }),
              let service = match.element.services.first(where: { $0.id == id }) else { return }
        let directory = service.directory(in: match.element.directory)
        let output = ServiceOutput()
        serviceOutputs[id] = output
        output.append(Data((L("运行目录：\(directory.path)") + "\n").utf8))
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            serviceStatuses[id] = .failed
            output.append(Data(L("运行目录不存在：\(directory.path)").utf8))
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", service.command]
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        process.environment = ShellEnvironment.shared.resolve()
        output.attach(to: process)
        let runtime = ServiceProcess(serviceID: id, process: process)
        serviceProcesses[id] = runtime
        serviceStatuses[id] = .starting
        process.terminationHandler = { [weak self, weak process] _ in
            guard let process else { return }
            Task { @MainActor [weak self] in
                self?.serviceDidTerminate(id: id, process: process)
            }
        }
        do {
            try process.run()
            serviceStatuses[id] = .running
        } catch {
            serviceProcesses.removeValue(forKey: id)
            serviceStatuses[id] = .failed
            self.error = L("无法启动服务：\(error.localizedDescription)")
            output.append(Data((self.error ?? "").utf8))
        }
    }

    func stopService(_ id: UUID) {
        guard let runtime = serviceProcesses[id] else {
            serviceStatuses[id] = .stopped
            return
        }
        serviceStatuses[id] = .stopping
        runtime.process.terminate()
        if !runtime.process.isRunning {
            serviceDidTerminate(id: id, process: runtime.process)
        }
    }

    func restartService(_ id: UUID) {
        guard serviceProcesses[id] != nil else { startService(id); return }
        stopService(id)
        let deadline = Date().addingTimeInterval(2)
        Task { @MainActor [weak self] in
            guard let self else { return }
            while self.serviceProcesses[id] != nil && Date() < deadline {
                try? await Task.sleep(for: .milliseconds(25))
            }
            guard self.serviceProcesses[id] == nil else { return }
            self.startService(id)
        }
    }

    func stopAllServices() {
        for id in Array(serviceProcesses.keys) { stopService(id) }
    }

    func stopServices(in workspaceID: UUID) {
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }) else { return }
        for id in workspace.services.map(\.id) { stopService(id) }
    }

    func transferServices(in workspaceID: UUID, to destination: WindowModel) {
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }) else { return }
        for id in workspace.services.map(\.id) {
            destination.serviceOutputs[id] = serviceOutputs.removeValue(forKey: id)
            guard let runtime = serviceProcesses.removeValue(forKey: id) else { continue }
            destination.serviceProcesses[id] = runtime
            destination.serviceStatuses[id] = serviceStatuses[id] ?? .running
            runtime.process.terminationHandler = { [weak destination, weak process = runtime.process] _ in
                guard let process else { return }
                Task { @MainActor [weak destination] in
                    destination?.serviceDidTerminate(id: id, process: process)
                }
            }
            serviceStatuses.removeValue(forKey: id)
        }
    }

    func serviceDidTerminate(id: UUID, process: Process) {
        guard serviceProcesses[id]?.process === process else { return }
        let wasStopping = serviceStatuses[id] == .stopping
        serviceProcesses.removeValue(forKey: id)
        serviceStatuses[id] = wasStopping || process.terminationStatus == 0 ? .stopped : .failed
    }
}
