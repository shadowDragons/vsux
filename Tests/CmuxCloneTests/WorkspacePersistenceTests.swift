import Foundation
import XCTest
@testable import CmuxClone

final class WorkspacePersistenceTests: XCTestCase {
    @MainActor func testOpenFileTabsAndSelectedEditorSurviveRelaunch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let project = directory.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = project.appendingPathComponent("first.swift")
        let second = project.appendingPathComponent("说明.md")
        try Data("let value = 1\n".utf8).write(to: first)
        try Data("# 文件恢复\n".utf8).write(to: second)
        let session = WorkspaceSession(directory: directory.appendingPathComponent("state"))
        let model = WindowModel(workspaces: [Workspace(name: "project", directory: project.path)])
        session.register(model)
        let files = model.tools.files(try XCTUnwrap(model.workspace))
        files.open(first, preview: false)
        files.open(second, preview: false)
        files.documents.last?.markdownPreview = true
        files.selectedDocumentID = files.documents.first?.id
        model.tools.sidebar = .files
        model.tools.content = .editor
        // Changes must already be durable before a graceful quit.
        let automatic = try XCTUnwrap(WorkspaceSession(directory: directory.appendingPathComponent("state")).restore().first)
        XCTAssertEqual(automatic.tools.files(try XCTUnwrap(automatic.workspace)).documents.map(\.url), [first, second])
        session.finish()
        let restored = try XCTUnwrap(WorkspaceSession(directory: directory.appendingPathComponent("state")).restore().first)
        let restoredFiles = restored.tools.files(try XCTUnwrap(restored.workspace))
        XCTAssertEqual(restoredFiles.documents.map(\.url), [first, second])
        XCTAssertEqual(restoredFiles.selectedDocument?.url, first)
        XCTAssertTrue(restoredFiles.documents.last?.markdownPreview == true)
        XCTAssertEqual(restored.tools.content, .editor)
        XCTAssertEqual(restored.tools.sidebar, .files)
        XCTAssertEqual(restored.workspaces, model.workspaces, "Terminal layout must survive alongside editor tabs")
    }

    @MainActor func testMultipleRenamedTerminalsAndPaneTabsSurviveRelaunch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = WorkspaceSession(directory: directory)
        let model = WindowModel()
        session.register(model)
        let firstPane = try XCTUnwrap(model.selectedTab?.focusedPane)
        model.mutateTab { $0.title = "后端服务"; $0.customTitle = true; $0.isPinned = true }
        let local = PaneTerminalTab(id: UUID(), title: "数据库", customTitle: true)
        model.paneTabs[firstPane] = [PaneTerminalTab(id: firstPane, title: "后端", customTitle: true), local]
        model.paneSelection[firstPane] = local.id
        model.addTab()
        model.mutateTab { $0.title = "前端服务"; $0.customTitle = true }
        let secondPane = try XCTUnwrap(model.selectedTab?.focusedPane)
        let splitPane = UUID()
        model.mutateTab {
            $0.layout = $0.layout.splitting(secondPane, new: splitPane, axis: .vertical).equalized()
            $0.focusedPane = splitPane; $0.zoomedPane = splitPane
        }
        model.resize(try splitID(model.selectedTab!.layout), fraction: 0.64)

        // No explicit save or graceful quit: every user change must already be durable.
        let restored = try XCTUnwrap(WorkspaceSession(directory: directory).restore().first)
        XCTAssertEqual(restored.workspaces, model.workspaces)
        XCTAssertEqual(restored.localTabs(firstPane), model.localTabs(firstPane))
        XCTAssertEqual(restored.activeTerminalID(firstPane), local.id)
        XCTAssertTrue(restored.terminals.isEmpty, "Restoring metadata must not eagerly start shell processes")
        restored.updateTitle(pane: firstPane, title: "shell title")
        XCTAssertEqual(restored.workspace?.tabs.first?.title, "后端服务")
        XCTAssertEqual(restored.localTabs(firstPane).first?.title, "后端")
    }

    private func splitID(_ layout: PaneLayout) throws -> UUID {
        if case .split(let id, _, _, _, _) = layout { return id }
        throw NSError(domain: "WorkspacePersistenceTests", code: 1)
    }

    @MainActor func testNewWorkspaceAndSelectionAreSavedBeforeQuitAndRestoredOnRelaunch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = WorkspaceSession(directory: directory)
        let model = WindowModel()
        session.register(model)
        session.save()
        model.addWorkspace(at: URL(fileURLWithPath: "/tmp/zhige", isDirectory: true))
        let project = try XCTUnwrap(model.workspace)
        model.workspaces[model.workspaceIndex!].description = "本地开发"
        model.colorWorkspace(project.id, color: "purple")
        model.pinWorkspace(project.id)

        // No quit/save call here: adding and editing must already be durable.
        let reopened = try XCTUnwrap(WorkspaceSession(directory: directory).restore().first)
        XCTAssertEqual(reopened.workspaces.map(\.id), model.workspaces.map(\.id))
        XCTAssertEqual(reopened.workspace?.name, "zhige")
        XCTAssertEqual(reopened.workspace?.directory, "/tmp/zhige")
        XCTAssertEqual(reopened.workspace?.description, "本地开发")
        XCTAssertEqual(reopened.workspace?.color, "purple")
        XCTAssertEqual(reopened.workspace?.isPinned, true)
        XCTAssertEqual(reopened.selectedWorkspaceID, project.id)
        XCTAssertTrue(reopened.terminals.isEmpty)
        XCTAssertEqual(reopened.workspace?.tabs.count, 1)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: session.fileURL.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    @MainActor func testRenameReorderAndCloseDoNotResurrectOldWorkspaces() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = WorkspaceSession(directory: directory)
        let model = WindowModel()
        session.register(model)
        let home = try XCTUnwrap(model.workspace)
        model.addWorkspace(at: URL(fileURLWithPath: "/tmp/project-a"))
        let first = try XCTUnwrap(model.workspace)
        model.addWorkspace(at: URL(fileURLWithPath: "/tmp/project-b"))
        let second = try XCTUnwrap(model.workspace)
        model.workspaces[model.workspaceIndex!].name = "重命名项目"
        model.moveWorkspace(second.id, to: first.id)
        model.closeWorkspace(home.id)
        let restored = try XCTUnwrap(WorkspaceSession(directory: directory).restore().first)
        XCTAssertEqual(restored.workspaces.map(\.id), [second.id, first.id])
        XCTAssertEqual(restored.workspaces.first?.name, "重命名项目")
        XCTAssertEqual(restored.selectedWorkspaceID, second.id)
    }

    @MainActor func testWindowsSaveTogetherAndLastWindowSurvivesClose() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = WorkspaceSession(directory: directory)
        let first = WindowModel(workspaces: [Workspace(name: "first", directory: "/tmp/first")])
        let second = WindowModel(workspaces: [Workspace(name: "second", directory: "/tmp/second")])
        session.register(first); session.register(second)
        first.colorWorkspace(first.selectedWorkspaceID, color: "orange")
        var restored = WorkspaceSession(directory: directory).restore()
        XCTAssertEqual(restored.map { $0.workspace?.name }, ["first", "second"])
        XCTAssertEqual(restored.first?.workspace?.color, "orange")
        session.unregister(first)
        restored = WorkspaceSession(directory: directory).restore()
        XCTAssertEqual(restored.map { $0.workspace?.name }, ["second"])
        session.unregister(second)
        XCTAssertEqual(WorkspaceSession(directory: directory).restore().map { $0.workspace?.name }, ["second"])
    }

    @MainActor func testQuitPreservesAllWindowsAndIgnoresDisposalChanges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = WorkspaceSession(directory: directory)
        let first = WindowModel(), second = WindowModel()
        session.register(first); session.register(second)
        session.finish()
        let saved = try Data(contentsOf: session.fileURL)
        first.workspaces.removeAll()
        session.unregister(first)
        session.unregister(second)
        XCTAssertEqual(try Data(contentsOf: session.fileURL), saved)
        XCTAssertEqual(WorkspaceSession(directory: directory).restore().count, 2)
    }

    @MainActor func testTransientTerminalUpdatesDoNotWriteWorkspaceConfiguration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = WorkspaceSession(directory: directory)
        let model = WindowModel()
        session.register(model)
        model.addTab()
        session.save()
        let original = try Data(contentsOf: session.fileURL)
        let sentinel = Date(timeIntervalSince1970: 1000)
        try FileManager.default.setAttributes([.modificationDate: sentinel], ofItemAtPath: session.fileURL.path)
        model.mutateTab { $0.title = "transient shell title" }
        let pane = try XCTUnwrap(model.selectedTab?.focusedPane)
        model.updateTitle(pane: pane, title: "another automatic title")
        XCTAssertEqual(try Data(contentsOf: session.fileURL), original)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: session.fileURL.path)[.modificationDate] as? Date, sentinel)
    }

    @MainActor func testLegacyWorkspaceArchiveMigratesWithoutLosingIDsOrMetadata() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = WorkspaceSession(directory: directory)
        let id = UUID()
        let legacy = """
        {"version":1,"windows":[{"selectedWorkspaceID":"\(id)","workspaces":[
          {"id":"\(id)","name":"zhige","description":"existing project","directory":"/tmp/zhige","color":"purple","isPinned":true}
        ]}]}
        """
        try Data(legacy.utf8).write(to: session.fileURL)
        let model = try XCTUnwrap(session.restore().first)
        XCTAssertEqual(model.workspace?.id, id)
        XCTAssertEqual(model.workspace?.description, "existing project")
        XCTAssertEqual(model.workspace?.tabs.count, 1)
        session.register(model)
        model.addTab()
        let restored = try XCTUnwrap(WorkspaceSession(directory: directory).restore().first)
        XCTAssertEqual(restored.workspaces, model.workspaces)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: session.fileURL)) as? [String: Any])
        XCTAssertEqual(json["version"] as? Int, 3)
        XCTAssertNil(model.error)
    }

    @MainActor func testPaneOnlyEditsAndClosingTabsAreDurableAndIsolatedByWorkspace() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = WorkspaceSession(directory: directory)
        let model = WindowModel()
        session.register(model)
        let first = model.selectedWorkspaceID
        let pane = try XCTUnwrap(model.selectedTab?.focusedPane)
        let second = PaneTerminalTab(id: UUID(), title: "后端", customTitle: true)
        model.paneTabs[pane] = [second, PaneTerminalTab(id: pane, title: "前端", customTitle: true)]
        model.selectLocalTab(second.id, pane: pane)
        var restored = try XCTUnwrap(WorkspaceSession(directory: directory).restore().first)
        XCTAssertEqual(restored.localTabs(pane), model.localTabs(pane))
        XCTAssertEqual(restored.activeTerminalID(pane), second.id)
        model.reorderLocalTab(pane, pane: pane, target: second.id)
        model.closeLocalTab(second.id, pane: pane)
        model.addTab()
        let toClose = try XCTUnwrap(model.selectedTab?.id)
        model.addTab()
        model.closeTab(toClose)
        model.addWorkspace(at: URL(fileURLWithPath: "/tmp/other-project"))
        model.mutateTab { $0.title = "其他项目"; $0.customTitle = true }
        model.selectWorkspace(first)
        session.finish()
        let beforeDisposal = try Data(contentsOf: session.fileURL)
        model.disposeAll()
        XCTAssertEqual(try Data(contentsOf: session.fileURL), beforeDisposal)
        restored = try XCTUnwrap(WorkspaceSession(directory: directory).restore().first)
        XCTAssertEqual(restored.workspaces, model.workspaces)
        XCTAssertEqual(restored.localTabs(pane), [PaneTerminalTab(id: pane, title: "前端", customTitle: true)])
        XCTAssertFalse(restored.workspace!.tabs.contains { $0.id == toClose })
        XCTAssertEqual(restored.workspaces.last?.tabs.first?.title, "其他项目")
        XCTAssertNil(model.error)
    }

    @MainActor func testRestoredTerminalUsesItsOwnDirectoryAndFallsBackIfDirectoryWasRemoved() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = directory.appendingPathComponent("project")
        let child = project.appendingPathComponent("backend")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = WorkspaceSession(directory: directory)
        let model = WindowModel(workspaces: [Workspace(name: "Project", directory: project.path)])
        session.register(model)
        let pane = try XCTUnwrap(model.selectedTab?.focusedPane)
        // Ghostty's PWD callback uses this same update path.
        model.updateDirectory(terminalID: pane, directory: child.path)
        let restored = try XCTUnwrap(WorkspaceSession(directory: directory).restore().first)
        XCTAssertEqual(restored.terminalDirectories[pane], child.path)
        restored.addWorkspace(at: directory)
        XCTAssertEqual(restored.terminal(pane).directory, child.path, "An inactive workspace must use its own saved directory")
        restored.disposeAll()
        try FileManager.default.removeItem(at: child)
        let reopened = try XCTUnwrap(WorkspaceSession(directory: directory).restore().first)
        XCTAssertEqual(reopened.startingDirectory(for: pane), project.path)
        try FileManager.default.removeItem(at: project)
        XCTAssertEqual(reopened.startingDirectory(for: pane), NSHomeDirectory())
    }

    @MainActor func testMergeAndExtractPreserveTerminalIdentityAndCustomNames() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = WorkspaceSession(directory: directory)
        let model = WindowModel()
        session.register(model)
        let firstTab = try XCTUnwrap(model.selectedTab?.id)
        let pane = try XCTUnwrap(model.selectedTab?.focusedPane)
        let extra = PaneTerminalTab(id: UUID(), title: "数据库日志", customTitle: true)
        model.paneTabs[pane] = [PaneTerminalTab(id: pane), extra]
        model.addTab()
        let other = try XCTUnwrap(model.selectedTab?.id)
        model.selectTab(firstTab)
        model.mergeTab(other)
        XCTAssertNil(model.error, "An intermediate duplicate pane must not trigger a save error")
        XCTAssertEqual(model.selectedTab?.layout.leaves.count, 2)
        model.extractLocalTab(extra.id, pane: pane)
        let newPane = try XCTUnwrap(model.selectedTab?.focusedPane)
        XCTAssertEqual(model.localTabs(newPane), [extra])
        let restored = try XCTUnwrap(WorkspaceSession(directory: directory).restore().first)
        XCTAssertEqual(restored.workspaces, model.workspaces)
        XCTAssertEqual(restored.localTabs(newPane), [extra])
        XCTAssertEqual(restored.activeTerminalID(newPane), extra.id)
        XCTAssertNil(model.error)
    }

    @MainActor func testInvalidTerminalSelectionIsPreservedAndReportedWithoutOverwritingArchive() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let originalSession = WorkspaceSession(directory: directory)
        let originalModel = WindowModel()
        originalSession.register(originalModel); originalSession.save()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: originalSession.fileURL)) as? [String: Any])
        var windows = try XCTUnwrap(json["windows"] as? [[String: Any]])
        var workspaces = try XCTUnwrap(windows[0]["workspaces"] as? [[String: Any]])
        var panes = try XCTUnwrap(workspaces[0]["panes"] as? [[String: Any]])
        panes[0]["selectedTerminalID"] = UUID().uuidString
        workspaces[0]["panes"] = panes; windows[0]["workspaces"] = workspaces; json["windows"] = windows
        let damaged = try JSONSerialization.data(withJSONObject: json)
        try damaged.write(to: originalSession.fileURL)
        let session = WorkspaceSession(directory: directory)
        XCTAssertTrue(session.restore().isEmpty)
        let model = WindowModel()
        session.register(model); model.addTab()
        XCTAssertNotNil(model.error)
        XCTAssertEqual(try Data(contentsOf: session.fileURL), damaged)
    }

    @MainActor func testUnreadableOrFutureArchivesArePreservedAndReported() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for contents in ["invalid JSON", "{\"version\":99,\"windows\":[]}"] {
            let session = WorkspaceSession(directory: directory)
            let original = Data(contents.utf8)
            try original.write(to: session.fileURL)
            XCTAssertTrue(session.restore().isEmpty)
            let model = WindowModel()
            session.register(model)
            model.addWorkspace(at: URL(fileURLWithPath: "/tmp/should-not-overwrite"))
            XCTAssertNotNil(model.error)
            XCTAssertEqual(try Data(contentsOf: session.fileURL), original)
        }
    }

    @MainActor func testSaveFailureIsVisibleToUser() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("file instead of directory".utf8).write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = WorkspaceSession(directory: root)
        let model = WindowModel()
        session.register(model)
        model.addWorkspace(at: URL(fileURLWithPath: "/tmp/project"))
        XCTAssertTrue(model.error?.hasPrefix("无法保存工作区") == true)
    }
}
