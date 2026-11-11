import AppKit
import SwiftUI
import XCTest
import CGhostty
import WebKit
@testable import CmuxClone

@MainActor
final class WorkbenchZoomTests: XCTestCase {
    func testEditorToolbarButtonsCanBeClickedAfterZoomAndResize() async throws {
        _ = NSApplication.shared
        let preferences = Preferences.shared
        let original = preferences.interfaceZoomLevel
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zoom-editor-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("readme.md")
        try Data("# Click fixture\n\nBody".utf8).write(to: file)
        let files = FileWorkspaceModel(rootURL: root); files.open(file)
        let document = try XCTUnwrap(files.selectedDocument)
        document.markdownPreview = true; document.markdownPreviewOnly = true
        let container = WorkbenchHostingView(rootView: HStack(spacing: 0) {
            Color.clear.frame(width: 200)
            FileEditorArea(model: files)
        })
        let window = PointerCursorWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = container; window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil); preferences.setInterfaceZoomLevel(original)
            try? FileManager.default.removeItem(at: root)
        }
        func controls() -> [PointerCursorView] {
            let rowY = container.bounds.height - 52.5 * preferences.zoomFactor
            return regions(in: container).filter {
                abs($0.convert($0.bounds, to: nil).midY - rowY) < 3 * preferences.zoomFactor
            }.sorted { $0.convert($0.bounds, to: nil).midX < $1.convert($1.bounds, to: nil).midX }
        }
        for (level, width) in [(0, 1280.0), (2, 1280), (3, 1440), (1, 1180), (-1, 1180)] {
            preferences.setInterfaceZoomLevel(level)
            window.setContentSize(NSSize(width: width, height: 800))
            document.markdownPreview = true; document.markdownPreviewOnly = true; document.markdownShowOutline = true
            try await settle()
            XCTAssertEqual(controls().count, 3)
            let layout = try XCTUnwrap(controls().first)
            try click(layout, in: window)
            try await settle()
            XCTAssertFalse(document.markdownPreviewOnly, "Split editing must respond at zoom level \(level)")
            // Return to reading mode to expose exactly the three reported controls.
            document.markdownPreviewOnly = true
            try await settle()
            let outline = try XCTUnwrap(controls().dropFirst().first)
            try click(outline, in: window)
            try await settle()
            XCTAssertFalse(document.markdownShowOutline, "Outline toggle must respond at zoom level \(level)")
            let close = try XCTUnwrap(controls().last)
            try click(close, in: window)
            try await settle()
            XCTAssertFalse(document.markdownPreview, "Close preview must respond at zoom level \(level)")
            XCTAssertFalse(document.isDirty)
        }
    }

    func testTerminalEditorSwitcherCanBeClickedAfterZoom() async throws {
        _ = NSApplication.shared
        let preferences = Preferences.shared
        let original = preferences.interfaceZoomLevel
        let controller = TerminalWindowController(model: WindowModel(shellCommand: "/bin/zsh -f"))
        let window = try XCTUnwrap(controller.window)
        window.makeKeyAndOrderFront(nil)
        defer { controller.model.disposeAll(); window.orderOut(nil); preferences.setInterfaceZoomLevel(original) }
        let container = try XCTUnwrap(window.contentView as? WorkbenchHostingView<RootView>)
        for level in [0, 1, 2, 3, -1] {
            preferences.setInterfaceZoomLevel(level)
            try await settle()
            let switches = regions(in: container).filter {
                $0.bounds.width > 60 && $0.bounds.height == 26 &&
                $0.convert($0.bounds, to: nil).midY > container.bounds.height - 40 * preferences.zoomFactor
            }.sorted { $0.convert($0.bounds, to: nil).midX < $1.convert($1.bounds, to: nil).midX }
            XCTAssertEqual(switches.count, 2)
            try click(try XCTUnwrap(switches.last), in: window)
            try await settle()
            XCTAssertEqual(controller.model.tools.content, .editor, "Editor switch must respond at zoom level \(level)")
            try click(try XCTUnwrap(switches.first), in: window)
            try await settle()
            XCTAssertEqual(controller.model.tools.content, .terminal, "Terminal switch must respond at zoom level \(level)")
        }
    }

    func testServiceStartStopAndRestartButtonsCanBeClickedAtRightEdgeAfterZoom() async throws {
        _ = NSApplication.shared
        let preferences = Preferences.shared
        let original = preferences.interfaceZoomLevel
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("zoom-service-\(UUID())")
        let service = WorkspaceService(name: "Zoom click fixture", command: "/usr/bin/touch '\(marker.path)'; /bin/sleep 30")
        var workspace = Workspace(name: "Zoom fixture", directory: NSTemporaryDirectory())
        workspace.services = [service]
        let model = WindowModel(workspaces: [workspace], shellCommand: "/bin/zsh -f")
        let container = WorkbenchHostingView(rootView: HStack(spacing: 0) {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            CommandSidebar(model: model, library: .shared, workspace: workspace).frame(width: 280)
        })
        let window = PointerCursorWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = container; window.makeKeyAndOrderFront(nil)
        defer {
            model.disposeAll(); window.orderOut(nil)
            preferences.setInterfaceZoomLevel(original)
            try? FileManager.default.removeItem(at: marker)
        }
        func buttons() -> [PointerCursorView] {
            regions(in: container).filter { $0.isPointerEnabled && $0.bounds.width > 20 && $0.bounds.width < 50 && $0.bounds.height == 13 }
                .sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
        }
        for level in [0, 2, 3, -1, 1] {
            preferences.setInterfaceZoomLevel(level)
            try await settle()
            let scroll = try XCTUnwrap(find(NSScrollView.self, in: container))
            let offset = min(60, max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height))
            scroll.contentView.scroll(to: NSPoint(x: 0, y: offset)); scroll.reflectScrolledClipView(scroll.contentView)
            try await settle()
            let start = try XCTUnwrap(buttons().last)
            try click(start, in: window)
            try await settle()
            XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "The visible Start button in the right sidebar must receive the click at level \(level)")
            let process = try XCTUnwrap(model.serviceProcesses[service.id]?.process)
            try? FileManager.default.removeItem(at: marker)
            try click(try XCTUnwrap(buttons().last), in: window)
            for _ in 0..<100 {
                if let current = model.serviceProcesses[service.id]?.process, current !== process,
                   FileManager.default.fileExists(atPath: marker.path) { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertFalse(model.serviceProcesses[service.id]?.process === process, "Restart must respond at level \(level)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
            try await settle()
            try click(try XCTUnwrap(buttons().dropLast().last), in: window)
            for _ in 0..<100 where model.serviceProcesses[service.id] != nil { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertNil(model.serviceProcesses[service.id], "Stop must respond at level \(level)")
            try? FileManager.default.removeItem(at: marker)
        }
    }

    func testZoomPersistsClampsAndDoesNotChangeContentFont() throws {
        _ = NSApplication.shared
        let suite = "vsux.ZoomTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        let font = preferences.terminal.fontSize
        XCTAssertEqual(preferences.zoomPercentage, 100)
        preferences.adjustInterfaceZoom(by: 1)
        XCTAssertEqual(preferences.zoomFactor, 1.2, accuracy: 0.0001)
        XCTAssertEqual(Preferences(defaults: defaults).interfaceZoomLevel, 1)
        preferences.setInterfaceZoomLevel(99)
        XCTAssertEqual(preferences.interfaceZoomLevel, 8)
        preferences.setInterfaceZoomLevel(-99)
        XCTAssertEqual(preferences.interfaceZoomLevel, -8)
        preferences.setInterfaceZoomLevel(0)
        XCTAssertEqual(preferences.zoomFactor, 1)
        XCTAssertEqual(preferences.terminal.fontSize, font)
    }

    func testWholeWorkbenchScalesIconsLayoutAndTerminalWithoutRecreatingSession() async throws {
        _ = NSApplication.shared
        AppDelegate.shared.makeMenus()
        let preferences = Preferences.shared
        let original = preferences.interfaceZoomLevel
        preferences.setInterfaceZoomLevel(0)
        let controller = TerminalWindowController(model: WindowModel(shellCommand: "/bin/zsh -f"))
        let window = try XCTUnwrap(controller.window)
        AppDelegate.shared.windows.append(controller)
        window.makeKeyAndOrderFront(nil)
        defer {
            controller.model.disposeAll(); window.orderOut(nil)
            AppDelegate.shared.windows.removeAll { $0 === controller }
            preferences.setInterfaceZoomLevel(original)
        }
        let container = try XCTUnwrap(window.contentView as? WorkbenchHostingView<RootView>)
        try await settle()
        let terminal = try XCTUnwrap(controller.model.focusedTerminal)
        let surface = try XCTUnwrap(terminal.surface)
        let process = ghostty_surface_foreground_pid(surface)
        let frame = window.frame
        let font = preferences.terminal.fontSize
        let normalGrid = ghostty_surface_size(surface)
        let icon = try XCTUnwrap(regions(in: container.host).first { abs($0.bounds.width - 26) < 1 })
        let iconSize = icon.convert(icon.bounds, to: nil).size
        window.makeFirstResponder(terminal)
        press(window, key: "=", code: 24)
        try await settle()
        XCTAssertEqual(preferences.interfaceZoomLevel, 1)
        XCTAssertEqual(container.host.bounds.size, container.bounds.size,
                       "The hosting view keeps window coordinates; SwiftUI applies the content transform")
        XCTAssertEqual(icon.convert(icon.bounds, to: nil).width, iconSize.width * 1.2, accuracy: 1)
        let largeGrid = ghostty_surface_size(surface)
        XCTAssertEqual(try XCTUnwrap(terminal.layer).contentsScale,
                       terminal.convertToBacking(terminal.bounds).width / terminal.bounds.width, accuracy: 0.001,
                       "The IOSurface and Ghostty grid must use the same density to avoid double zoom")
        XCTAssertLessThan(largeGrid.columns, normalGrid.columns)
        XCTAssertGreaterThan(largeGrid.cell_width_px, normalGrid.cell_width_px)
        XCTAssertEqual(terminal.surface, surface)
        XCTAssertEqual(ghostty_surface_foreground_pid(surface), process)
        XCTAssertEqual(window.frame, frame)
        XCTAssertEqual(preferences.terminal.fontSize, font)

        // A real click on the transformed sidebar icon must hit the same action.
        let shown = controller.model.showSidebar
        let point = icon.convert(NSPoint(x: icon.bounds.midX, y: icon.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            window.sendEvent(event)
        }
        try await settle()
        XCTAssertEqual(controller.model.showSidebar, !shown)

        for level in [0, 1, 2, -1] {
            preferences.setInterfaceZoomLevel(level)
            try await settle()
            let bitmap = try XCTUnwrap(container.bitmapImageRepForCachingDisplay(in: container.bounds))
            container.cacheDisplay(in: container.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to:
                URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/workbench-zoom-\(level).png"))
        }
        press(window, key: "0", code: 29)
        try await settle()
        XCTAssertEqual(preferences.interfaceZoomLevel, 0)

        controller.model.showSettings = true
        try await settle()
        let sheet = try XCTUnwrap(window.attachedSheet)
        let settings = try XCTUnwrap(sheet.contentView)
        for level in [0, 1, 8] {
            preferences.setInterfaceZoomLevel(level)
            try await settle()
            XCTAssertLessThanOrEqual(sheet.frame.height, try XCTUnwrap(sheet.screen).visibleFrame.height)
            if level == 1 {
                let bitmap = try XCTUnwrap(settings.bitmapImageRepForCachingDisplay(in: settings.bounds))
                settings.cacheDisplay(in: settings.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to:
                    URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/workbench-zoom-settings.png"))
            }
        }
        window.endSheet(sheet)
        controller.model.showSettings = false
    }

    func testEditorAndPreviewUseTheSameScaleAndKeepSelectionAndDocument() async throws {
        _ = NSApplication.shared
        let preferences = Preferences.shared
        let original = preferences.interfaceZoomLevel
        preferences.setInterfaceZoomLevel(0)
        let source = "# Heading\n\nPreserved text"
        let document = LocalFileDocument(url: URL(fileURLWithPath: "/tmp/workbench-zoom.md"), text: source, data: Data(source.utf8), isPreview: false)
        let content = HStack {
            SyntaxEditor(document: document, onChange: { document.text = $0 }, onSave: {})
            MarkdownPreview(source: source, documentURL: document.url, rootURL: URL(fileURLWithPath: "/tmp"))
        }
        let container = WorkbenchHostingView(rootView: content)
        let window = PointerCursorWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = container; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); preferences.setInterfaceZoomLevel(original) }
        try await settle()
        let editor = try XCTUnwrap(find(CodeTextView.self, in: container))
        let preview = try XCTUnwrap(find(WKWebView.self, in: container))
        let selection = NSRange(location: 4, length: 3)
        editor.setSelectedRange(selection)
        let font = editor.font?.pointSize
        window.makeFirstResponder(editor)
        for level in [1, -1, 2, 0] {
            preferences.setInterfaceZoomLevel(level)
            try await settle()
            for view in [editor as NSView, preview] {
                XCTAssertEqual(view.convert(NSRect(x: 0, y: 0, width: 100, height: 100), to: nil).width,
                               preferences.zoomFactor * 100, accuracy: 0.01)
            }
            XCTAssertEqual(editor.font?.pointSize, font)
            XCTAssertEqual(editor.selectedRange(), selection)
            XCTAssertTrue(window.firstResponder === editor)
            XCTAssertEqual(document.text, source)
            XCTAssertFalse(document.isDirty)
        }
    }

    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        (view as? T) ?? view.subviews.lazy.compactMap { self.find(type, in: $0) }.first
    }

    private func regions(in view: NSView) -> [PointerCursorView] {
        (view as? PointerCursorView).map { [$0] } ?? view.subviews.flatMap { regions(in: $0) }
    }
    private func click(_ region: NSView, in window: NSWindow) throws {
        let point = region.convert(NSPoint(x: region.bounds.midX, y: region.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
        }
    }
    private func press(_ window: NSWindow, key: String, code: UInt16) {
        window.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: code)!)
    }
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(180))
        NSApp.windows.forEach { $0.contentView?.layoutSubtreeIfNeeded() }
        try await Task.sleep(for: .milliseconds(80))
    }
}
