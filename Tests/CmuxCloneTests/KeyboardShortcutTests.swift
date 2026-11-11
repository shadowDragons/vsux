import AppKit
import SwiftUI
import XCTest
@testable import CmuxClone

@MainActor
final class KeyboardShortcutTests: XCTestCase {
    func testOverridesPersistClearAndResetWithoutChangingOtherCommands() throws {
        let suite = "vsux.Shortcuts.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ShortcutPreferences(defaults: defaults)
        let custom = KeyBinding("p", [.command, .shift])
        XCTAssertNil(settings.set(custom, for: .quickOpen))
        XCTAssertEqual(ShortcutPreferences(defaults: defaults).binding(for: .quickOpen), custom)
        XCTAssertEqual(settings.binding(for: .newTab), AppCommand.newTab.defaultBinding)
        XCTAssertNil(settings.set(.disabled, for: .quickOpen))
        XCTAssertTrue(ShortcutPreferences(defaults: defaults).binding(for: .quickOpen).isDisabled)
        XCTAssertNil(settings.reset(.quickOpen))
        XCTAssertEqual(ShortcutPreferences(defaults: defaults).binding(for: .quickOpen), AppCommand.quickOpen.defaultBinding)
        XCTAssertNil(settings.set(custom, for: .quickOpen))
        settings.resetAll()
        XCTAssertTrue(ShortcutPreferences(defaults: defaults).overrides.isEmpty)
    }

    func testConflictsIncludeDefaultBindingsAndZoomAliases() throws {
        let suite = "vsux.Shortcuts.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ShortcutPreferences(defaults: defaults)
        XCTAssertNotNil(settings.set(KeyBinding("f", .command), for: .quickOpen))
        XCTAssertNotNil(settings.set(KeyBinding("=", [.control, .shift]), for: .quickOpen))
        XCTAssertNotNil(settings.set(KeyBinding("p", []), for: .quickOpen))
        XCTAssertEqual(settings.binding(for: .quickOpen), AppCommand.quickOpen.defaultBinding)
        XCTAssertNil(settings.set(.disabled, for: .find))
        XCTAssertNil(settings.set(KeyBinding("f", .command), for: .quickOpen))
        XCTAssertNotNil(settings.reset(.find), "Reset must not create a conflict with a user binding")
    }

    func testMalformedAndCollidingSavedDataFallsBackSafely() throws {
        let suite = "vsux.Shortcuts.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("bad json".utf8), forKey: "keyboardShortcuts")
        XCTAssertTrue(ShortcutPreferences(defaults: defaults).overrides.isEmpty)
        defaults.set(try JSONEncoder().encode(["quickOpen": KeyBinding("f", .command)]), forKey: "keyboardShortcuts")
        XCTAssertTrue(ShortcutPreferences(defaults: defaults).overrides.isEmpty)
    }

    func testFileFindBindingPersistsClearsResetsAndDetectsConflicts() throws {
        let suite = "vsux.Shortcuts.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ShortcutPreferences(defaults: defaults)
        XCTAssertEqual(settings.binding(for: .find), KeyBinding("f", .command))
        XCTAssertEqual(settings.binding(for: .findFile), KeyBinding("f", .control))
        XCTAssertNotNil(settings.set(KeyBinding("f", .control), for: .quickOpen))
        XCTAssertNotNil(settings.set(KeyBinding("f", .command), for: .findFile))
        let custom = KeyBinding("f", [.control, .shift])
        XCTAssertNil(settings.set(custom, for: .findFile))
        XCTAssertEqual(ShortcutPreferences(defaults: defaults).binding(for: .findFile), custom)
        XCTAssertNil(settings.set(.disabled, for: .findFile))
        XCTAssertTrue(ShortcutPreferences(defaults: defaults).binding(for: .findFile).isDisabled)
        XCTAssertNil(settings.reset(.findFile))
        XCTAssertEqual(settings.binding(for: .findFile), KeyBinding("f", .control))
    }

    func testExistingControlFOverrideSurvivesNewFileFindCommand() throws {
        let suite = "vsux.Shortcuts.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let custom = KeyBinding("f", .control)
        defaults.set(try JSONEncoder().encode(["quickOpen": custom]), forKey: "keyboardShortcuts")
        let settings = ShortcutPreferences(defaults: defaults)
        XCTAssertEqual(settings.binding(for: .quickOpen), custom)
        XCTAssertTrue(settings.binding(for: .findFile).isDisabled)
        XCTAssertEqual(settings.binding(for: .find), KeyBinding("f", .command))
        XCTAssertNotNil(settings.reset(.findFile))
        XCTAssertNil(settings.reset(.quickOpen))
        XCTAssertNil(settings.reset(.findFile))
    }

    func testExistingControlZeroOverrideSurvivesNewResetZoomCommand() throws {
        let suite = "vsux.Shortcuts.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let custom = KeyBinding("0", .control)
        defaults.set(try JSONEncoder().encode(["quickOpen": custom]), forKey: "keyboardShortcuts")
        let settings = ShortcutPreferences(defaults: defaults)
        XCTAssertEqual(settings.binding(for: .quickOpen), custom)
        XCTAssertTrue(settings.binding(for: .resetInterfaceZoom).isDisabled)
        XCTAssertNotNil(settings.reset(.resetInterfaceZoom))
    }

    func testRemappingRoutesNewKeysToOwningWindowAndUpdatesMenus() async throws {
        _ = NSApplication.shared
        let shortcuts = ShortcutPreferences.shared
        let original = shortcuts.overrides
        shortcuts.resetAll()
        defer { restore(original) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shortcut-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("sample.swift")
        try Data("before".utf8).write(to: file)
        let model = WindowModel(workspaces: [Workspace(name: "Keys", directory: root.path)], shellCommand: "/bin/zsh -f")
        let controller = TerminalWindowController(model: model)
        let window = try XCTUnwrap(controller.window)
        AppDelegate.shared.windows.append(controller)
        window.makeKeyAndOrderFront(nil)
        defer { model.disposeAll(); window.orderOut(nil); AppDelegate.shared.windows.removeAll { $0 === controller } }
        let terminal = try XCTUnwrap(model.focusedTerminal)
        window.makeFirstResponder(terminal)
        XCTAssertNil(shortcuts.set(KeyBinding("p", [.command, .shift]), for: .quickOpen))
        press(window, key: "p", code: 35, flags: .control)
        XCTAssertFalse(model.showQuickOpen, "Old Control-P binding must be released")
        press(window, key: "p", code: 35, flags: [.command, .shift])
        XCTAssertTrue(model.showQuickOpen)
        model.showQuickOpen = false
        let menus = try XCTUnwrap(NSApp.mainMenu)
        let quickOpenItem = try XCTUnwrap(menus.items.compactMap(\.submenu).flatMap(\.items).first { $0.identifier?.rawValue == AppCommand.quickOpen.rawValue })
        XCTAssertEqual(quickOpenItem.keyEquivalentModifierMask, [.command, .shift])
        XCTAssertNil(shortcuts.set(KeyBinding("k", .command), for: .quickOpen))
        XCTAssertTrue(window.performKeyEquivalent(with: event(window, key: "k", code: 40, flags: .command)))
        XCTAssertTrue(model.showQuickOpen, "Command shortcuts must reach the app before Ghostty's key equivalents")
        model.showQuickOpen = false
        XCTAssertNil(shortcuts.set(KeyBinding("p", [.command, .shift]), for: .quickOpen))

        let files = model.tools.files(try XCTUnwrap(model.workspace))
        files.open(file, preview: false)
        model.tools.content = .editor
        try await Task.sleep(for: .milliseconds(100))
        let editor = try XCTUnwrap(find(CodeTextView.self, in: try XCTUnwrap(window.contentView)))
        window.makeFirstResponder(editor)
        var findOpens = 0
        let onFind = editor.onFind
        editor.onFind = { findOpens += 1 }
        defer { editor.onFind = onFind }
        XCTAssertNil(shortcuts.set(KeyBinding("f", [.control, .shift]), for: .findFile))
        _ = window.performKeyEquivalent(with: event(window, key: "f", code: 3, flags: .control))
        XCTAssertEqual(findOpens, 0, "Retired Ctrl+F must not bypass the configured command")
        XCTAssertFalse(editor.performKeyEquivalent(with: event(window, key: "f", code: 3, flags: .control)))
        XCTAssertTrue(editor.performKeyEquivalent(with: event(window, key: "f", code: 3, flags: [.control, .shift])))
        XCTAssertEqual(findOpens, 1)
        let findItem = try XCTUnwrap(NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items).first { $0.identifier?.rawValue == AppCommand.findFile.rawValue })
        XCTAssertEqual(findItem.keyEquivalentModifierMask, [.control, .shift])
        XCTAssertNil(shortcuts.set(.disabled, for: .findFile))
        XCTAssertFalse(editor.performKeyEquivalent(with: event(window, key: "f", code: 3, flags: [.control, .shift])))
        XCTAssertEqual(findOpens, 1)
        XCTAssertNil(shortcuts.reset(.findFile))
        XCTAssertTrue(editor.performKeyEquivalent(with: event(window, key: "f", code: 3, flags: .control)))
        XCTAssertEqual(findOpens, 2)
        editor.onFind = onFind
        XCTAssertNil(shortcuts.set(KeyBinding("a", [.control, .shift]), for: .selectAll))
        XCTAssertTrue(window.performKeyEquivalent(with: event(window, key: "a", code: 0, flags: [.control, .shift])))
        XCTAssertEqual(editor.selectedRange().length, (editor.string as NSString).length)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertTrue(window.performKeyEquivalent(with: event(window, key: "a", code: 0, flags: .command)))
        XCTAssertEqual(editor.selectedRange().length, 0, "Retired Command-A must not leak into NSTextView's default select-all")
        XCTAssertNil(shortcuts.set(KeyBinding("s", [.control, .shift]), for: .saveFile))
        let doc = try XCTUnwrap(files.selectedDocument)
        files.update(doc, text: "after")
        // Test the editor's own key-equivalent path as well as window dispatch.
        XCTAssertFalse(editor.performKeyEquivalent(with: event(window, key: "s", code: 1, flags: .command)))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "before")
        press(window, key: "s", code: 1, flags: [.control, .shift])
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "after")
        press(window, key: "p", code: 35, flags: [.command, .shift])
        XCTAssertTrue(model.showQuickOpen, "New binding must work with editor focus too")
        model.showQuickOpen = false
        XCTAssertNil(shortcuts.set(.disabled, for: .quickOpen))
        press(window, key: "p", code: 35, flags: [.command, .shift])
        XCTAssertFalse(model.showQuickOpen)
    }

    func testRecorderCapturesKeysWithoutExecutingCommandsAndHandlesConflictCancelClear() async throws {
        _ = NSApplication.shared
        let shortcuts = ShortcutPreferences.shared
        let original = shortcuts.overrides
        shortcuts.resetAll()
        defer { restore(original) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 610, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: SettingsView(preferences: .shared, initialTab: 1))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(100))
        let host = try XCTUnwrap(window.contentView)
        let recorder = try XCTUnwrap(allRecorders(in: host).first { $0.accessibilityIdentifier() == "shortcut-recorder-quickOpen" })
        recorder.beginRecording()
        XCTAssertTrue(window.performKeyEquivalent(with: event(window, key: "f", code: 3, flags: .command)), "The native settings window must send menu equivalents to the active recorder")
        XCTAssertTrue(recorder.recording, "Conflicts should leave recording active")
        XCTAssertEqual(shortcuts.binding(for: .quickOpen), AppCommand.quickOpen.defaultBinding)
        press(window, key: "p", code: 35, flags: [.command, .shift])
        XCTAssertFalse(recorder.recording)
        XCTAssertEqual(shortcuts.binding(for: .quickOpen), KeyBinding("p", [.command, .shift]))
        recorder.beginRecording()
        press(window, key: "\u{1b}", code: 53, flags: [])
        XCTAssertEqual(shortcuts.binding(for: .quickOpen), KeyBinding("p", [.command, .shift]))
        recorder.beginRecording()
        press(window, key: "\u{7f}", code: 51, flags: [])
        XCTAssertTrue(shortcuts.binding(for: .quickOpen).isDisabled)
        if let destination = ProcessInfo.processInfo.environment["CMUX_SHORTCUT_SNAPSHOT"] {
            try await Task.sleep(for: .milliseconds(80))
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-l", String(window.windowNumber), destination]
            try capture.run(); capture.waitUntilExit()
            XCTAssertEqual(capture.terminationStatus, 0)
        }
    }

    private func restore(_ bindings: [String: KeyBinding]) {
        let shortcuts = ShortcutPreferences.shared
        shortcuts.resetAll()
        // Clear every overridden command first to permit binding swaps.
        for key in bindings.keys { if let command = AppCommand(rawValue: key) { shortcuts.set(.disabled, for: command) } }
        for (key, binding) in bindings { if let command = AppCommand(rawValue: key) { shortcuts.set(binding, for: command) } }
    }
    private func event(_ window: NSWindow, key: String, code: UInt16, flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: code)!
    }
    private func press(_ window: NSWindow, key: String, code: UInt16, flags: NSEvent.ModifierFlags) { window.sendEvent(event(window, key: key, code: code, flags: flags)) }
    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? { (view as? T) ?? view.subviews.lazy.compactMap { self.find(type, in: $0) }.first }
    private func allRecorders(in view: NSView) -> [ShortcutCaptureView] { (view as? ShortcutCaptureView).map { [$0] } ?? view.subviews.flatMap { allRecorders(in: $0) } }
}
