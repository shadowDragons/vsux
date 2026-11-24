import AppKit
import XCTest
import SwiftUI
import Security
@testable import CmuxClone

private final class MemoryCredentials: SSHCredentialStore {
    var passwords: [String: String] = [:]
    var failWrites = false
    func password(for reference: SSHCredentialReference) throws -> String? { passwords[reference.account] }
    func setPassword(_ password: String?, for reference: SSHCredentialReference) throws {
        if failWrites { throw CocoaError(.fileWriteNoPermission) }
        passwords[reference.account] = password
    }
}

final class SSHCredentialTests: XCTestCase {
    @MainActor func testCredentialsAreProjectScopedAndNeverArchived() throws {
        let credentials = MemoryCredentials()
        let a = Workspace(name: "A", directory: "/tmp"), b = Workspace(name: "B", directory: "/tmp")
        let model = WindowModel(workspaces: [a, b], sshCredentials: credentials)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { model.disposeAll(); try? FileManager.default.removeItem(at: directory) }
        let archive = WorkspaceSession(directory: directory); archive.register(model)
        let connection = SSHConnection(name: "Server", host: "localhost", username: "test", authentication: .password)
        try model.saveSSHConnection(connection, in: a.id, passwordUpdate: .replace("project-a-secret"))
        try model.saveSSHConnection(connection, in: b.id, passwordUpdate: .replace("project-b-secret"))
        let aReference = SSHCredentialReference(workspaceID: a.id, connectionID: connection.id)
        let bReference = SSHCredentialReference(workspaceID: b.id, connectionID: connection.id)
        XCTAssertEqual(try credentials.password(for: aReference), "project-a-secret")
        XCTAssertEqual(try credentials.password(for: bReference), "project-b-secret")
        let json = try String(contentsOf: archive.fileURL, encoding: .utf8)
        XCTAssertFalse(json.contains("project-a-secret")); XCTAssertFalse(json.contains("project-b-secret"))
        XCTAssertTrue(json.contains("credentialReference"))
        model.deleteSSHConnection(connection.id, in: a.id)
        XCTAssertNil(try credentials.password(for: aReference))
        XCTAssertEqual(try credentials.password(for: bReference), "project-b-secret")
    }

    @MainActor func testCredentialWriteFailureAndHostChangePreserveOriginalSettings() throws {
        let credentials = MemoryCredentials()
        let workspace = Workspace(name: "A", directory: "/tmp")
        let owner = WindowModel(workspaces: [workspace], sshCredentials: credentials)
        defer { owner.disposeAll() }
        var connection = SSHConnection(name: "Server", host: "localhost", username: "test", authentication: .password)
        try owner.saveSSHConnection(connection, in: workspace.id, passwordUpdate: .replace("original"))
        let saved = try XCTUnwrap(owner.workspace?.sshConnections.first)
        credentials.failWrites = true
        connection.name = "changed"
        XCTAssertThrowsError(try owner.saveSSHConnection(connection, in: workspace.id, passwordUpdate: .replace("new")))
        XCTAssertEqual(owner.workspace?.sshConnections.first, saved)
        credentials.failWrites = false
        connection.host = "another.example"
        XCTAssertThrowsError(try owner.saveSSHConnection(connection, in: workspace.id))
        XCTAssertEqual(owner.workspace?.sshConnections.first, saved)
        try owner.saveSSHConnection(connection, in: workspace.id, passwordUpdate: .remove)
        XCTAssertNil(owner.workspace?.sshConnections.first?.credentialReference)
        XCTAssertTrue(credentials.passwords.isEmpty)
    }

    @MainActor func testReconnectValidationAndSurfaceFailureKeepOriginal() throws {
        let runtime = SSHWorkspaceRuntime()
        defer { runtime.dispose() }
        var connection = SSHConnection(name: "Server", host: "localhost", username: "test")
        runtime.connect(connection, directory: "/tmp")
        let original = try XCTUnwrap(runtime.selectedSession)
        runtime.markEnded(original.id)
        connection.authentication = .privateKey
        connection.privateKeyPath = "/missing/" + UUID().uuidString
        runtime.reconnect(original.id, using: connection, directory: "/tmp")
        XCTAssertEqual(runtime.sessions.count, 1)
        XCTAssertTrue(runtime.selectedSession?.terminal === original.terminal)
        XCTAssertNotNil(runtime.error)
        connection.authentication = .agent
        runtime.reconnect(original.id, using: connection, directory: "/tmp")
        let replacement = try XCTUnwrap(runtime.selectedSession)
        XCTAssertEqual(runtime.sessions.count, 2)
        replacement.terminal.onSurfaceFailure?()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(runtime.sessions.count, 1)
        XCTAssertTrue(runtime.selectedSession?.terminal === original.terminal)
        runtime.reconnect(original.id, using: connection, directory: "/tmp")
        let successful = try XCTUnwrap(runtime.selectedSession)
        successful.terminal.onSurfaceReady?()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(runtime.sessions.count, 1)
        XCTAssertEqual(runtime.selectedSessionID, successful.id)
    }

    @MainActor func testTransferRetainsRuntimeAndSourceDisposalDoesNotEndIt() throws {
        let a = SSHWorkspaceStore(), b = SSHWorkspaceStore(), id = UUID()
        let runtime = a.runtime(for: id)
        runtime.connect(SSHConnection(name: "Server", host: "localhost", username: "test"), directory: "/tmp")
        let terminal = try XCTUnwrap(runtime.selectedSession?.terminal)
        a.transfer(id, to: b); a.disposeAll()
        XCTAssertNil(a.existing(id))
        XCTAssertTrue(b.existing(id) === runtime)
        XCTAssertTrue(b.terminals.first === terminal)
        b.disposeAll()
        XCTAssertTrue(runtime.sessions.isEmpty)
    }

    @MainActor func testCrossProjectCredentialCannotBeUsedToLaunch() throws {
        let credentials = MemoryCredentials(), a = UUID(), b = UUID()
        var connection = SSHConnection(name: "Server", host: "localhost", username: "test", authentication: .password)
        connection.credentialReference = SSHCredentialReference(workspaceID: a, connectionID: connection.id)
        try credentials.setPassword("secret", for: connection.credentialReference!)
        let runtime = SSHWorkspaceRuntime(workspaceID: b, credentials: credentials)
        runtime.connect(connection, directory: "/tmp")
        XCTAssertTrue(runtime.sessions.isEmpty); XCTAssertNotNil(runtime.error)
        let environment = SSHAskpass.environment(for: connection.credentialReference!, executable: "/test/vsux")
        XCTAssertFalse(environment.values.contains("secret"))
        XCTAssertEqual(environment["SSH_ASKPASS_REQUIRE"], "force")
    }

    func testKeychainRoundTripUsesOnlyDisposableTestCredentials() throws {
        let keychain = SSHKeychain()
        let reference = SSHCredentialReference(workspaceID: UUID(), connectionID: UUID())
        defer { try? keychain.setPassword(nil, for: reference) }
        XCTAssertNil(try keychain.password(for: reference))
        try keychain.setPassword("vsux-test-only", for: reference)
        XCTAssertEqual(try keychain.password(for: reference), "vsux-test-only")
        try keychain.setPassword("updated-test-only", for: reference)
        XCTAssertEqual(try keychain.password(for: reference), "updated-test-only")
        try keychain.setPassword(nil, for: reference)
        XCTAssertNil(try keychain.password(for: reference))
    }
    @MainActor func testClosingLiveSessionRespectsCancellation() throws {
        _ = NSApplication.shared
        var approved = false
        var confirmations = 0
        let runtime = SSHWorkspaceRuntime(confirmTermination: { confirmations += 1; return approved })
        runtime.connect(SSHConnection(name: "Test", host: "127.0.0.1", port: 1, username: "test"), directory: "/tmp")
        let session = try XCTUnwrap(runtime.selectedSession)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = session.terminal
        defer { runtime.dispose(); window.orderOut(nil) }
        XCTAssertNotNil(session.terminal.surface)
        runtime.close(session.id)
        XCTAssertEqual(confirmations, 1)
        XCTAssertEqual(runtime.sessions.count, 1)
        XCTAssertNotNil(session.terminal.surface)
        approved = true
        runtime.close(session.id)
        XCTAssertEqual(confirmations, 2)
        XCTAssertTrue(runtime.sessions.isEmpty)
        XCTAssertNil(session.terminal.surface)
    }

    func testAskpassExecutableReturnsOnlyDisposableKeychainPassword() throws {
        let keychain = SSHKeychain()
        let reference = SSHCredentialReference(workspaceID: UUID(), connectionID: UUID())
        let password = "askpass-test-" + UUID().uuidString
        defer { try? keychain.setPassword(nil, for: reference) }
        let executable = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("CmuxClone")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))
        // XCTest and the askpass executable are separate signed programs. Give
        // only this disposable item an explicit ACL for both, just as the real
        // app and its helper share the same executable in a packaged release.
        var testApplication: SecTrustedApplication?
        var helperApplication: SecTrustedApplication?
        XCTAssertEqual(SecTrustedApplicationCreateFromPath(nil, &testApplication), errSecSuccess)
        XCTAssertEqual(SecTrustedApplicationCreateFromPath(executable.path, &helperApplication), errSecSuccess)
        var access: SecAccess?
        let trusted = [try XCTUnwrap(testApplication), try XCTUnwrap(helperApplication)] as CFArray
        XCTAssertEqual(SecAccessCreate("vsux disposable askpass test" as CFString, trusted, &access), errSecSuccess)
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "local.vsux.ssh-password",
            kSecAttrAccount as String: reference.account,
            kSecValueData as String: Data(password.utf8),
            kSecAttrAccess as String: try XCTUnwrap(access)
        ]
        XCTAssertEqual(SecItemAdd(item as CFDictionary, nil), errSecSuccess)
        let process = Process()
        process.executableURL = executable
        process.arguments = ["test@localhost's password: "]
        process.environment = ProcessInfo.processInfo.environment.merging(SSHAskpass.environment(for: reference, executable: executable.path)) { _, new in new }
        let output = Pipe(); process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(8)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { process.terminate(); XCTFail("Askpass did not complete"); return }
        let result = output.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(result == Data((password + "\n").utf8), "Askpass must return only the saved password")
    }

    @MainActor func testPasswordEditorRendersWithSavedCredential() throws {
        _ = NSApplication.shared
        let credentials = MemoryCredentials(), workspace = Workspace(name: "Credential Test", directory: "/tmp")
        let model = WindowModel(workspaces: [workspace], sshCredentials: credentials)
        var connection = SSHConnection(name: "Server", host: "localhost", username: "test", authentication: .password)
        connection.credentialReference = SSHCredentialReference(workspaceID: workspace.id, connectionID: connection.id)
        let editor = SSHConnectionEditor(model: model, workspaceID: workspace.id, workspaceName: workspace.name, connection: connection)
        let host = NSHostingView(rootView: editor.background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; window.orderFront(nil)
        defer { model.disposeAll(); window.orderOut(nil) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        host.layoutSubtreeIfNeeded()
        func secureFields(_ view: NSView) -> [NSSecureTextField] {
            (view as? NSSecureTextField).map { [$0] } ?? view.subviews.flatMap { secureFields($0) }
        }
        let field = try XCTUnwrap(secureFields(host).first)
        XCTAssertTrue(field.stringValue.isEmpty, "Saved passwords must not be loaded into the editor")
        XCTAssertTrue(host.bounds.contains(field.convert(field.bounds, to: host)))
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to:
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/ssh-credentials.png"))
    }

}
