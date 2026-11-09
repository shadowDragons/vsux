import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class CommandLibrary: ObservableObject {
    static let shared = CommandLibrary()
    @Published private(set) var commandsByWorkspace: [UUID: [SavedCommand]] = [:]
    @Published var error: String?
    let fileURL: URL
    private var legacyData: Data?
    private var legacyCommands: [SavedCommand] = []
    private var loadError: String?

    init(directory: URL? = nil) {
        let directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CmuxLocal", isDirectory: true)
        fileURL = directory.appendingPathComponent("commands.json")
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            guard data.count <= 8_388_608 else { throw LibraryError.tooLarge }
            // A workspace store must never fall back to the portable import
            // format: doing so could discard other workspaces after corruption.
            if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], object["workspaces"] != nil {
                let archive = try WorkspaceCommandArchive.decode(data)
                commandsByWorkspace = Dictionary(uniqueKeysWithValues: archive.workspaces.map { ($0.workspaceID, $0.commands) })
            } else {
                legacyCommands = try CommandArchive.decode(data).commands
                legacyData = data
            }
        } catch {
            loadError = L("无法读取命令库，原文件已保留：\(error.localizedDescription)")
            self.error = loadError
        }
    }

    func commands(in workspaceID: UUID) -> [SavedCommand] { commandsByWorkspace[workspaceID] ?? [] }

    /// The old global library has no workspace association. Assign it once to
    /// the active restored workspace and retain an exact copy of the old file.
    @discardableResult
    func migrateLegacyCommands(to workspaceID: UUID) -> Bool {
        if let loadError { error = loadError; return false }
        guard let legacyData else { return true }
        do {
            let backup = fileURL.deletingLastPathComponent().appendingPathComponent("commands-v1.backup.json")
            if !FileManager.default.fileExists(atPath: backup.path) {
                try legacyData.write(to: backup, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            }
            var updated = commandsByWorkspace
            updated[workspaceID] = legacyCommands
            guard persist(updated) else { return false }
            self.legacyData = nil
            legacyCommands = []
            return true
        } catch {
            self.error = L("无法迁移命令库，原文件已保留：\(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func put(_ command: SavedCommand, in workspaceID: UUID) -> Bool {
        guard migrateLegacyCommands(to: workspaceID) else { return false }
        var updated = commandsByWorkspace
        var commands = commands(in: workspaceID)
        var command = command
        command.name = command.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = commands.firstIndex(where: { $0.id == command.id }) { commands[index] = command }
        else { commands.append(command) }
        updated[workspaceID] = commands
        return persist(updated)
    }

    @discardableResult
    func deleteCommand(_ id: UUID, in workspaceID: UUID) -> Bool {
        guard migrateLegacyCommands(to: workspaceID) else { return false }
        var updated = commandsByWorkspace
        updated[workspaceID] = commands(in: workspaceID).filter { $0.id != id }
        return persist(updated)
    }

    @discardableResult
    func importCommands(_ data: Data, into workspaceID: UUID) -> Bool {
        do {
            let incoming = try CommandArchive.decode(data)
            guard migrateLegacyCommands(to: workspaceID) else { return false }
            var updated = commandsByWorkspace
            updated[workspaceID] = incoming.merging(into: commands(in: workspaceID))
            return persist(updated)
        } catch { self.error = L("导入失败：\(error.localizedDescription)"); return false }
    }

    func exportCommands(in workspaceID: UUID) throws -> Data {
        if let loadError { throw NSError(domain: "CmuxLocal.CommandLibrary", code: 1, userInfo: [NSLocalizedDescriptionKey: loadError]) }
        return try encoder().encode(CommandArchive(commands: commands(in: workspaceID)))
    }

    func importFile(into workspaceID: UUID) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        panel.message = L("仅导入到当前工作区，保留已有命令；名称和正文都相同的命令会跳过。")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { importCommands(try Data(contentsOf: url), into: workspaceID) }
        catch { self.error = L("导入失败：\(error.localizedDescription)") }
    }

    func exportFile(from workspaceID: UUID, name: String) {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = L("\(name)-常用命令.json")
        panel.message = L("仅导出当前工作区的命令。")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try exportCommands(in: workspaceID).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { self.error = L("导出失败：\(error.localizedDescription)") }
    }

    private func persist(_ updated: [UUID: [SavedCommand]]) -> Bool {
        if let loadError { error = loadError; return false }
        do {
            let archive = WorkspaceCommandArchive(workspaces: updated.keys.sorted { $0.uuidString < $1.uuidString }.map {
                WorkspaceCommandArchive.Commands(workspaceID: $0, commands: updated[$0]!)
            })
            try archive.validate()
            let data = try encoder().encode(archive)
            guard data.count <= 8_388_608 else { throw LibraryError.tooLarge }
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            commandsByWorkspace = updated
            error = nil
            return true
        } catch { self.error = L("保存命令失败：\(error.localizedDescription)"); return false }
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
