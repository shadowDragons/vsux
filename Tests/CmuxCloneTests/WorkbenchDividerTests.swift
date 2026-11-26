import AppKit
import XCTest
@testable import CmuxClone

@MainActor
final class WorkbenchDividerTests: XCTestCase {
    func testBothDividersTrackPointerAndCanExpandPastOldLimits() throws {
        for width in [1024.0, 1100] {
            try verifyDividers(windowWidth: width)
        }
    }

    private func verifyDividers(windowWidth: CGFloat) throws {
        _ = NSApplication.shared
        let preferences = Preferences.shared
        let originalZoom = preferences.interfaceZoomLevel
        preferences.setInterfaceZoomLevel(0)
        let model = WindowModel(shellCommand: "/bin/zsh -f")
        let controller = TerminalWindowController(model: model)
        let window = try XCTUnwrap(controller.window)
        let originalSize = NSSize(width: windowWidth, height: 650)
        window.setContentSize(originalSize)
        window.makeKeyAndOrderFront(nil)
        defer {
            model.disposeAll()
            window.orderOut(nil)
            preferences.setInterfaceZoomLevel(originalZoom)
        }

        settle(window)
        let content = try XCTUnwrap(window.contentView)
        let viewport = content.convert(content.bounds, to: nil)
        let terminal = try XCTUnwrap(model.focusedTerminal)
        func terminalFrame() -> NSRect { terminal.convert(terminal.bounds, to: nil) }
        let initial = terminalFrame()
        let centerMinimum: CGFloat = 220
        let leftEdgeAtMinimum = viewport.minX + 150 + 5
        let rightEdgeAtMinimum = viewport.maxX - 240 - 5
        let centerSlack = initial.width - centerMinimum
        let rightSlack = rightEdgeAtMinimum - initial.maxX
        let leftSlack = initial.minX - leftEdgeAtMinimum
        XCTAssertGreaterThan(centerSlack, 150)
        XCTAssertGreaterThan(rightSlack, 0)
        XCTAssertGreaterThan(leftSlack, 0)

        let leftStart = NSPoint(x: initial.minX - 2.5, y: initial.midY)
        try send(.leftMouseDown, at: leftStart, to: window)
        for delta in [20.0, 40, 60, 140, centerSlack + rightSlack / 2] {
            let point = NSPoint(x: leftStart.x + delta, y: leftStart.y)
            try send(.leftMouseDragged, at: point, to: window)
            settle(window)
            XCTAssertEqual(terminalFrame().minX, initial.minX + delta, accuracy: 2, "Left divider lost the pointer at \(delta) points")
        }
        XCTAssertGreaterThan(terminalFrame().maxX, initial.maxX, "After the center reaches minimum width, the right area should yield")
        let beyondLeftLimit = NSPoint(x: leftStart.x + centerSlack + rightSlack + 50, y: leftStart.y)
        try send(.leftMouseDragged, at: beyondLeftLimit, to: window)
        settle(window)
        XCTAssertEqual(terminalFrame().width, centerMinimum, accuracy: 2)
        XCTAssertEqual(terminalFrame().maxX, rightEdgeAtMinimum, accuracy: 2)
        try send(.leftMouseDragged, at: NSPoint(x: leftStart.x + 140, y: leftStart.y), to: window)
        settle(window)
        XCTAssertEqual(terminalFrame().minX, initial.minX + 140, accuracy: 2)
        XCTAssertEqual(terminalFrame().maxX, initial.maxX, accuracy: 2)
        for _ in 0..<3 {
            try send(.leftMouseDragged, at: leftStart, to: window)
            settle(window)
            XCTAssertEqual(terminalFrame().minX, initial.minX, accuracy: 2)
            XCTAssertEqual(terminalFrame().maxX, initial.maxX, accuracy: 2)
        }
        try send(.leftMouseUp, at: leftStart, to: window)

        let rightStart = NSPoint(x: initial.maxX + 2.5, y: initial.midY)
        try send(.leftMouseDown, at: rightStart, to: window)
        for delta in [20.0, 40, 60, 150, centerSlack + leftSlack / 2] {
            let point = NSPoint(x: rightStart.x - delta, y: rightStart.y)
            try send(.leftMouseDragged, at: point, to: window)
            settle(window)
            XCTAssertEqual(terminalFrame().maxX, initial.maxX - delta, accuracy: 2, "Right divider lost the pointer at \(delta) points")
        }
        XCTAssertLessThan(terminalFrame().minX, initial.minX, "After the center reaches minimum width, the left area should yield")
        let beyondRightLimit = NSPoint(x: rightStart.x - centerSlack - leftSlack - 50, y: rightStart.y)
        try send(.leftMouseDragged, at: beyondRightLimit, to: window)
        settle(window)
        XCTAssertEqual(terminalFrame().width, centerMinimum, accuracy: 2)
        XCTAssertEqual(terminalFrame().minX, leftEdgeAtMinimum, accuracy: 2)
        try send(.leftMouseUp, at: beyondRightLimit, to: window)
        let final = terminalFrame()

        // Temporarily shrinking the window and hiding a panel preserve the chosen widths.
        window.setContentSize(NSSize(width: 940, height: 650))
        settle(window)
        XCTAssertGreaterThanOrEqual(terminalFrame().width, 218)
        model.showSidebar = false
        settle(window)
        XCTAssertEqual(terminalFrame().minX, 0, accuracy: 2)
        // A small display may constrain the requested size when the window is shown.
        window.setContentSize(viewport.size)
        model.showSidebar = true
        settle(window)
        XCTAssertEqual(terminalFrame().minX, final.minX, accuracy: 2)
        XCTAssertEqual(terminalFrame().maxX, final.maxX, accuracy: 2)

        preferences.setInterfaceZoomLevel(1)
        settle(window)
        let zoomed = terminalFrame()
        let dividerHalfWidth = 2.5 * preferences.zoomFactor
        let zoomStart = NSPoint(x: zoomed.maxX + dividerHalfWidth, y: zoomed.midY)
        let zoomEnd = NSPoint(x: zoomStart.x + 100, y: zoomStart.y)
        try send(.leftMouseDown, at: zoomStart, to: window)
        try send(.leftMouseDragged, at: zoomEnd, to: window)
        settle(window)
        XCTAssertEqual(terminalFrame().maxX, zoomed.maxX + 100, accuracy: 2)
        try send(.leftMouseUp, at: zoomEnd, to: window)

        preferences.setInterfaceZoomLevel(8)
        settle(window)
        XCTAssertGreaterThan(terminalFrame().width, 0)
        XCTAssertLessThan(terminalFrame().maxX, viewport.maxX)
    }

    private func settle(_ window: NSWindow) {
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.035))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private func send(_ type: NSEvent.EventType, at location: NSPoint, to window: NSWindow) throws {
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
        window.sendEvent(event)
    }
}
