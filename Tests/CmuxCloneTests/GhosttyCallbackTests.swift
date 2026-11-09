import AppKit
import CGhostty
import XCTest
@testable import CmuxClone

final class GhosttyCallbackTests: XCTestCase {
    @MainActor func testRendererThreadActionReturnsWithoutMainThreadOrTrap() async throws {
        _ = NSApplication.shared
        let app = try XCTUnwrap(GhosttyEngine.shared.app)
        let address = UInt(bitPattern: app)
        let returned = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            var target = ghostty_target_s()
            target.tag = GHOSTTY_TARGET_APP
            var action = ghostty_action_s()
            action.tag = GHOSTTY_ACTION_RENDERER_HEALTH
            XCTAssertFalse(GhosttyEngine.actionCallback(UnsafeMutableRawPointer(bitPattern: address), target, action))
            // Unsupported surface events must not dereference a C surface,
            // including when the pointer is no longer a live terminal.
            target.tag = GHOSTTY_TARGET_SURFACE
            target.target.surface = UnsafeMutableRawPointer(bitPattern: 1)
            for _ in 0..<1000 {
                XCTAssertFalse(GhosttyEngine.actionCallback(UnsafeMutableRawPointer(bitPattern: address), target, action))
            }
            returned.signal()
        }
        // Deliberately keep the main thread occupied. A synchronous dispatch
        // from a renderer can deadlock while the main thread is freeing it.
        XCTAssertEqual(returned.wait(timeout: .now() + 2), .success)
    }

    @MainActor func testBackgroundActionsCopyBorrowedPayloadsAndDeliverOnMainThreadInOrder() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let appAddress = UInt(bitPattern: try XCTUnwrap(GhosttyEngine.shared.app))
        let surfaceAddress = UInt(bitPattern: try XCTUnwrap(fixture.terminal.surface))
        let pane = fixture.terminal.paneID
        let returned = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            var target = ghostty_target_s()
            target.tag = GHOSTTY_TARGET_SURFACE
            target.target.surface = UnsafeMutableRawPointer(bitPattern: surfaceAddress)
            for index in 0..<64 {
                let text = strdup("renderer title \(index)")!
                var action = ghostty_action_s()
                action.tag = GHOSTTY_ACTION_SET_TITLE
                action.action.set_title.title = UnsafePointer(text)
                XCTAssertTrue(GhosttyEngine.actionCallback(UnsafeMutableRawPointer(bitPattern: appAddress), target, action))
                // Invalidate the borrowed C storage before MainActor can deliver.
                memset(text, 0x78, strlen(text))
                free(text)
            }
            let text = strdup("/tmp/renderer-directory")!
            var action = ghostty_action_s()
            action.tag = GHOSTTY_ACTION_PWD
            action.action.pwd.pwd = UnsafePointer(text)
            XCTAssertTrue(GhosttyEngine.actionCallback(UnsafeMutableRawPointer(bitPattern: appAddress), target, action))
            memset(text, 0x78, strlen(text)); free(text)
            returned.signal()
        }
        XCTAssertEqual(returned.wait(timeout: .now() + 2), .success)
        XCTAssertNotEqual(fixture.model.selectedTab?.title, "renderer title 63", "The worker must not mutate UI directly")
        try pump {
            fixture.model.selectedTab?.title == "renderer title 63" &&
            fixture.model.terminalDirectories[pane] == "/tmp/renderer-directory"
        }
        XCTAssertEqual(fixture.terminal.directory, "/tmp/renderer-directory")
        // The main-thread fast path retains the immediate behavior needed by
        // synchronous actions and must not re-enter singleton initialization.
        var target = ghostty_target_s()
        target.tag = GHOSTTY_TARGET_SURFACE
        target.target.surface = fixture.terminal.surface
        "main thread title".withCString { text in
            var action = ghostty_action_s()
            action.tag = GHOSTTY_ACTION_SET_TITLE
            action.action.set_title.title = text
            XCTAssertTrue(GhosttyEngine.actionCallback(UnsafeMutableRawPointer(bitPattern: appAddress), target, action))
        }
        XCTAssertEqual(fixture.model.selectedTab?.title, "main thread title")
    }

    @MainActor func testQueuedAndLateCallbacksCannotAccessClosedSurfaceOrItsReplacement() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let engine = GhosttyEngine.shared
        let appAddress = UInt(bitPattern: try XCTUnwrap(engine.app))
        let surfaceAddress = UInt(bitPattern: try XCTUnwrap(fixture.terminal.surface))
        let originalDirectory = fixture.terminal.directory
        let returned = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            var target = ghostty_target_s()
            target.tag = GHOSTTY_TARGET_SURFACE
            target.target.surface = UnsafeMutableRawPointer(bitPattern: surfaceAddress)
            "/tmp/stale-renderer-directory".withCString { text in
                var action = ghostty_action_s()
                action.tag = GHOSTTY_ACTION_PWD
                action.action.pwd.pwd = text
                XCTAssertTrue(GhosttyEngine.actionCallback(UnsafeMutableRawPointer(bitPattern: appAddress), target, action))
            }
            returned.signal()
        }
        XCTAssertEqual(returned.wait(timeout: .now() + 2), .success)
        fixture.terminal.shutdown()
        // Force address reuse in the registry: an already queued event must
        // not resolve that pointer to a different view when delivery runs.
        let replacement = try Fixture()
        defer { replacement.close() }
        let replacementDirectory = replacement.terminal.directory
        let oldSurface = try XCTUnwrap(UnsafeMutableRawPointer(bitPattern: surfaceAddress))
        engine.actionBridge.register(surface: oldSurface, view: replacement.terminal)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(fixture.terminal.directory, originalDirectory)
        XCTAssertEqual(replacement.terminal.directory, replacementDirectory)
        engine.actionBridge.unregister(surface: oldSurface)
        var target = ghostty_target_s()
        target.tag = GHOSTTY_TARGET_SURFACE
        target.target.surface = oldSurface
        "late title".withCString { text in
            var action = ghostty_action_s()
            action.tag = GHOSTTY_ACTION_SET_TITLE
            action.action.set_title.title = text
            XCTAssertFalse(GhosttyEngine.actionCallback(engine.app, target, action))
        }
        XCTAssertNil(fixture.terminal.surface)
    }

    @MainActor private func pump(_ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(condition())
    }

    @MainActor private final class Fixture {
        let model: WindowModel
        let window: NSWindow
        let terminal: GhosttyTerminalView

        init() throws {
            _ = NSApplication.shared
            model = WindowModel(shellCommand: "/bin/cat")
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
            terminal = model.terminal(try XCTUnwrap(model.selectedTab?.focusedPane))
            window.contentView = terminal
            window.orderFront(nil)
            XCTAssertNotNil(terminal.surface)
        }

        func close() { model.disposeAll(); window.orderOut(nil) }
    }
}
