import XCTest
import AppKit
import SwiftUI
import WebKit
import CGhostty
@testable import CmuxClone

final class AppearanceTests: XCTestCase {
    @MainActor func testAppearancePersistsAndResolvesSystemWithoutChangingTerminalSettings() throws {
        _ = NSApplication.shared
        let suite = "CmuxClone.AppearanceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let original = NSApp.appearance
        defer {
            NSApp.appearance = original
            GhosttyEngine.shared.apply(Preferences.shared.effectiveTerminalSettings)
            defaults.removePersistentDomain(forName: suite)
        }
        let preferences = Preferences(defaults: defaults)
        XCTAssertEqual(preferences.appearance, .system)
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        XCTAssertEqual(preferences.terminalSettings(for: light).theme, "light")
        XCTAssertEqual(preferences.terminalSettings(for: dark).theme, "dark")
        let terminal = preferences.terminal
        preferences.appearance = .dark
        XCTAssertEqual(Preferences(defaults: defaults).appearance, .dark)
        XCTAssertEqual(preferences.terminalSettings(for: light).theme, "dark")
        preferences.appearance = .light
        XCTAssertEqual(Preferences(defaults: defaults).appearance, .light)
        XCTAssertEqual(preferences.terminalSettings(for: dark).theme, "light")
        preferences.appearance = .system
        XCTAssertNil(NSApp.appearance)
        XCTAssertEqual(Preferences(defaults: defaults).appearance, .system)
        XCTAssertEqual(preferences.terminal, terminal, "切换外观不得重置字体、透明度等终端设置")

        defaults.removeObject(forKey: "appAppearance")
        var legacy = TerminalSettings(); legacy.theme = "dark"; legacy.fontSize = 19
        defaults.set(try JSONEncoder().encode(legacy), forKey: "terminalSettings")
        let migrated = Preferences(defaults: defaults)
        XCTAssertEqual(migrated.appearance, .dark)
        XCTAssertEqual(migrated.terminal.fontSize, 19)
    }

    @MainActor func testAppearanceUpdatesNativeEditorPreviewAndKeepsTerminalSession() async throws {
        _ = NSApplication.shared
        let suite = "CmuxClone.AppearanceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let preferences = Preferences(defaults: defaults)
        let original = NSApp.appearance
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let controller = TerminalWindowController(model: WindowModel(shellCommand: "/bin/zsh -f"))
        let window = try XCTUnwrap(controller.window)
        AppDelegate.shared.windows.append(controller)
        window.orderFront(nil)
        let document = LocalFileDocument(url: URL(fileURLWithPath: "/tmp/appearance.md"), text: "# Appearance\n", data: Data("# Appearance\n".utf8), isPreview: false)
        let host = NSHostingView(rootView: HStack {
            SyntaxEditor(document: document, onChange: { document.text = $0 }, onSave: {})
            MarkdownPreview(source: document.text, documentURL: document.url, rootURL: URL(fileURLWithPath: "/tmp"))
        })
        defer {
            controller.model.disposeAll(); window.orderOut(nil)
            AppDelegate.shared.windows.removeAll { $0 === controller }
            NSApp.appearance = original
            GhosttyEngine.shared.apply(Preferences.shared.effectiveTerminalSettings)
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        try await eventually { controller.model.focusedTerminal?.surface != nil }
        let terminal = try XCTUnwrap(controller.model.focusedTerminal)
        let surface = try XCTUnwrap(terminal.surface)
        func enter() {
            terminal.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!)
        }
        terminal.pasteText("export CMUX_APPEARANCE_TEST_VALUE=preserved; printf ready > '\(root.appendingPathComponent("ready").path)'")
        enter()
        try await eventually { FileManager.default.fileExists(atPath: root.appendingPathComponent("ready").path) }
        let process = ghostty_surface_foreground_pid(surface)
        XCTAssertGreaterThan(process, 0)
        window.contentView = host
        var editor: CodeTextView?
        var preview: WKWebView?
        try await eventually {
            editor = self.find(CodeTextView.self, in: host)
            preview = self.find(WKWebView.self, in: host)
            return editor != nil && preview != nil
        }
        let text = try XCTUnwrap(editor)
        let web = try XCTUnwrap(preview)
        text.setSelectedRange(NSRange(location: 3, length: 0))
        for mode in [AppAppearance.dark, .light] {
            preferences.appearance = mode
            try await eventually {
                let nativeDark = text.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                let webDark = try? await web.evaluateJavaScript("matchMedia('(prefers-color-scheme: dark)').matches") as? Bool
                return nativeDark == (mode == .dark) && webDark == (mode == .dark)
            }
            XCTAssertEqual(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), mode == .dark ? .darkAqua : .aqua)
            XCTAssertEqual(terminal.surface, surface, "外观切换不得重建终端")
            XCTAssertEqual(ghostty_surface_foreground_pid(surface), process)
            XCTAssertEqual(text.selectedRange(), NSRange(location: 3, length: 0))
            XCTAssertFalse(document.isDirty)
        }
        preferences.appearance = .system
        XCTAssertNil(NSApp.appearance)
        let result = root.appendingPathComponent("result")
        terminal.pasteText("printf '%s' \"$CMUX_APPEARANCE_TEST_VALUE\" > '\(result.path)'")
        enter()
        try await eventually { FileManager.default.fileExists(atPath: result.path) }
        XCTAssertEqual(try String(contentsOf: result, encoding: .utf8), "preserved")
    }

    @MainActor private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        (view as? T) ?? view.subviews.lazy.compactMap { self.find(type, in: $0) }.first
    }
    @MainActor private func eventually(_ predicate: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if try await predicate() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("外观未在预期时间内更新")
    }
}
