import AppKit
import SwiftUI
import WebKit
import CGhostty
import XCTest
@testable import CmuxClone

@MainActor
final class FontShortcutTests: XCTestCase {
    func testControlKeysReachEditorAndPreviewWithoutEditingText() async throws {
        _ = NSApplication.shared
        AppDelegate.shared.makeMenus()
        let preferences = Preferences.shared
        let original = preferences.terminal
        preferences.terminal.fontSize = 14
        let source = "# Heading\n\nUnchanged body\n"
        let document = LocalFileDocument(url: URL(fileURLWithPath: "/tmp/font-shortcuts.md"), text: source, data: Data(source.utf8), isPreview: false)
        let window = PointerCursorWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: HStack {
            SyntaxEditor(document: document, onChange: { document.text = $0 }, onSave: {})
            MarkdownPreview(source: source, documentURL: document.url, rootURL: URL(fileURLWithPath: "/tmp"))
        })
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); preferences.terminal = original }
        try await wait { self.find(CodeTextView.self, in: host) != nil && self.find(WKWebView.self, in: host) != nil }
        let editor = try XCTUnwrap(find(CodeTextView.self, in: host))
        let preview = try XCTUnwrap(find(WKWebView.self, in: host))
        window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        // Real Control events can contain a control character rather than '+'.
        press(window, code: 24, characters: "=", ignoring: "=", flags: [.control])
        XCTAssertEqual(preferences.terminal.fontSize, 15, "Ctrl+= must reach the app before NSTextView")
        try await wait { editor.font?.pointSize == 15 }
        press(window, code: 24, characters: "+", ignoring: "+", flags: [.control, .shift])
        XCTAssertEqual(preferences.terminal.fontSize, 16, "Ctrl+Shift+= must also increase")
        press(window, code: 27, characters: "\u{1f}", ignoring: "-", flags: [.control])
        XCTAssertEqual(preferences.terminal.fontSize, 15)
        try await wait { (try? await preview.evaluateJavaScript("getComputedStyle(document.body).fontSize")) as? String == "15px" }
        XCTAssertEqual(document.text, source)
        XCTAssertFalse(document.isDirty)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 3, length: 0))
        window.makeFirstResponder(preview)
        press(window, code: 27, characters: "\u{1f}", ignoring: "-", flags: [.control])
        XCTAssertEqual(preferences.terminal.fontSize, 14, "Preview focus must not swallow the shortcut")
    }

    func testTerminalSettingsOverrideNativeZoomAndKeepShellAndGrid() async throws {
        _ = NSApplication.shared
        let preferences = Preferences.shared
        let original = preferences.terminal
        preferences.terminal.fontSize = 14
        let controller = TerminalWindowController(model: WindowModel(shellCommand: "/bin/zsh -f"))
        AppDelegate.shared.windows.append(controller)
        let window = try XCTUnwrap(controller.window)
        window.makeKeyAndOrderFront(nil)
        defer {
            controller.model.disposeAll(); window.orderOut(nil)
            AppDelegate.shared.windows.removeAll { $0 === controller }
            preferences.terminal = original
        }
        try await wait { controller.model.focusedTerminal?.surface != nil }
        let terminal = try XCTUnwrap(controller.model.focusedTerminal)
        let surface = try XCTUnwrap(terminal.surface)
        let ready = FileManager.default.temporaryDirectory.appendingPathComponent("font-shell-ready-\(UUID())")
        defer { try? FileManager.default.removeItem(at: ready) }
        terminal.pasteText("export CMUX_FONT_SESSION=preserved; printf ready > '\(ready.path)'")
        terminal.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!)
        try await wait { FileManager.default.fileExists(atPath: ready.path) }
        let process = ghostty_surface_foreground_pid(surface)
        window.makeFirstResponder(terminal)
        press(window, code: 24, characters: "=", ignoring: "=", flags: [.control])
        XCTAssertEqual(preferences.terminal.fontSize, 15)
        try await wait { ghostty_surface_font_size(surface) == 15 }
        preferences.terminal.fontSize = 14
        XCTAssertTrue(terminal.action("increase_font_size:3"))
        XCTAssertEqual(ghostty_surface_font_size(surface), 17)
        preferences.terminal.fontSize = 18
        try await wait { ghostty_surface_font_size(surface) == 18 }
        let large = ghostty_surface_size(surface)
        preferences.terminal.fontSize = 12
        try await wait { ghostty_surface_font_size(surface) == 12 }
        let small = ghostty_surface_size(surface)
        XCTAssertGreaterThan(small.columns, large.columns)
        XCTAssertGreaterThan(small.rows, large.rows)
        XCTAssertEqual(terminal.surface, surface)
        XCTAssertEqual(ghostty_surface_foreground_pid(surface), process)
    }

    func testOneFontChangeSendsOnePTYResize() async throws {
        _ = NSApplication.shared
        let preferences = Preferences.shared
        let original = preferences.terminal
        preferences.terminal.fontSize = 14
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("font-resize-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let events = root.appendingPathComponent("events")
        let ready = root.appendingPathComponent("ready")
        let script = root.appendingPathComponent("watch.py")
        try Data("""
        import os, signal, time
        def resized(*_):
            size = os.get_terminal_size()
            with open(\(String(reflecting: events.path)), 'a') as file:
                file.write(f'{size.lines} {size.columns}\\n')
        signal.signal(signal.SIGWINCH, resized)
        open(\(String(reflecting: ready.path)), 'w').close()
        while True: time.sleep(.01)
        """.utf8).write(to: script)
        let controller = TerminalWindowController(model: WindowModel(shellCommand: "/usr/bin/python3 " + script.path))
        AppDelegate.shared.windows.append(controller)
        let window = try XCTUnwrap(controller.window)
        window.orderFront(nil)
        defer {
            controller.model.disposeAll(); window.orderOut(nil)
            AppDelegate.shared.windows.removeAll { $0 === controller }
            preferences.terminal = original
            try? FileManager.default.removeItem(at: root)
        }
        try await wait { FileManager.default.fileExists(atPath: ready.path) }
        try await Task.sleep(for: .milliseconds(150))
        try Data().write(to: events)
        preferences.terminal.fontSize = 20
        try await wait { ((try? Data(contentsOf: events).count) ?? 0) > 0 }
        try await Task.sleep(for: .milliseconds(200))
        let rows = try String(contentsOf: events, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(rows.count, 1, "One zoom must not repeatedly resize/redraw the shell: \(rows)")
        let surface = try XCTUnwrap(controller.model.focusedTerminal?.surface)
        let grid = ghostty_surface_size(surface)
        XCTAssertEqual(rows.last.map(String.init), "\(grid.rows) \(grid.columns)")
    }

    func testBashPromptStaysAtLeftAfterZoom() async throws {
        _ = NSApplication.shared
        let preferences = Preferences.shared
        let original = preferences.terminal
        preferences.terminal.fontSize = 14
        let controller = TerminalWindowController(model: WindowModel(shellCommand: "/usr/bin/env TERM=cmux-font-unknown /bin/bash --noprofile --norc -i"))
        AppDelegate.shared.windows.append(controller)
        let window = try XCTUnwrap(controller.window)
        window.orderFront(nil)
        defer {
            controller.model.disposeAll(); window.orderOut(nil)
            AppDelegate.shared.windows.removeAll { $0 === controller }
            preferences.terminal = original
        }
        try await wait { controller.model.focusedTerminal?.surface != nil }
        let terminal = try XCTUnwrap(controller.model.focusedTerminal)
        let surface = try XCTUnwrap(terminal.surface)
        terminal.pasteText("PS1='CMUX_PROMPT> '; printf '\\033[2J\\033[H'")
        terminal.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!)
        try await Task.sleep(for: .milliseconds(200))
        for size in [18.0, 12, 20, 14, 18, 12, 20, 14] {
            preferences.terminal.fontSize = size
            try await Task.sleep(for: .milliseconds(30))
        }
        try await Task.sleep(for: .milliseconds(200))
        var selection = ghostty_selection_s()
        selection.top_left.tag = GHOSTTY_POINT_VIEWPORT
        selection.top_left.coord = GHOSTTY_POINT_COORD_TOP_LEFT
        selection.bottom_right.tag = GHOSTTY_POINT_VIEWPORT
        selection.bottom_right.coord = GHOSTTY_POINT_COORD_BOTTOM_RIGHT
        var output = ghostty_text_s()
        XCTAssertTrue(ghostty_surface_read_text(surface, selection, &output))
        defer { ghostty_surface_free_text(surface, &output) }
        let text = String(decoding: UnsafeBufferPointer(start: UnsafeRawPointer(output.text).assumingMemoryBound(to: UInt8.self), count: Int(output.text_len)), as: UTF8.self)
        let prompts = text.split(separator: "\n").filter { $0.contains("CMUX_PROMPT>") }
        XCTAssertFalse(prompts.isEmpty)
        XCTAssertTrue(prompts.allSatisfy { $0.hasPrefix("CMUX_PROMPT>") }, "Misaligned prompts: \(prompts)")
    }

    private func press(_ window: NSWindow, code: UInt16, characters: String, ignoring: String, flags: NSEvent.ModifierFlags) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: ignoring, isARepeat: false, keyCode: code)!
        window.sendEvent(event)
    }
    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        (view as? T) ?? view.subviews.lazy.compactMap { self.find(type, in: $0) }.first
    }
    private func wait(_ predicate: () async throws -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<100 {
            if try await predicate() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Font or view did not update", file: file, line: line)
        throw NSError(domain: "FontShortcutTests", code: 1)
    }
}
