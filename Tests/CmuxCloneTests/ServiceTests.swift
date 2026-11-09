import Foundation
import XCTest
@testable import CmuxClone

final class ServiceTests: XCTestCase {
    @MainActor func testStartAllServicesIsScopedSkipsRunningAndRetriesFailedServices() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(name: "project", directory: root.path)
        let other = Workspace(name: "other", directory: root.path)
        let model = WindowModel(workspaces: [workspace, other])
        defer { model.stopAllServices() }
        let running = WorkspaceService(name: "running", command: "sleep 30")
        let stopped = WorkspaceService(name: "stopped", command: "sleep 30")
        let failed = WorkspaceService(name: "failed", command: "sleep 30", workingDirectory: "backend")
        let unrelated = WorkspaceService(name: "other", command: "sleep 30")
        for service in [running, stopped, failed] { model.addService(service, to: workspace.id) }
        model.addService(unrelated, to: other.id)
        model.startService(running.id)
        let originalProcess = try XCTUnwrap(model.serviceProcesses[running.id]?.process)
        let originalOutput = model.output(for: running.id)
        model.startService(failed.id)
        XCTAssertEqual(model.serviceStatuses[failed.id], .failed)

        // One failure must not prevent other services from starting.
        model.selectedWorkspaceID = other.id
        model.startServices(in: workspace.id)
        XCTAssertEqual(model.serviceStatuses[stopped.id], .running)
        XCTAssertEqual(model.serviceStatuses[failed.id], .failed)
        XCTAssertNil(model.serviceProcesses[unrelated.id])

        try FileManager.default.createDirectory(at: root.appendingPathComponent("backend"), withIntermediateDirectories: true)
        model.startServices(in: workspace.id)
        XCTAssertEqual(model.serviceStatuses[failed.id], .running)
        XCTAssertTrue(model.serviceProcesses[running.id]?.process === originalProcess)
        XCTAssertTrue(model.output(for: running.id) === originalOutput)
        XCTAssertEqual(model.serviceProcesses.count, 3)
        XCTAssertTrue(model.terminals.isEmpty)

        model.stopAllServices()
        let deadline = Date().addingTimeInterval(2)
        while !model.serviceProcesses.isEmpty && Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(model.serviceProcesses.isEmpty)
    }

    @MainActor func testServiceUsesConfiguredSubdirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let backend = root.appendingPathComponent("apps/server")
        try FileManager.default.createDirectory(at: backend, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: backend.appendingPathComponent("pom.xml"))
        let data = try JSONSerialization.data(withJSONObject: [
            "id": UUID().uuidString, "name": "backend", "command": "test -f pom.xml",
            "workingDirectory": "apps/server"
        ])
        let service = try JSONDecoder().decode(WorkspaceService.self, from: data)
        let model = WindowModel(workspaces: [Workspace(name: "project", directory: root.path)])
        model.addService(service, to: model.selectedWorkspaceID)
        let session = WorkspaceSession(directory: root.appendingPathComponent("state"))
        session.register(model)
        session.save()
        XCTAssertEqual(WorkspaceSession(directory: root.appendingPathComponent("state")).restore().first?.workspace?.services, [service])
        model.startService(service.id)
        let deadline = Date().addingTimeInterval(5)
        while model.serviceProcesses[service.id] != nil && Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(model.serviceStatuses[service.id], .stopped, "The command must run beside the backend pom.xml")
    }

    @MainActor func testFailedCommandPreservesStandardOutputAndError() async throws {
        let model = WindowModel()
        let service = WorkspaceService(name: "failure", command: "printf 'service-out\\n'; printf 'service-error\\n' >&2; exit 7")
        model.addService(service, to: model.selectedWorkspaceID)
        model.startService(service.id)
        let deadline = Date().addingTimeInterval(5)
        while (model.serviceProcesses[service.id] != nil || !model.output(for: service.id).text.contains("service-error")) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(model.serviceStatuses[service.id], .failed)
        XCTAssertTrue(model.output(for: service.id).text.contains("service-out"))
        XCTAssertTrue(model.output(for: service.id).text.contains("service-error"))
        XCTAssertTrue(model.terminals.isEmpty)
    }

    @MainActor func testMissingDirectoryShowsReasonAndDoesNotStartProcess() {
        let model = WindowModel()
        let path = "/tmp/cmux-missing-" + UUID().uuidString
        let service = WorkspaceService(name: "missing", command: "sleep 10", workingDirectory: path)
        model.addService(service, to: model.selectedWorkspaceID)
        model.startService(service.id)
        XCTAssertEqual(model.serviceStatuses[service.id], .failed)
        XCTAssertNil(model.serviceProcesses[service.id])
        XCTAssertTrue(model.output(for: service.id).text.contains(path))
    }

    @MainActor func testLegacyServiceDefaultsToWorkspaceAndOutputIsBounded() throws {
        let data = try JSONSerialization.data(withJSONObject: ["id": UUID().uuidString, "name": "legacy", "command": "true"])
        let service = try JSONDecoder().decode(WorkspaceService.self, from: data)
        XCTAssertNil(service.workingDirectory)
        XCTAssertEqual(service.directory(in: "/tmp/project").path, "/tmp/project")
        let output = ServiceOutput()
        output.append(Data(repeating: 65, count: 1_000_000))
        output.append(Data("latest output".utf8))
        XCTAssertLessThanOrEqual(output.text.utf8.count, 262_144)
        XCTAssertTrue(output.text.hasSuffix("latest output"))
    }

    @MainActor func testServicesPersistWithTheirWorkspaceAndDoNotCreateTerminals() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = WorkspaceSession(directory: root.appendingPathComponent("state"))
        let model = WindowModel(workspaces: [Workspace(name: "project", directory: root.path)])
        session.register(model)
        let service = WorkspaceService(name: "后端", command: "sleep 10")
        model.addService(service, to: model.selectedWorkspaceID)

        let restored = try XCTUnwrap(WorkspaceSession(directory: root.appendingPathComponent("state")).restore().first)
        XCTAssertEqual(restored.workspace?.services, [service])
        XCTAssertTrue(restored.terminals.isEmpty)
        XCTAssertTrue(restored.serviceProcesses.isEmpty)
    }

    @MainActor func testServiceStartsRunsInWorkspaceDirectoryAndStops() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WindowModel(workspaces: [Workspace(name: "project", directory: root.path)])
        let service = WorkspaceService(name: "worker", command: "sleep 30")
        model.addService(service, to: model.selectedWorkspaceID)
        model.startService(service.id)
        XCTAssertEqual(model.serviceStatuses[service.id], .running)
        XCTAssertTrue(model.terminals.isEmpty)
        XCTAssertEqual(model.serviceProcesses[service.id]?.process.currentDirectoryURL?.path, root.path)
        model.stopService(service.id)
        let deadline = Date().addingTimeInterval(2)
        while model.serviceProcesses[service.id] != nil && Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertNil(model.serviceProcesses[service.id])
        XCTAssertEqual(model.serviceStatuses[service.id], .stopped)
    }

    @MainActor func testEditingRunningServiceRestartsWithUpdatedCommand() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WindowModel(workspaces: [Workspace(name: "project", directory: root.path)])
        let service = WorkspaceService(name: "worker", command: "sleep 30")
        model.addService(service, to: model.selectedWorkspaceID)
        model.startService(service.id)
        var edited = service
        edited.command = "sleep 30"
        model.updateService(edited, in: model.selectedWorkspaceID)
        let deadline = Date().addingTimeInterval(2)
        while model.serviceStatuses[service.id] != .running && Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(model.serviceStatuses[service.id], .running)
        model.stopService(service.id)
    }
}
