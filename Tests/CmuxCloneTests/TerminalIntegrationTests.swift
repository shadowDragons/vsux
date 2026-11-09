import XCTest
import AppKit
import CGhostty
@testable import CmuxClone

final class TerminalIntegrationTests: XCTestCase {
    @MainActor func testRelaunchedWindowRestoresRenamedTabsAndStartsFreshShellInSavedDirectory() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-restore-" + UUID().uuidString)
        let child = root.appendingPathComponent("backend")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = WorkspaceSession(directory: root)
        let model = WindowModel(workspaces: [Workspace(name: "恢复测试", directory: root.path)], shellCommand: "/bin/zsh -f")
        session.register(model)
        let controller = TerminalWindowController(model: model)
        let window = try XCTUnwrap(controller.window)
        window.orderFront(nil)
        defer { model.disposeAll(); window.orderOut(nil) }
        model.mutateTab { $0.title = "前端"; $0.customTitle = true }
        model.addTab()
        model.mutateTab { $0.title = "后端"; $0.customTitle = true }
        let pane = try XCTUnwrap(model.selectedTab?.focusedPane)
        model.addLocalTab(pane)
        let activeID = model.activeTerminalID(pane)
        model.paneTabs[pane]?[1].title = "开发服务"
        model.paneTabs[pane]?[1].customTitle = true
        XCTAssertTrue(pump { model.terminals[activeID]?.surface != nil })
        let terminal = try XCTUnwrap(model.terminals[activeID])
        func enter(_ view: GhosttyTerminalView, in window: NSWindow) {
            view.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!)
        }
        terminal.pasteText("cd '\(child.path)'; export CMUX_RESTORE_TEST=old; printf '\\033]7;file://localhost%s\\007' \"$PWD\"")
        enter(terminal, in: window)
        XCTAssertTrue(pump { terminal.directory == child.path && model.terminalDirectories[activeID] == child.path })
        session.finish()
        model.disposeAll(); window.orderOut(nil)

        let nextSession = WorkspaceSession(directory: root)
        let restored = try XCTUnwrap(nextSession.restore(shellCommand: "/bin/zsh -f").first)
        nextSession.register(restored)
        let nextController = TerminalWindowController(model: restored)
        let nextWindow = try XCTUnwrap(nextController.window)
        nextWindow.orderFront(nil)
        defer { nextSession.finish(); restored.disposeAll(); nextWindow.orderOut(nil) }
        XCTAssertEqual(restored.workspace?.tabs.map(\.title), ["前端", "后端"])
        XCTAssertEqual(restored.activeTerminalID(pane), activeID)
        XCTAssertEqual(restored.localTabs(pane).last?.title, "开发服务")
        XCTAssertTrue(pump { restored.focusedTerminal?.surface != nil })
        let fresh = try XCTUnwrap(restored.focusedTerminal)
        XCTAssertFalse(fresh === terminal)
        let result = root.appendingPathComponent("restored-shell")
        fresh.pasteText("printf '%s\\n%s' \"$PWD\" \"${CMUX_RESTORE_TEST-unset}\" > '\(result.path)'")
        enter(fresh, in: nextWindow)
        XCTAssertTrue(pump { FileManager.default.fileExists(atPath: result.path) })
        XCTAssertEqual(try String(contentsOf: result, encoding: .utf8), child.path + "\nunset")
        XCTAssertNil(restored.error)
    }

    @MainActor func pump(until predicate: () -> Bool, timeout: TimeInterval = 8) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.025)) }
        return predicate()
    }
    @MainActor func testRealShellCwdKeysAndFocusedCommandInsertion() throws {
        _ = NSApplication.shared
        let model = WindowModel(shellCommand: "/bin/zsh -f")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        model.window = window
        let pane = model.selectedTab!.focusedPane
        let terminal = model.terminal(pane)
        window.contentView = terminal
        window.orderFront(nil)
        defer { model.disposeAll(); window.orderOut(nil) }
        XCTAssertNotNil(terminal.surface)
        guard terminal.surface != nil else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-integration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func press(_ code: UInt16, _ chars: String, flags: NSEvent.ModifierFlags = []) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
            terminal.keyDown(with: event)
        }
        // Paste inserts a command. Enter goes through the native keyboard bridge.
        terminal.pasteText("cd '\(root.path)' && export CMUX_TEST_VALUE=persistent")
        press(36, "\r")
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        terminal.pasteText("printf '%s\\n' \"$PWD:$CMUX_TEST_VALUE\" > result")
        press(36, "\r")
        XCTAssertTrue(pump { FileManager.default.fileExists(atPath: root.appendingPathComponent("result").path) })
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("result"), encoding: .utf8), root.path + ":persistent\n")
        // Ctrl-C must interrupt an actual foreground process.
        terminal.pasteText("sleep 30")
        press(36, "\r")
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        press(8, "c", flags: [.control])
        terminal.pasteText("printf '中文' > interrupted")
        press(36, "\r")
        XCTAssertTrue(pump { FileManager.default.fileExists(atPath: root.appendingPathComponent("interrupted").path) })
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("interrupted"), encoding: .utf8), "中文")
        // Commands filled from the library do not execute until Enter.
        model.insertCommand("printf filled > filled")
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("filled").path))
        press(36, "\r")
        XCTAssertTrue(pump { FileManager.default.fileExists(atPath: root.appendingPathComponent("filled").path) })
        // A hidden Tab keeps its Shell, and a new split receives the library text.
        let originalTab = model.selectedTab!.id
        model.addTab()
        let otherTab = model.selectedTab!.id
        XCTAssertNotEqual(originalTab, otherTab)
        model.selectTab(originalTab)
        XCTAssertTrue(model.focusedTerminal === terminal)
        model.split(.horizontal)
        let right = model.focusedTerminal!
        XCTAssertFalse(right === terminal)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 480))
        terminal.removeFromSuperview(); window.contentView = host
        terminal.frame = NSRect(x: 0, y: 0, width: 360, height: 480)
        right.frame = NSRect(x: 360, y: 0, width: 360, height: 480)
        host.addSubview(terminal); host.addSubview(right)
        XCTAssertNotNil(right.surface)
        model.insertCommand("printf focused > '\(root.path)/focused'")
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("focused").path))
        let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        right.keyDown(with: enter)
        XCTAssertTrue(pump { FileManager.default.fileExists(atPath: root.appendingPathComponent("focused").path) })
        model.focus(pane)
        terminal.pasteText("printf '%s' \"$CMUX_TEST_VALUE\" > retained")
        press(36, "\r")
        XCTAssertTrue(pump { FileManager.default.fileExists(atPath: root.appendingPathComponent("retained").path) })
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("retained"), encoding: .utf8), "persistent")
        // Library multi-line fill must stay pending even without bracketed paste.
        model.insertCommand("printf 'first' > multiline-first\nprintf second > multiline-second\n")
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("multiline-first").path))
        press(36, "\r")
        XCTAssertTrue(pump { FileManager.default.fileExists(atPath: root.appendingPathComponent("multiline-second").path) })
        // Committed input from an IME uses the text-input API rather than paste.
        terminal.insertText("printf '输入法' > ime", replacementRange: NSRange(location: NSNotFound, length: 0))
        press(36, "\r")
        XCTAssertTrue(pump { FileManager.default.fileExists(atPath: root.appendingPathComponent("ime").path) })
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("ime"), encoding: .utf8), "输入法")
        XCTAssertTrue(terminal.action("search:persistent"))
        XCTAssertTrue(terminal.action("navigate_search:next"))
        XCTAssertTrue(terminal.action("end_search"))
    }
}
