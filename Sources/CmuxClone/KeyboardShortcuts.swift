import AppKit
import SwiftUI

/// One source of truth for the menu, settings recorder, and window event routing.
enum AppCommand: String, CaseIterable, Identifiable, Codable {
    case settings, hide, quit, newWindow, newWorkspace, quickOpen, newTab, closePane, closeWindow
    case saveFile, undo, redo, cut, copy, paste, selectAll, find, findFile, findInFiles
    case splitRight, splitBelow, equalize, markdownPreview, increaseFont, decreaseFont, resetInterfaceZoom
    case sidebar, commands, fullScreen, minimize, zoom
    var id: String { rawValue }

    var title: String {
        switch self {
        case .settings: return L("设置…")
        case .hide: return L("隐藏 vsux")
        case .quit: return L("退出 vsux")
        case .newWindow: return L("新建窗口")
        case .newWorkspace: return L("新建工作区…")
        case .quickOpen: return L("快速打开文件…")
        case .newTab: return L("新建终端 Tab")
        case .closePane: return L("关闭当前分屏")
        case .closeWindow: return L("关闭窗口")
        case .saveFile: return L("保存")
        case .undo: return L("撤销")
        case .redo: return L("重做")
        case .cut: return L("剪切")
        case .copy: return L("复制")
        case .paste: return L("粘贴")
        case .selectAll: return L("全选")
        case .find: return L("查找当前内容…")
        case .findFile: return L("查找当前文件…")
        case .findInFiles: return L("在文件中搜索…")
        case .splitRight: return L("向右分屏")
        case .splitBelow: return L("向下分屏")
        case .equalize: return L("均分分屏")
        case .markdownPreview: return L("Markdown 侧边预览")
        case .increaseFont: return L("放大界面")
        case .decreaseFont: return L("缩小界面")
        case .resetInterfaceZoom: return L("重置界面缩放")
        case .sidebar: return L("显示 / 隐藏工作区")
        case .commands: return L("显示 / 隐藏常用命令")
        case .fullScreen: return L("进入全屏幕")
        case .minimize: return L("最小化")
        case .zoom: return L("缩放")
        }
    }

    var selector: Selector {
        switch self {
        case .settings: return #selector(AppDelegate.settings(_:))
        case .hide: return #selector(NSApplication.hide(_:))
        case .quit: return #selector(NSApplication.terminate(_:))
        case .newWindow: return #selector(AppDelegate.newWindow(_:))
        case .newWorkspace: return #selector(AppDelegate.newWorkspace(_:))
        case .quickOpen: return #selector(AppDelegate.quickOpen(_:))
        case .newTab: return #selector(AppDelegate.newTab(_:))
        case .closePane: return #selector(AppDelegate.closePane(_:))
        case .closeWindow: return #selector(NSWindow.performClose(_:))
        case .saveFile: return #selector(AppDelegate.saveFile(_:))
        case .undo: return Selector(("undo:"))
        case .redo: return Selector(("redo:"))
        case .cut: return #selector(NSText.cut(_:))
        case .copy: return #selector(NSText.copy(_:))
        case .paste: return #selector(NSText.paste(_:))
        case .selectAll: return #selector(NSText.selectAll(_:))
        case .find: return #selector(AppDelegate.find(_:))
        case .findFile: return #selector(AppDelegate.findFile(_:))
        case .findInFiles: return #selector(AppDelegate.findInFiles(_:))
        case .splitRight: return #selector(AppDelegate.splitRight(_:))
        case .splitBelow: return #selector(AppDelegate.splitBelow(_:))
        case .equalize: return #selector(AppDelegate.equalize(_:))
        case .markdownPreview: return #selector(AppDelegate.toggleMarkdownPreview(_:))
        case .increaseFont: return #selector(AppDelegate.increaseFontSize(_:))
        case .decreaseFont: return #selector(AppDelegate.decreaseFontSize(_:))
        case .resetInterfaceZoom: return #selector(AppDelegate.resetInterfaceZoom(_:))
        case .sidebar: return #selector(AppDelegate.sidebar(_:))
        case .commands: return #selector(AppDelegate.commands(_:))
        case .fullScreen: return #selector(NSWindow.toggleFullScreen(_:))
        case .minimize: return #selector(NSWindow.performMiniaturize(_:))
        case .zoom: return #selector(NSWindow.performZoom(_:))
        }
    }

    var defaultBinding: KeyBinding {
        switch self {
        case .settings: return KeyBinding(",", .command)
        case .hide: return KeyBinding("h", .command)
        case .quit: return KeyBinding("q", .command)
        case .newWindow: return KeyBinding("n", .command)
        case .newWorkspace: return KeyBinding("n", [.command, .shift])
        case .quickOpen: return KeyBinding("p", .control)
        case .newTab: return KeyBinding("t", .command)
        case .closePane: return KeyBinding("w", .command)
        case .closeWindow: return KeyBinding("w", [.command, .shift])
        case .saveFile: return KeyBinding("s", .command)
        case .undo: return KeyBinding("z", .command)
        case .redo: return KeyBinding("z", [.command, .shift])
        case .cut: return KeyBinding("x", .command)
        case .copy: return KeyBinding("c", .command)
        case .paste: return KeyBinding("v", .command)
        case .selectAll: return KeyBinding("a", .command)
        case .find: return KeyBinding("f", .command)
        case .findFile: return KeyBinding("f", .control)
        case .findInFiles: return KeyBinding("f", [.command, .shift])
        case .splitRight: return KeyBinding("d", .command)
        case .splitBelow: return KeyBinding("d", [.command, .shift])
        case .markdownPreview: return KeyBinding("v", [.command, .shift])
        case .increaseFont: return KeyBinding("+", .control)
        case .decreaseFont: return KeyBinding("-", .control)
        case .resetInterfaceZoom: return KeyBinding("0", .control)
        case .fullScreen: return KeyBinding("f", [.command, .control])
        case .minimize: return KeyBinding("m", .command)
        case .equalize, .sidebar, .commands, .zoom: return .disabled
        }
    }
}

struct KeyBinding: Codable, Equatable {
    static let supportedModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
    static let disabled = KeyBinding("", [])
    var key: String
    private var modifierBits: UInt
    var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifierBits) }
    var isDisabled: Bool { key.isEmpty }
    var isValid: Bool {
        isDisabled || (key.count == 1 && !modifiers.intersection([.command, .control, .option]).isEmpty &&
            modifierBits == modifiers.intersection(Self.supportedModifiers).rawValue)
    }

    init(_ key: String, _ modifiers: NSEvent.ModifierFlags) {
        self.key = key.lowercased()
        modifierBits = modifiers.intersection(Self.supportedModifiers).rawValue
    }
    init?(event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(Self.supportedModifiers)
        guard let key = event.charactersIgnoringModifiers, key.count == 1,
              !modifiers.intersection([.command, .control, .option]).isEmpty else { return nil }
        self.init(key, modifiers)
        // AppKit emits control characters for Control-=/- on some layouts.
        if event.keyCode == 24 { self.key = modifiers.contains(.shift) ? "+" : "=" }
        if event.keyCode == 27 { self.key = "-" }
    }
    // Preserve the existing Ctrl+=, Ctrl+Shift+= and keypad zoom aliases.
    private var canonical: KeyBinding {
        if (key == "+" || key == "=") && (modifiers == .control || modifiers == [.control, .shift]) {
            return KeyBinding("=", .control)
        }
        return self
    }
    func overlaps(_ other: KeyBinding) -> Bool { !isDisabled && !other.isDisabled && canonical == other.canonical }
    func matches(_ event: NSEvent) -> Bool {
        guard !isDisabled, event.type == .keyDown else { return false }
        if canonical == KeyBinding("=", .control),
           [24, 69].contains(event.keyCode),
           event.modifierFlags.intersection(Self.supportedModifiers) == .control || event.modifierFlags.intersection(Self.supportedModifiers) == [.control, .shift] { return true }
        if key == "-", modifiers == .control, [27, 78].contains(event.keyCode), event.modifierFlags.intersection(Self.supportedModifiers) == .control { return true }
        guard let input = KeyBinding(event: event) else { return false }
        return overlaps(input)
    }
    var display: String {
        guard !isDisabled else { return L("未设置") }
        var value = ""
        if modifiers.contains(.control) { value += "⌃" }
        if modifiers.contains(.option) { value += "⌥" }
        if modifiers.contains(.shift) { value += "⇧" }
        if modifiers.contains(.command) { value += "⌘" }
        let special: [String: String] = [" ": L("空格"), "\t": "⇥", "\r": "↩", "\u{7f}": "⌫", "\u{f700}": "↑", "\u{f701}": "↓", "\u{f702}": "←", "\u{f703}": "→"]
        return value + (special[key] ?? key.uppercased())
    }
}

extension Notification.Name {
    static let keyboardShortcutsDidChange = Notification.Name("vsux.keyboardShortcutsDidChange")
}

@MainActor
final class ShortcutPreferences: ObservableObject {
    static let shared = ShortcutPreferences()
    private let defaults: UserDefaults
    @Published private(set) var overrides: [String: KeyBinding] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "keyboardShortcuts"),
           let saved = try? JSONDecoder().decode([String: KeyBinding].self, from: data) {
            // Invalid/colliding archives fall back as a whole, so defaults and
            // overrides can never silently assign one combination twice.
            var known = saved.filter { AppCommand(rawValue: $0.key) != nil }
            if known[AppCommand.resetInterfaceZoom.rawValue] == nil,
               AppCommand.allCases.contains(where: {
                   $0 != .resetInterfaceZoom && (known[$0.rawValue] ?? $0.defaultBinding).overlaps(AppCommand.resetInterfaceZoom.defaultBinding)
               }) {
                known[AppCommand.resetInterfaceZoom.rawValue] = .disabled
            }
            // Existing users may already own Ctrl+F. Adding a command must not
            // invalidate their complete shortcut archive or steal that binding.
            if known[AppCommand.findFile.rawValue] == nil,
               AppCommand.allCases.contains(where: {
                   $0 != .findFile && (known[$0.rawValue] ?? $0.defaultBinding).overlaps(AppCommand.findFile.defaultBinding)
               }) {
                known[AppCommand.findFile.rawValue] = .disabled
            }
            if Self.isValid(known) { overrides = known }
        }
    }
    func binding(for command: AppCommand) -> KeyBinding { overrides[command.rawValue] ?? command.defaultBinding }
    func command(for event: NSEvent) -> AppCommand? { AppCommand.allCases.first { binding(for: $0).matches(event) } }
    func isRetiredEditingShortcut(_ event: NSEvent) -> Bool {
        [AppCommand.undo, .redo, .cut, .copy, .paste, .selectAll].contains {
            $0.defaultBinding.matches(event) && !binding(for: $0).overlaps($0.defaultBinding)
        }
    }
    func conflict(for binding: KeyBinding, excluding command: AppCommand) -> AppCommand? {
        AppCommand.allCases.first { $0 != command && self.binding(for: $0).overlaps(binding) }
    }
    /// Returns a user-facing error without changing the existing binding.
    @discardableResult
    func set(_ binding: KeyBinding, for command: AppCommand) -> String? {
        guard binding.isValid else { return L("请使用 Command、Control 或 Option 加一个按键。") }
        if let conflict = conflict(for: binding, excluding: command) { return L("此快捷键已用于“\(conflict.title)”，请先修改该操作。") }
        if binding == command.defaultBinding { overrides.removeValue(forKey: command.rawValue) }
        else { overrides[command.rawValue] = binding }
        save()
        return nil
    }
    func reset(_ command: AppCommand) -> String? { set(command.defaultBinding, for: command) }
    func resetAll() { overrides = [:]; save() }
    private func save() {
        if let data = try? JSONEncoder().encode(overrides) { defaults.set(data, forKey: "keyboardShortcuts") }
        NotificationCenter.default.post(name: .keyboardShortcutsDidChange, object: self)
    }
    private static func isValid(_ overrides: [String: KeyBinding]) -> Bool {
        let bindings = AppCommand.allCases.map { overrides[$0.rawValue] ?? $0.defaultBinding }
        for (index, binding) in bindings.enumerated() {
            if !binding.isValid || bindings.dropFirst(index + 1).contains(where: { $0.overlaps(binding) }) { return false }
        }
        return true
    }
}
