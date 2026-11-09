import Foundation

struct SavedCommand: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var command: String
}

/// A workspace-owned background process definition. Runtime process state is kept
/// by WindowModel and is intentionally not persisted with the workspace.
struct WorkspaceService: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var command: String
    var workingDirectory: String?

    func directory(in workspaceDirectory: String) -> URL {
        let path = (workingDirectory ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let root = URL(fileURLWithPath: workspaceDirectory, isDirectory: true)
        guard !path.isEmpty else { return root.standardizedFileURL }
        let expanded = (path as NSString).expandingTildeInPath
        return ((expanded as NSString).isAbsolutePath
            ? URL(fileURLWithPath: expanded, isDirectory: true)
            : root.appendingPathComponent(expanded, isDirectory: true)).standardizedFileURL
    }
}

enum ServiceStatus: String, Equatable {
    case stopped
    case starting
    case running
    case stopping
    case failed

    var title: String {
        switch self {
        case .stopped: return L("已停止")
        case .starting: return L("启动中")
        case .running: return L("运行中")
        case .stopping: return L("停止中")
        case .failed: return L("异常退出")
        }
    }
}

struct CommandArchive: Codable {
    var version = 2
    var commands: [SavedCommand]

    static func decode(_ data: Data) throws -> CommandArchive {
        guard data.count <= 8_388_608 else { throw LibraryError.tooLarge }
        let decoder = JSONDecoder()
        if let header = try? decoder.decode(ArchiveVersion.self, from: data) {
            switch header.version {
            case 2:
                let archive = try decoder.decode(CommandArchive.self, from: data)
                try validate(archive.commands)
                return archive
            case 1:
                return try flatten(decoder.decode(LegacyArchive.self, from: data).categories)
            default: throw LibraryError.version
            }
        }
        return try flatten(decoder.decode([LegacyCategory].self, from: data))
    }

    static func validate(_ commands: [SavedCommand]) throws {
        guard commands.count <= 100_000,
              Set(commands.map(\.id)).count == commands.count,
              commands.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw LibraryError.invalid }
    }

    private static func flatten(_ categories: [LegacyCategory]) throws -> CommandArchive {
        guard categories.count <= 500, categories.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.commands.count <= 2000 }) else { throw LibraryError.invalid }
        // Keep the original order and content, including commands in collapsed groups.
        // Legacy imports could contain repeated IDs; give those entries new IDs.
        var seen = Set<UUID>()
        let commands = categories.flatMap(\.commands).map { command in
            var command = command
            if !seen.insert(command.id).inserted { command.id = UUID(); seen.insert(command.id) }
            return command
        }
        let archive = CommandArchive(commands: commands)
        try validate(commands)
        return archive
    }

    func merging(into existing: [SavedCommand]) -> [SavedCommand] {
        var result = existing
        var contents = Set(existing.map { [$0.name, $0.command] })
        for command in commands where contents.insert([command.name, command.command]).inserted {
            result.append(SavedCommand(name: command.name, command: command.command))
        }
        return result
    }

    private struct ArchiveVersion: Decodable { var version: Int }
    private struct LegacyArchive: Decodable { var categories: [LegacyCategory] }
    private struct LegacyCategory: Decodable { var name: String; var commands: [SavedCommand] }
}

struct WorkspaceCommandArchive: Codable {
    var version = 2
    var workspaces: [Commands]

    struct Commands: Codable {
        var workspaceID: UUID
        var commands: [SavedCommand]
    }

    static func decode(_ data: Data) throws -> WorkspaceCommandArchive {
        guard data.count <= 8_388_608 else { throw LibraryError.tooLarge }
        let archive = try JSONDecoder().decode(Self.self, from: data)
        try archive.validate()
        return archive
    }

    func validate() throws {
        guard version == 2 else { throw LibraryError.version }
        guard workspaces.count <= 10_000,
              Set(workspaces.map(\.workspaceID)).count == workspaces.count else { throw LibraryError.invalid }
        for workspace in workspaces { try CommandArchive.validate(workspace.commands) }
    }
}

enum LibraryError: LocalizedError {
    case tooLarge, version, invalid
    var errorDescription: String? {
        switch self {
        case .tooLarge: return L("命令库文件超过 8 MB。")
        case .version: return L("不支持此命令库版本。")
        case .invalid: return L("命令库格式不正确：名称和内容不能为空，标识不能重复。")
        }
    }
}

enum SplitAxis: String, Codable { case horizontal, vertical }
indirect enum PaneLayout: Equatable, Codable {
    case leaf(UUID)
    case split(id: UUID, axis: SplitAxis, fraction: Double, first: PaneLayout, second: PaneLayout)

    var leaves: [UUID] {
        switch self {
        case .leaf(let id): return [id]
        case .split(_, _, _, let first, let second): return first.leaves + second.leaves
        }
    }
    func splitting(_ leaf: UUID, new: UUID, axis: SplitAxis, before: Bool = false) -> PaneLayout {
        switch self {
        case .leaf(let id):
            guard id == leaf else { return self }
            return .split(id: UUID(), axis: axis, fraction: 0.5, first: .leaf(before ? new : id), second: .leaf(before ? id : new))
        case .split(let id, let direction, let fraction, let first, let second):
            return .split(id: id, axis: direction, fraction: fraction, first: first.splitting(leaf, new: new, axis: axis, before: before), second: second.splitting(leaf, new: new, axis: axis, before: before))
        }
    }
    func removing(_ leaf: UUID) -> PaneLayout? {
        switch self {
        case .leaf(let id): return id == leaf ? nil : self
        case .split(let id, let axis, let fraction, let first, let second):
            let a = first.removing(leaf), b = second.removing(leaf)
            if let a, let b { return .split(id: id, axis: axis, fraction: fraction, first: a, second: b) }
            return a ?? b
        }
    }
    func resized(_ splitID: UUID, fraction: Double) -> PaneLayout {
        switch self {
        case .leaf: return self
        case .split(let id, let axis, let current, let first, let second):
            return .split(id: id, axis: axis, fraction: id == splitID ? min(0.85, max(0.15, fraction)) : current, first: first.resized(splitID, fraction: fraction), second: second.resized(splitID, fraction: fraction))
        }
    }
    func equalized() -> PaneLayout {
        switch self {
        case .leaf: return self
        case .split(let id, let axis, _, let first, let second):
            return .split(id: id, axis: axis, fraction: 0.5, first: first.equalized(), second: second.equalized())
        }
    }
}

struct TerminalTab: Identifiable, Equatable, Codable {
    var displayTitle: String { !customTitle && title == "终端" ? L("终端") : title }
    let id: UUID
    var title: String
    var customTitle = false
    var isPinned = false
    var layout: PaneLayout
    var focusedPane: UUID
    var zoomedPane: UUID?

    init(title: String = "终端", pane: UUID = UUID()) {
        id = UUID(); self.title = title; layout = .leaf(pane); focusedPane = pane
    }
}

struct Workspace: Identifiable, Equatable {
    var id = UUID()
    var name: String
    var description = ""
    var color = "blue"
    var isPinned = false
    var directory: String
    var services: [WorkspaceService] = []
    var tabs: [TerminalTab]
    var selectedTabID: UUID

    init(name: String, directory: String) {
        self.name = name; self.directory = directory
        let tab = TerminalTab(); tabs = [tab]; selectedTabID = tab.id
    }
}

struct TerminalSettings: Codable, Equatable {
    var fontName = "Menlo"
    var fontSize = 14.0
    var theme = "light"
    var cursor = "block"
    var cursorBlink = true
    var optionAsAlt = false
    var padding = 12
    var opacity = 1.0
    var blur = false
    var scrollbackMB = 16

    var ghosttyConfig: String {
        let dark = theme == "dark"
        let paper = theme == "paper"
        let background = dark ? "1e2022" : (paper ? "f8f6f0" : "ffffff")
        let foreground = dark ? "d8dadd" : "25282c"
        let safeFont = fontName.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        let safeCursor = ["block", "bar", "underline"].contains(cursor) ? cursor : "block"
        return """
        font-family = \(safeFont)
        font-size = \(min(40, max(9, fontSize)))
        background = \(background)
        foreground = \(foreground)
        cursor-color = \(dark ? "d8dadd" : "363b41")
        cursor-style = \(safeCursor)
        cursor-style-blink = \(cursorBlink)
        background-opacity = \(min(1, max(0.5, opacity)))
        window-padding-x = \(min(40, max(0, padding)))
        window-padding-y = \(min(40, max(0, padding)))
        macos-option-as-alt = \(optionAsAlt)
        scrollback-limit = \(min(128, max(1, scrollbackMB)) * 1024 * 1024)
        shell-integration = none
        clipboard-read = ask
        clipboard-write = allow
        confirm-close-surface = true
        keybind = clear
        keybind = super+c=copy_to_clipboard
        keybind = super+v=paste_from_clipboard
        keybind = super+a=select_all
        keybind = super+equal=increase_font_size:1
        keybind = super+minus=decrease_font_size:1
        keybind = super+zero=reset_font_size
        keybind = super+k=clear_screen
        """
    }
}

// Keep multi-line snippets pending even when a shell disables bracketed paste.
// POSIX single quoting keeps embedded newlines inside one eval argument.
func commandForInsertion(_ command: String) -> String {
    let normalized = command.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").trimmingCharacters(in: .newlines)
    guard normalized.contains("\n") else { return normalized }
    return "eval '" + normalized.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
}

struct PaneTerminalTab: Identifiable, Equatable, Codable {
    var displayTitle: String { !customTitle && title == "终端" ? L("终端") : title }
    var id: UUID
    var title = "终端"
    var customTitle = false
}
