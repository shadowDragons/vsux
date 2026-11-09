import XCTest
@testable import CmuxClone

final class CommandLibraryTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func legacyData(_ commands: [SavedCommand]) throws -> Data {
        struct Category: Codable { var name: String; var commands: [SavedCommand]; var isExpanded = false }
        struct Archive: Codable { var version = 1; var categories: [Category] }
        return try JSONEncoder().encode(Archive(categories: [
            Category(name: "开发", commands: Array(commands.prefix(1))),
            Category(name: "系统维护", commands: Array(commands.dropFirst()))
        ]))
    }

    func testPortableArchiveRoundtripAndMergePreserveExistingIDs() throws {
        let command = SavedCommand(name: "目录", command: "pwd")
        let incoming = CommandArchive(commands: [command, commandWithNewID(command), SavedCommand(name: "文件", command: "ls")])
        let decoded = try CommandArchive.decode(JSONEncoder().encode(incoming))
        let merged = decoded.merging(into: [command])
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0], command)
        XCTAssertNotEqual(merged[1].id, incoming.commands[2].id)
        XCTAssertEqual(merged[1].command, "ls")
    }

    func testLegacyGroupedImportsFlattenInOrderIncludingCollapsedGroups() throws {
        let commands = [SavedCommand(name: "目录", command: "pwd"), SavedCommand(name: "多行", command: "echo 中文\npwd")]
        let data = try legacyData(commands)
        XCTAssertEqual(try CommandArchive.decode(data).commands, commands)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let categories = try XCTUnwrap(object["categories"])
        XCTAssertEqual(try CommandArchive.decode(JSONSerialization.data(withJSONObject: categories)).commands, commands)
    }

    func testRejectMalformedArchivesAndFutureVersions() throws {
        XCTAssertThrowsError(try CommandArchive.decode(Data("garbage".utf8)))
        XCTAssertThrowsError(try CommandArchive.decode(JSONEncoder().encode(CommandArchive(version: 99, commands: []))))
        XCTAssertThrowsError(try CommandArchive.decode(JSONEncoder().encode(CommandArchive(commands: [SavedCommand(name: " ", command: "pwd")]))))
        XCTAssertThrowsError(try CommandArchive.decode(JSONEncoder().encode(CommandArchive(commands: [SavedCommand(name: "空白", command: "\n ")]))))
        let command = SavedCommand(name: "目录", command: "pwd")
        XCTAssertThrowsError(try CommandArchive.decode(JSONEncoder().encode(CommandArchive(commands: [command, command]))))
        XCTAssertThrowsError(try CommandArchive.decode(Data(repeating: 0, count: 8_388_609)))
    }

    @MainActor func testWorkspacesPersistIndependentEditsDeletionAndEmptyLists() throws {
        let root = try temporaryDirectory()
        let library = CommandLibrary(directory: root)
        let a = UUID(), b = UUID(), empty = UUID()
        var command = SavedCommand(name: "多行", command: "printf '中文'\npwd")
        let second = SavedCommand(name: "文件", command: "ls -la")
        XCTAssertTrue(library.commands(in: a).isEmpty)
        XCTAssertTrue(library.put(command, in: a))
        XCTAssertTrue(library.put(second, in: a))
        XCTAssertTrue(library.put(command, in: b)) // Even shared command IDs cannot cross workspace boundaries.
        command.name = "已编辑"
        XCTAssertTrue(library.put(command, in: a))
        let reloaded = CommandLibrary(directory: root)
        XCTAssertEqual(reloaded.commands(in: a), [command, second], "编辑不能把命令移到列表末尾")
        XCTAssertEqual(reloaded.commands(in: b).first?.name, "多行")
        XCTAssertTrue(reloaded.commands(in: empty).isEmpty)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: library.fileURL.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertTrue(reloaded.deleteCommand(command.id, in: a))
        XCTAssertTrue(reloaded.deleteCommand(second.id, in: a))
        let reopened = CommandLibrary(directory: root)
        XCTAssertTrue(reopened.commands(in: a).isEmpty)
        XCTAssertEqual(reopened.commands(in: b).count, 1)
        XCTAssertNil(reopened.error)
    }

    @MainActor func testImportAndExportOnlyAffectTheChosenWorkspace() throws {
        let root = try temporaryDirectory()
        let library = CommandLibrary(directory: root)
        let a = UUID(), b = UUID()
        let command = SavedCommand(name: "目录", command: "pwd")
        let other = SavedCommand(name: "另一个工作区", command: "echo other")
        XCTAssertTrue(library.put(command, in: a))
        XCTAssertTrue(library.put(other, in: b))
        let incoming = try legacyData([command, SavedCommand(name: "文件", command: "ls")])
        XCTAssertTrue(library.importCommands(incoming, into: a))
        XCTAssertTrue(library.importCommands(incoming, into: a))
        XCTAssertEqual(library.commands(in: a).count, 2)
        XCTAssertEqual(library.commands(in: a).first?.id, command.id)
        XCTAssertEqual(library.commands(in: b), [other])
        let exported = try library.exportCommands(in: a)
        XCTAssertEqual(try CommandArchive.decode(exported).commands, library.commands(in: a))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: exported) as? [String: Any])
        XCTAssertNil(object["categories"])
        XCTAssertNil(object["workspaces"])
        XCTAssertEqual(object["version"] as? Int, 2)
    }

    @MainActor func testLegacyMigrationIsBackedUpAndAssignedOnlyOnce() throws {
        let root = try temporaryDirectory()
        let commands = [SavedCommand(name: "目录", command: "pwd"), SavedCommand(name: "多行", command: "echo 中文\npwd")]
        let original = try legacyData(commands)
        let file = root.appendingPathComponent("commands.json")
        try original.write(to: file)
        let library = CommandLibrary(directory: root)
        let a = UUID(), b = UUID()
        XCTAssertTrue(library.migrateLegacyCommands(to: a))
        XCTAssertTrue(library.migrateLegacyCommands(to: b))
        XCTAssertEqual(library.commands(in: a), commands)
        XCTAssertTrue(library.commands(in: b).isEmpty)
        let backup = root.appendingPathComponent("commands-v1.backup.json")
        XCTAssertEqual(try Data(contentsOf: backup), original)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let reloaded = CommandLibrary(directory: root)
        XCTAssertTrue(reloaded.migrateLegacyCommands(to: b))
        XCTAssertEqual(reloaded.commands(in: a), commands)
        XCTAssertTrue(reloaded.commands(in: b).isEmpty)
        XCTAssertEqual(try WorkspaceCommandArchive.decode(Data(contentsOf: file)).workspaces.count, 1)
    }

    @MainActor func testUnreadableFutureAndCorruptStoresAreNotOverwritten() throws {
        let root = try temporaryDirectory()
        let file = root.appendingPathComponent("commands.json")
        for value in ["garbage", "{\"version\":99,\"workspaces\":[]}", "{\"version\":2,\"workspaces\":null,\"commands\":[]}"] {
            let original = Data(value.utf8)
            try original.write(to: file)
            let library = CommandLibrary(directory: root)
            XCTAssertNotNil(library.error)
            XCTAssertFalse(library.put(SavedCommand(name: "目录", command: "pwd"), in: UUID()))
            XCTAssertEqual(try Data(contentsOf: file), original)
        }
    }

    @MainActor func testFailedSaveDoesNotPublishUnsavedCommands() throws {
        let root = try temporaryDirectory().appendingPathComponent("not-a-directory")
        try Data("file".utf8).write(to: root)
        let library = CommandLibrary(directory: root)
        let workspace = UUID()
        XCTAssertFalse(library.put(SavedCommand(name: "目录", command: "pwd"), in: workspace))
        XCTAssertTrue(library.commands(in: workspace).isEmpty)
        XCTAssertNotNil(library.error)
    }

    @MainActor func testWorkspaceRenameAndSessionRestoreKeepCommandAssociation() throws {
        let root = try temporaryDirectory()
        let session = WorkspaceSession(directory: root)
        let first = Workspace(name: "同名项目", directory: "/tmp/shared")
        let second = Workspace(name: "同名项目", directory: "/tmp/shared")
        let model = WindowModel(workspaces: [first, second])
        session.register(model)
        let library = CommandLibrary(directory: root)
        let command = SavedCommand(name: "项目命令", command: "pwd")
        XCTAssertTrue(library.put(command, in: first.id))
        model.workspaces[0].name = "已重命名"
        model.selectWorkspace(second.id)
        let restored = try XCTUnwrap(WorkspaceSession(directory: root).restore().first)
        XCTAssertEqual(restored.workspace?.id, second.id)
        let reloaded = CommandLibrary(directory: root)
        XCTAssertTrue(reloaded.commands(in: restored.selectedWorkspaceID).isEmpty)
        restored.selectWorkspace(first.id)
        XCTAssertEqual(restored.workspace?.name, "已重命名")
        XCTAssertEqual(reloaded.commands(in: restored.selectedWorkspaceID), [command])
    }

    private func commandWithNewID(_ value: SavedCommand) -> SavedCommand {
        SavedCommand(name: value.name, command: value.command)
    }
}
