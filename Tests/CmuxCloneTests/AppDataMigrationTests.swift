import XCTest
@testable import CmuxClone

final class AppDataMigrationTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    @MainActor func testUpgradePreservesWorkspaceCommandAssociationAndLegacyFiles() throws {
        let support = try temporaryDirectory()
        let legacy = support.appendingPathComponent("CmuxLocal")
        let destination = support.appendingPathComponent("vsux")
        let session = WorkspaceSession(directory: legacy)
        let model = WindowModel(workspaces: [Workspace(name: "project", directory: support.path)])
        session.register(model)
        session.finish()
        let workspaceID = try XCTUnwrap(model.workspace?.id)
        let command = SavedCommand(name: "start", command: "npm run dev")
        XCTAssertTrue(CommandLibrary(directory: legacy).put(command, in: workspaceID))
        let backup = Data("original command backup".utf8)
        try backup.write(to: legacy.appendingPathComponent("commands-v1.backup.json"))
        let workspaceData = try Data(contentsOf: session.fileURL)
        let commandData = try Data(contentsOf: legacy.appendingPathComponent("commands.json"))

        try AppDataMigration.migrateDirectory(in: support)

        let restored = try XCTUnwrap(WorkspaceSession(directory: destination).restore().first)
        XCTAssertEqual(restored.workspace?.id, workspaceID)
        XCTAssertEqual(CommandLibrary(directory: destination).commands(in: workspaceID), [command])
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("workspaces.json")), workspaceData)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("commands.json")), commandData)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("commands-v1.backup.json")), backup)
        XCTAssertEqual(try Data(contentsOf: session.fileURL), workspaceData)
        XCTAssertEqual(try Data(contentsOf: legacy.appendingPathComponent("commands.json")), commandData)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: destination.appendingPathComponent("commands.json").path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: support.path).sorted(), ["CmuxLocal", "vsux"])
    }

    func testExistingVsuxDirectoryIsNeverMergedOrOverwritten() throws {
        let support = try temporaryDirectory()
        let legacy = support.appendingPathComponent("CmuxLocal")
        let destination = support.appendingPathComponent("vsux")
        for directory in [legacy, destination] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data("old commands".utf8).write(to: legacy.appendingPathComponent("commands.json"))
        try Data("old workspace IDs".utf8).write(to: legacy.appendingPathComponent("workspaces.json"))
        let current = Data("new workspace IDs".utf8)
        try current.write(to: destination.appendingPathComponent("workspaces.json"))
        for _ in 0..<2 { try AppDataMigration.migrateDirectory(in: support) }
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("workspaces.json")), current)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("commands.json").path))
    }

    func testFreshInstallDoesNotNeedLegacyData() throws {
        let support = try temporaryDirectory()
        try AppDataMigration.migrateDirectory(in: support)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: support.path), [])
    }

    func testInvalidDirectoryStopsMigrationWithoutPublishingAnEmptyStore() throws {
        let support = try temporaryDirectory()
        let legacy = support.appendingPathComponent("CmuxLocal")
        let destination = support.appendingPathComponent("vsux")
        let original = Data("not a directory".utf8)
        try original.write(to: legacy)
        XCTAssertThrowsError(try AppDataMigration.migrateDirectory(in: support))
        XCTAssertEqual(try Data(contentsOf: legacy), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        try FileManager.default.removeItem(at: legacy)
        try original.write(to: destination)
        XCTAssertThrowsError(try AppDataMigration.migrateDirectory(in: support))
        XCTAssertEqual(try Data(contentsOf: destination), original)
    }

    func testSymlinkDoesNotLeaveNewStorePointingToLegacyData() throws {
        let support = try temporaryDirectory()
        let elsewhere = support.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: support.appendingPathComponent("CmuxLocal"), withDestinationURL: elsewhere)
        XCTAssertThrowsError(try AppDataMigration.migrateDirectory(in: support))
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.appendingPathComponent("vsux").path))
    }

    func testPreferencesMigrateOnceWithoutReplacingNewSettingsOrRestoringRemovedKeys() throws {
        let legacyDomain = "vsux.migration.legacy." + UUID().uuidString
        let destinationDomain = "vsux.migration.current." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: destinationDomain))
        defer {
            defaults.removePersistentDomain(forName: legacyDomain)
            defaults.removePersistentDomain(forName: destinationDomain)
        }
        let terminal = try JSONEncoder().encode(TerminalSettings())
        let shortcuts = Data("shortcut archive".utf8)
        defaults.setPersistentDomain([
            "appLanguage": "en", "appAppearance": "dark",
            "terminalSettings": terminal, "keyboardShortcuts": shortcuts
        ], forName: legacyDomain)
        defaults.set("light", forKey: "appAppearance")
        AppDataMigration.migratePreferences(defaults: defaults, legacyDomain: legacyDomain, destinationDomain: destinationDomain)
        XCTAssertEqual(defaults.string(forKey: "appLanguage"), "en")
        XCTAssertEqual(defaults.string(forKey: "appAppearance"), "light")
        XCTAssertEqual(defaults.data(forKey: "terminalSettings"), terminal)
        XCTAssertEqual(defaults.data(forKey: "keyboardShortcuts"), shortcuts)
        XCTAssertEqual(defaults.persistentDomain(forName: legacyDomain)?["appAppearance"] as? String, "dark")

        defaults.removeObject(forKey: "keyboardShortcuts")
        defaults.set("zh", forKey: "appLanguage")
        AppDataMigration.migratePreferences(defaults: defaults, legacyDomain: legacyDomain, destinationDomain: destinationDomain)
        XCTAssertNil(defaults.object(forKey: "keyboardShortcuts"))
        XCTAssertEqual(defaults.string(forKey: "appLanguage"), "zh")
    }
}
