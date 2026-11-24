import AppKit
import CGhostty
import Darwin
import SwiftUI
import XCTest
@testable import CmuxClone

final class SSHTests: XCTestCase {
    private func connection() -> SSHConnection {
        SSHConnection(name: "Server", host: "127.0.0.1", port: 22, username: "developer")
    }

    func testRejectsInvalidConnectionAndOptionInjection() throws {
        for host in ["", "-oProxyCommand=touch /tmp/injected", "host;touch", "$(whoami)", "host\nname", "user@host"] {
            var value = connection(); value.host = host
            XCTAssertThrowsError(try value.launchCommand(), host)
        }
        for host in ["example.com", "192.168.0.1", "::1", "fe80::1%en0"] {
            var value = connection(); value.host = host
            XCTAssertNoThrow(try value.launchCommand(), host)
        }
        for port in [0, -1, 65536] {
            var value = connection(); value.port = port
            XCTAssertThrowsError(try value.validate())
        }
        var value = connection(); value.authentication = .privateKey; value.privateKeyPath = "relative-key"
        XCTAssertThrowsError(try value.validate())
    }

    func testSSHCommandQuotesArgumentsAndDisablesMultiplexingAndConfigCommands() throws {
        var value = connection()
        value.authentication = .privateKey
        value.privateKeyPath = "/tmp/key with ' quote $(touch injected)"
        let command = try value.launchCommand()
        // Execute the generated argument list with printf substituted for ssh.
        // The shell must preserve every byte as one argument, without expansion.
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command.replacingOccurrences(of: "'/usr/bin/ssh'", with: "/usr/bin/printf '%s\\n'")]
        let output = Pipe(); process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let arguments = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        XCTAssertTrue(arguments.contains(value.privateKeyPath))
        XCTAssertTrue(arguments.contains("ControlPath=none"))
        XCTAssertTrue(arguments.contains("ForwardAgent=no"))
        XCTAssertTrue(arguments.contains("/dev/null"))
        XCTAssertTrue(arguments.contains("StrictHostKeyChecking=ask"))
        XCTAssertEqual(arguments.suffix(3), ["--", "127.0.0.1", ""])
        value.authentication = .password
        XCTAssertTrue(try value.launchCommand().contains("PubkeyAuthentication=no"))
        XCTAssertFalse(try value.launchCommand().contains(value.privateKeyPath))
    }

    @MainActor func testWorkspaceIsolationPersistenceAndDeletion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = Workspace(name: "A", directory: "/tmp")
        let second = Workspace(name: "B", directory: "/tmp")
        let model = WindowModel(workspaces: [first, second])
        defer { model.disposeAll() }
        let persistence = WorkspaceSession(directory: root); persistence.register(model)
        let value = connection()
        XCTAssertTrue(try model.saveSSHConnection(value, in: first.id))
        XCTAssertTrue(model.workspaces[1].sshConnections.isEmpty)
        model.selectedWorkspaceID = second.id
        var other = value; other.name = "B's server"
        // Even an identical connection ID is owned by the explicit project.
        XCTAssertTrue(try model.saveSSHConnection(other, in: second.id))
        let a = model.sshRuntime(for: first.id), b = model.sshRuntime(for: second.id)
        a.connect(value, directory: "/tmp"); b.connect(other, directory: "/tmp")
        XCTAssertFalse(a === b)
        XCTAssertFalse(a.selectedSession!.terminal === b.selectedSession!.terminal)
        let firstTerminal = a.selectedSession!.terminal
        model.selectedWorkspaceID = first.id
        XCTAssertTrue(model.sshRuntime(for: first.id).selectedSession!.terminal === firstTerminal)
        XCTAssertTrue(model.paneTabs.isEmpty)
        let restored = try XCTUnwrap(WorkspaceSession(directory: root).restore().first)
        XCTAssertEqual(restored.workspaces[0].sshConnections, [value])
        XCTAssertEqual(restored.workspaces[1].sshConnections, [other])
        XCTAssertTrue(restored.ssh.isEmpty, "Restoring projects must not auto-connect")
        model.deleteSSHConnection(value.id, in: first.id)
        XCTAssertTrue(a.sessions.isEmpty)
        XCTAssertEqual(b.sessions.count, 1)
        XCTAssertEqual(model.workspaces[1].sshConnections, [other])
        model.closeWorkspace(second.id)
        XCTAssertTrue(b.sessions.isEmpty)
        XCTAssertNil(model.ssh.existing(second.id))
    }

    @MainActor func testReconnectAndLateExitStayWithinOriginalSession() throws {
        let runtime = SSHWorkspaceRuntime()
        defer { runtime.dispose() }
        let value = connection()
        runtime.connect(value, directory: "/tmp")
        let first = try XCTUnwrap(runtime.selectedSession)
        runtime.connect(value, directory: "/tmp")
        XCTAssertEqual(runtime.sessions.count, 1)
        runtime.disconnect(first.id)
        runtime.connect(value, directory: "/tmp")
        let second = try XCTUnwrap(runtime.selectedSession)
        XCTAssertNotEqual(first.id, second.id)
        runtime.markEnded(first.id)
        XCTAssertFalse(try XCTUnwrap(runtime.selectedSession).ended)
        runtime.close(second.id)
        XCTAssertEqual(runtime.selectedSessionID, first.id)
    }

    @MainActor func testLegacyArchiveWithoutSSHConnectionsStillRestores() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = WorkspaceSession(directory: root), model = WindowModel()
        persistence.register(model); persistence.save()
        var archive = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: persistence.fileURL)) as? [String: Any])
        var windows = archive["windows"] as! [[String: Any]]
        var workspaces = windows[0]["workspaces"] as! [[String: Any]]
        workspaces[0].removeValue(forKey: "sshConnections")
        windows[0]["workspaces"] = workspaces; archive["windows"] = windows
        try JSONSerialization.data(withJSONObject: archive).write(to: persistence.fileURL)
        let restored = try XCTUnwrap(WorkspaceSession(directory: root).restore().first)
        XCTAssertTrue(try XCTUnwrap(restored.workspace).sshConnections.isEmpty)
    }
    @MainActor func testRealSSHFailureKeepsOutputAndRendersProjectPanel() throws {
        _ = NSApplication.shared
        // A local server closes the handshake: no external server or credentials.
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(socketFD, 0)
        defer { shutdown(socketFD, SHUT_RDWR); Darwin.close(socketFD) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socketFD, $0, length) }
        }
        XCTAssertEqual(bound, 0)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &length) }
        }
        XCTAssertEqual(named, 0)
        XCTAssertEqual(listen(socketFD, 1), 0)
        DispatchQueue.global().async {
            let client = accept(socketFD, nil, nil)
            if client >= 0 { Darwin.close(client) }
        }
        var value = connection(); value.port = Int(UInt16(bigEndian: address.sin_port))
        let model = WindowModel(workspaces: [Workspace(name: "SSH Test Project", directory: "/tmp")])
        let workspaceID = model.selectedWorkspaceID
        try model.saveSSHConnection(value, in: workspaceID)
        let workspace = try XCTUnwrap(model.workspace)
        let runtime = model.sshRuntime(for: workspaceID)
        runtime.connect(value, directory: "/tmp")
        let session = try XCTUnwrap(runtime.selectedSession)
        let sidebar = NSHostingView(rootView: CommandSidebar(model: model, library: .shared, workspace: workspace))
        let host = NSHostingView(rootView: TerminalArea(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { model.disposeAll(); window.orderOut(nil) }
        let originalPane = model.selectedTab?.focusedPane
        let deadline = Date().addingTimeInterval(10)
        while runtime.selectedSession?.ended != true && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.025))
        }
        XCTAssertTrue(try XCTUnwrap(runtime.selectedSession).ended)
        let surface = try XCTUnwrap(session.terminal.surface, "Failed SSH output should remain visible")
        var selection = ghostty_selection_s()
        selection.top_left.tag = GHOSTTY_POINT_SCREEN
        selection.top_left.coord = GHOSTTY_POINT_COORD_TOP_LEFT
        selection.bottom_right.tag = GHOSTTY_POINT_SCREEN
        selection.bottom_right.coord = GHOSTTY_POINT_COORD_BOTTOM_RIGHT
        var output = ghostty_text_s()
        XCTAssertTrue(ghostty_surface_read_text(surface, selection, &output))
        let text = output.text.map { String(cString: $0) } ?? ""
        ghostty_surface_free_text(surface, &output)
        XCTAssertTrue(text.lowercased().contains("connection") && (text.lowercased().contains("closed") || text.lowercased().contains("reset")), text)
        XCTAssertEqual(model.selectedTab?.focusedPane, originalPane)
        XCTAssertTrue(model.terminals.isEmpty)
        XCTAssertTrue(model.paneTabs.isEmpty)
        // The management sidebar must never attach an SSH surface.
        let sidebarWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        sidebarWindow.contentView = sidebar
        defer { sidebarWindow.orderOut(nil) }
        sidebar.layoutSubtreeIfNeeded()
        func containsTerminal(_ view: NSView) -> Bool {
            view is GhosttyTerminalView || view.subviews.contains { containsTerminal($0) }
        }
        XCTAssertFalse(containsTerminal(sidebar))
        XCTAssertTrue(session.terminal.window === window)
        XCTAssertGreaterThan(session.terminal.bounds.width, 800)
        let localTab = try XCTUnwrap(model.selectedTab?.id)
        model.selectTab(localTab)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertFalse(runtime.isPresented)
        runtime.select(session.id)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(session.terminal.surface, surface)
        XCTAssertTrue(model.focusedTerminal === session.terminal)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to:
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/ssh-panel.png"))
    }

    @MainActor func testOpeningSSHSelectsMainTerminalAndKeepsProjectSelectionSeparate() throws {
        let a = Workspace(name: "A", directory: "/tmp"), b = Workspace(name: "B", directory: "/tmp")
        let model = WindowModel(workspaces: [a, b])
        defer { model.disposeAll() }
        let value = connection()
        try model.saveSSHConnection(value, in: a.id)
        model.tools.content = .editor
        model.openSSHConnection(value, in: a.id)
        let runtime = model.sshRuntime(for: a.id)
        let session = try XCTUnwrap(runtime.presentedSession)
        XCTAssertEqual(model.tools.content, .terminal)
        XCTAssertTrue(model.focusedTerminal === session.terminal)
        model.selectTab(a.selectedTabID)
        XCTAssertNil(runtime.presentedSession)
        XCTAssertEqual(runtime.sessions.count, 1)
        model.openSSHConnection(value, in: a.id)
        XCTAssertEqual(runtime.sessions.count, 1)
        XCTAssertEqual(runtime.presentedSession?.id, session.id)
        model.selectWorkspace(b.id)
        XCTAssertNil(model.ssh.existing(b.id)?.presentedSession)
        XCTAssertFalse(model.focusedTerminal === session.terminal)
        model.selectWorkspace(a.id)
        XCTAssertTrue(model.focusedTerminal === session.terminal)
        model.addTab()
        XCTAssertNil(runtime.presentedSession)
        XCTAssertEqual(runtime.sessions.count, 1)
        runtime.select(session.id)
        XCTAssertTrue(model.closeFocusedSSHSession())
        XCTAssertTrue(runtime.sessions.isEmpty)
        XCTAssertEqual(model.workspace?.tabs.count, 2)
    }

}
