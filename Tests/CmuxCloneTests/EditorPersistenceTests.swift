import Foundation
import AppKit
import XCTest
@testable import CmuxClone

@MainActor
final class EditorPersistenceTests: XCTestCase {
    private func fixture() throws -> (URL, URL, WorkspaceSession, WindowModel) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let project = directory.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        for name in ["one.txt", "two.txt", "three.md"] {
            try Data("disk: \(name)\n".utf8).write(to: project.appendingPathComponent(name))
        }
        let session = WorkspaceSession(directory: directory.appendingPathComponent("state"))
        let model = WindowModel(workspaces: [Workspace(name: "project", directory: project.path)])
        session.register(model)
        return (directory, project, session, model)
    }

    func testPreviewReplacementPinningSelectionRenameAndClosePersistImmediately() throws {
        let (directory, project, session, model) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = model.tools.files(try XCTUnwrap(model.workspace))
        let one = project.appendingPathComponent("one.txt"), two = project.appendingPathComponent("two.txt")
        let three = project.appendingPathComponent("three.md")
        files.open(one, preview: false)
        files.open(two)
        files.open(three) // Replaces only the clean preview.
        func reopen() throws -> FileWorkspaceModel {
            let window = try XCTUnwrap(WorkspaceSession(directory: session.fileURL.deletingLastPathComponent()).restore().first)
            return window.tools.files(try XCTUnwrap(window.workspace))
        }
        var restored = try reopen()
        XCTAssertEqual(restored.documents.map(\.url), [one, three])
        XCTAssertEqual(restored.documents.map(\.isPreview), [false, true])
        XCTAssertEqual(restored.selectedDocument?.url, three)
        let markdown = try XCTUnwrap(files.selectedDocument)
        markdown.isPreview = false // Direct UI pinning must trigger persistence.
        markdown.markdownPreview = true
        markdown.markdownPreviewOnly = true
        files.selectedDocumentID = files.documents.first?.id
        restored = try reopen()
        XCTAssertEqual(restored.selectedDocument?.url, one)
        XCTAssertEqual(restored.documents.map(\.isPreview), [false, false])
        XCTAssertTrue(restored.documents.last?.markdownPreview == true)
        XCTAssertTrue(restored.documents.last?.markdownPreviewOnly == true)
        try files.rename(FileTreeItem(url: one, isDirectory: false, isSymbolicLink: false), to: "renamed.txt")
        XCTAssertEqual(try reopen().selectedDocument?.url.lastPathComponent, "renamed.txt")
        XCTAssertTrue(files.close(markdown))
        XCTAssertEqual(try reopen().documents.map { $0.url.lastPathComponent }, ["renamed.txt"])
        XCTAssertTrue(files.close(try XCTUnwrap(files.selectedDocument)))
        XCTAssertTrue(try reopen().documents.isEmpty)
    }

    func testLegacyMarkdownSessionDefaultsToSplitPreview() throws {
        let (directory, project, _, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = Data(#"{"documents":[{"path":"three.md","isPreview":false,"markdownPreview":true}],"selectedPath":"three.md"}"#.utf8)
        let saved = try JSONDecoder().decode(FileWorkspaceSession.self, from: data)
        let files = FileWorkspaceModel(rootURL: project)
        files.restoreSession(saved)
        XCTAssertEqual(files.selectedDocument?.markdownPreview, true)
        XCTAssertEqual(files.selectedDocument?.markdownPreviewOnly, false)
    }

    func testInactiveWorkspaceFilesSurviveLazyRestoreAndSubsequentSaves() throws {
        let (directory, project, session, model) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstWorkspace = try XCTUnwrap(model.workspace)
        model.tools.files(firstWorkspace).open(project.appendingPathComponent("one.txt"), preview: false)
        let otherRoot = directory.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        let otherFile = otherRoot.appendingPathComponent("other.txt")
        try Data("other project".utf8).write(to: otherFile)
        model.addWorkspace(at: otherRoot)
        let secondWorkspace = try XCTUnwrap(model.workspace)
        model.tools.files(secondWorkspace).open(otherFile, preview: false)
        model.tools.content = .terminal
        let nextSession = WorkspaceSession(directory: session.fileURL.deletingLastPathComponent())
        let reopened = try XCTUnwrap(nextSession.restore().first)
        nextSession.register(reopened)
        // Do not instantiate either editor before another workspace change is saved.
        reopened.colorWorkspace(secondWorkspace.id, color: "purple")
        let restored = try XCTUnwrap(WorkspaceSession(directory: session.fileURL.deletingLastPathComponent()).restore().first)
        XCTAssertEqual(restored.selectedWorkspaceID, secondWorkspace.id)
        XCTAssertEqual(restored.tools.content, .terminal)
        XCTAssertEqual(restored.tools.files(firstWorkspace).documents.map(\.url), [project.appendingPathComponent("one.txt")])
        XCTAssertEqual(restored.tools.files(secondWorkspace).documents.map(\.url), [otherFile])
        XCTAssertTrue(restored.terminals.isEmpty)
    }

    func testMissingAndUnsafeFilesDoNotPreventOtherTabsOrTerminalsRestoring() throws {
        let (directory, project, session, model) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = try XCTUnwrap(model.workspace)
        let files = model.tools.files(workspace)
        let one = project.appendingPathComponent("one.txt"), two = project.appendingPathComponent("two.txt")
        let three = project.appendingPathComponent("three.md")
        for file in [one, two, three] { files.open(file, preview: false) }
        let expectedTerminals = model.workspaces
        try FileManager.default.removeItem(at: one)
        try FileManager.default.removeItem(at: two)
        let outside = directory.appendingPathComponent("outside.txt")
        try Data("outside workspace".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: two, withDestinationURL: outside)
        try Data("updated on disk".utf8).write(to: three)
        let restored = try XCTUnwrap(WorkspaceSession(directory: session.fileURL.deletingLastPathComponent()).restore().first)
        let recovered = restored.tools.files(try XCTUnwrap(restored.workspace))
        XCTAssertEqual(recovered.documents.map(\.url), [three])
        XCTAssertEqual(recovered.selectedDocument?.text, "updated on disk")
        XCTAssertNotNil(recovered.error)
        XCTAssertEqual(restored.workspaces, expectedTerminals)
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "outside workspace")
    }

    func testMovingWorkspaceEditorModelRebindsPersistenceToDestinationWindow() throws {
        let (directory, project, session, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = try XCTUnwrap(source.workspace)
        let files = source.tools.files(workspace)
        files.open(project.appendingPathComponent("one.txt"), preview: false)
        let destination = WindowModel(workspaces: [workspace])
        source.tools.transferFiles(for: workspace.id, to: destination.tools)
        source.workspaces = [Workspace(name: "replacement", directory: directory.path)]
        session.register(destination)
        let moved = destination.tools.files(workspace)
        XCTAssertTrue(moved === files)
        moved.open(project.appendingPathComponent("two.txt"), preview: false)
        let restored = WorkspaceSession(directory: session.fileURL.deletingLastPathComponent()).restore()
        let target = try XCTUnwrap(restored.first { $0.workspace?.id == workspace.id })
        XCTAssertEqual(target.tools.files(workspace).documents.map { $0.url.lastPathComponent }, ["one.txt", "two.txt"])
        XCTAssertTrue(source.tools.files(workspace).documents.isEmpty)
    }

    func testVersionTwoArchiveKeepsTerminalLayoutDuringEditorSessionUpgrade() throws {
        let (directory, _, session, model) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        model.addTab()
        session.save()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: session.fileURL)) as? [String: Any])
        json["version"] = 2
        var windows = try XCTUnwrap(json["windows"] as? [[String: Any]])
        for index in windows.indices {
            windows[index].removeValue(forKey: "sidebar")
            windows[index].removeValue(forKey: "content")
        }
        json["windows"] = windows
        try JSONSerialization.data(withJSONObject: json).write(to: session.fileURL)
        let updatedSession = WorkspaceSession(directory: session.fileURL.deletingLastPathComponent())
        let restored = try XCTUnwrap(updatedSession.restore().first)
        XCTAssertEqual(restored.workspaces, model.workspaces)
        XCTAssertEqual(restored.tools.content, .terminal)
        updatedSession.register(restored)
        restored.tools.content = .editor
        let upgraded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: session.fileURL)) as? [String: Any])
        XCTAssertEqual(upgraded["version"] as? Int, 3)
    }

    func testFileSessionRejectsTraversalAbsolutePathsAndDuplicateTabs() throws {
        for path in ["../outside.txt", "/tmp/outside.txt", "folder/../../outside.txt", "./one.txt", "folder//one.txt", "bad\0.txt"] {
            let state = FileWorkspaceSession(documents: [.init(path: path, isPreview: false, markdownPreview: false)], selectedPath: path)
            XCTAssertThrowsError(try state.validate())
        }
        let document = FileWorkspaceSession.Document(path: "one.txt", isPreview: false, markdownPreview: false)
        XCTAssertThrowsError(try FileWorkspaceSession(documents: [document, document], selectedPath: "one.txt").validate())
    }

    func testFreshNativeWindowDisplaysRestoredEditorAndBothFileTabs() async throws {
        _ = NSApplication.shared
        let (directory, project, session, model) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = try XCTUnwrap(model.workspace)
        let files = model.tools.files(workspace)
        files.open(project.appendingPathComponent("one.txt"), preview: false)
        files.open(project.appendingPathComponent("two.txt"), preview: false)
        files.selectedDocumentID = files.documents.first?.id
        model.tools.sidebar = .files; model.tools.content = .editor
        session.finish()
        model.disposeAll()
        let nextSession = WorkspaceSession(directory: session.fileURL.deletingLastPathComponent())
        let restored = try XCTUnwrap(nextSession.restore(shellCommand: "/bin/zsh -f").first)
        restored.showCommands = false
        nextSession.register(restored)
        let controller = TerminalWindowController(model: restored)
        let window = try XCTUnwrap(controller.window)
        window.orderFront(nil)
        defer { nextSession.finish(); restored.disposeAll(); window.orderOut(nil) }
        func editors(_ view: NSView) -> [NSTextView] {
            (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap { editors($0) }
        }
        let host = try XCTUnwrap(window.contentView)
        let deadline = Date().addingTimeInterval(5)
        while !editors(host).contains(where: { $0.string == "disk: one.txt\n" }) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(editors(host).contains { $0.string == "disk: one.txt\n" }, "A fresh native window must show the restored selected file")
        XCTAssertEqual(restored.tools.files(workspace).documents.map { $0.url.lastPathComponent }, ["one.txt", "two.txt"])
        XCTAssertTrue(restored.terminals.isEmpty, "Restoring the editor must not start a hidden terminal")
        XCTAssertNil(restored.error)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/editor-session-preview.png")
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output)
    }
}
