import XCTest
import SwiftUI
import AppKit
import Vision
@testable import CmuxClone

@MainActor private final class CollapsibleSectionsFixtureState: ObservableObject {
    @Published var commandsExpanded = true
    @Published var servicesExpanded = true
}

@MainActor private struct CollapsibleSectionsFixture: View {
    @ObservedObject var state: CollapsibleSectionsFixtureState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Commands"); Spacer(); SectionDisclosureButton(title: "Commands", expanded: $state.commandsExpanded) }
            if state.commandsExpanded { Button("Command item") {}.pointingHandCursor() }
            HStack { Text("Services"); Spacer(); SectionDisclosureButton(title: "Services", expanded: $state.servicesExpanded) }
            if state.servicesExpanded { Button("Service item") {}.pointingHandCursor() }
        }.padding(12).frame(width: 360, alignment: .leading)
    }
}

final class ViewIntegrationTests: XCTestCase {
    @MainActor func testQuickTunnelControlsRenderInBothLanguages() throws {
        _ = NSApplication.shared
        let preferences = LanguagePreferences.shared
        let originalLanguage = preferences.language
        let originalDefault = UserDefaults.standard.object(forKey: "appLanguage")
        defer {
            preferences.language = originalLanguage
            if let originalDefault { UserDefaults.standard.set(originalDefault, forKey: "appLanguage") }
            else { UserDefaults.standard.removeObject(forKey: "appLanguage") }
        }

        let model = WindowModel()
        let workspace = try XCTUnwrap(model.workspace)
        let host = NSHostingView(rootView: CommandSidebar(model: model, library: .shared, workspace: workspace))
        let window = PointerCursorWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 520), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { model.disposeAll(); window.orderOut(nil) }

        for (language, expected) in [
            (AppLanguage.english, ["Quick Tunnel", "Local port", "Expose Port"]),
            (.chinese, ["公网隧道", "本地端口", "公开端口"])
        ] {
            preferences.language = language
            settle(); host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let image = try XCTUnwrap(bitmap.cgImage)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = language == .chinese ? ["zh-Hans", "en-US"] : ["en-US"]
            try VNImageRequestHandler(cgImage: image).perform([request])
            let rendered = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to:
                URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/quick-tunnel-\(language.catalogCode).png"))
            for text in expected {
                XCTAssertTrue(rendered.contains(text), "Missing \(text) in \(language.title): \(rendered)")
            }
        }
    }

    @MainActor func testCommandAndServiceSectionsCanBeCollapsedByClickingTheirDisclosureButtons() throws {
        _ = NSApplication.shared
        let state = CollapsibleSectionsFixtureState()
        let host = NSHostingView(rootView: CollapsibleSectionsFixture(state: state))
        let window = PointerCursorWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 160), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        func regions(_ view: NSView) -> [PointerCursorView] {
            (view as? PointerCursorView).map { [$0] } ?? view.subviews.flatMap { regions($0) }
        }
        func disclosureRegions() -> [PointerCursorView] {
            regions(host).filter { region in
                (27...30).contains(Int(region.bounds.width.rounded())) && (26...28).contains(Int(region.bounds.height.rounded()))
            }.sorted { $0.convert($0.bounds, to: nil).midY > $1.convert($1.bounds, to: nil).midY }
        }
        settle(); host.layoutSubtreeIfNeeded()
        XCTAssertEqual(disclosureRegions().count, 2, "服务和命令标题都应显示独立的折叠按钮")
        for (index, isExpanded) in [(0, { state.commandsExpanded }), (1, { state.servicesExpanded })] {
            let expandedCount = regions(host).count
            let button = try XCTUnwrap(disclosureRegions().dropFirst(index).first)
            window.makeKeyAndOrderFront(nil)
            try click(button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil), in: window)
            settle(); host.layoutSubtreeIfNeeded()
            XCTAssertFalse(isExpanded(), "点击箭头应切换对应分区的展开状态")
            XCTAssertLessThan(regions(host).count, expandedCount, "折叠分区后，其内容按钮应从视图树中移除")
            XCTAssertEqual(disclosureRegions().count, 2, "收起后仍应保留可再次展开的按钮")
            let collapsedCount = regions(host).count
            let disclosure = try XCTUnwrap(disclosureRegions().dropFirst(index).first)
            window.makeKeyAndOrderFront(nil)
            try click(disclosure.convert(NSPoint(x: disclosure.bounds.midX, y: disclosure.bounds.midY), to: nil), in: window)
            settle(); host.layoutSubtreeIfNeeded()
            XCTAssertTrue(isExpanded(), "再次点击箭头应展开对应分区")
            XCTAssertGreaterThan(regions(host).count, collapsedCount, "重新展开分区后，其内容按钮应重新出现")
        }
    }

    @MainActor func testFirstClickActivatesIconButtonInInactiveWindow() throws {
        _ = NSApplication.shared
        var activations = 0
        let window = PointerCursorWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: IconButton(symbol: "plus", help: "Action") { activations += 1 }.frame(maxWidth: .infinity, maxHeight: .infinity))
        window.contentView = host
        window.orderFront(nil)
        let otherWindow = NSWindow(contentRect: NSRect(x: 300, y: 0, width: 240, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        otherWindow.orderFrontRegardless()
        otherWindow.makeKey()
        defer { window.orderOut(nil); otherWindow.orderOut(nil) }
        settle(); host.layoutSubtreeIfNeeded()
        XCTAssertFalse(window.isKeyWindow)

        try click(NSPoint(x: 120, y: 60), in: window)

        XCTAssertEqual(activations, 1, "非活动窗口中的按钮第一次点击就应执行")
    }

    @MainActor func testSidebarButtonsRespondAcrossTheirWholeVisibleBounds() throws {
        _ = NSApplication.shared
        let tools = WorkspaceToolsState()
        let window = PointerCursorWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 41), styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: SidebarSectionPicker(tools: tools))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        settle(); host.layoutSubtreeIfNeeded()
        func regions(_ view: NSView) -> [PointerCursorView] {
            (view as? PointerCursorView).map { [$0] } ?? view.subviews.flatMap { regions($0) }
        }
        for width in [198.0, 360.0, 620.0] {
            window.setContentSize(NSSize(width: width, height: 41))
            settle(); host.layoutSubtreeIfNeeded()
            let buttons = regions(host).sorted { $0.convert(.zero, to: nil).x < $1.convert(.zero, to: nil).x }
            XCTAssertEqual(buttons.count, WorkspaceSidebarSection.allCases.count)
            for (index, section) in WorkspaceSidebarSection.allCases.enumerated() {
                guard buttons.indices.contains(index) else { return }
                let view = buttons[index]
                let rect = view.bounds
                let points = [NSPoint(x: rect.midX, y: rect.midY), NSPoint(x: 4, y: rect.midY),
                    NSPoint(x: rect.maxX - 4, y: rect.midY), NSPoint(x: rect.midX, y: 2), NSPoint(x: rect.midX, y: rect.maxY - 2)]
                for point in points {
                    tools.sidebar = section == .workspaces ? .files : .workspaces
                    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
                    try click(view.convert(point, to: nil), in: window)
                    XCTAssertEqual(tools.sidebar, section, "侧栏宽 \(width)，第 \(index + 1) 格 \(point) 必须一次点击即切换")
                }
            }
        }
    }

    @MainActor func testFileTabCloseButtonRespondsInsideItsPadding() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("sample.swift")
        try Data("let sample = 1\n".utf8).write(to: file)
        let model = FileWorkspaceModel(rootURL: root)
        let host = NSHostingView(rootView: FileEditorArea(model: model))
        let window = PointerCursorWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        func regions(_ view: NSView) -> [PointerCursorView] {
            (view as? PointerCursorView).map { [$0] } ?? view.subviews.flatMap { regions($0) }
        }
        for point in [NSPoint(x: 2, y: 2), NSPoint(x: 24, y: 36)] {
            model.open(file); settle(); host.layoutSubtreeIfNeeded()
            let close = try XCTUnwrap(regions(host).first { abs($0.bounds.width - 26) < 0.1 && abs($0.bounds.height - 38) < 0.1 })
            try click(close.convert(point, to: nil), in: window)
            let deadline = Date().addingTimeInterval(0.2)
            while !model.documents.isEmpty && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            XCTAssertTrue(model.documents.isEmpty, "关闭按钮在 \(point) 的留白不得变成只选中 Tab 的死区")
        }
    }

    @MainActor private func click(_ point: NSPoint, in window: NSWindow) throws {
        let timestamp = ProcessInfo.processInfo.systemUptime
        for (type, delay) in [(NSEvent.EventType.leftMouseDown, 0.0), (.leftMouseUp, 0.01)] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: timestamp + delay,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            NSApp.sendEvent(event)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    @MainActor func testEditorRulerDoesNotDrawThroughHeader() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("sample.md")
        try Data("# Sample\n\nText\n".utf8).write(to: file)
        let model = FileWorkspaceModel(rootURL: root)
        model.open(file)
        let host = NSHostingView(rootView: VStack(spacing: 0) {
            Color.white.frame(height: 80)
            FileEditorArea(model: model)
        }.environment(\.colorScheme, .light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; window.orderFront(nil)
        defer { window.orderOut(nil) }
        settle(); host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/editor-render.png")
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output)
        let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
        let background = try XCTUnwrap(bitmap.colorAt(x: Int(80 * scale), y: Int(20 * scale))?.usingColorSpace(.deviceRGB))
        for x in 45...52 {
            let pixel = try XCTUnwrap(bitmap.colorAt(x: Int(CGFloat(x) * scale), y: Int(20 * scale))?.usingColorSpace(.deviceRGB))
            XCTAssertEqual(pixel.redComponent, background.redComponent, accuracy: 0.02, "编辑器行号边线不得穿过上方标题区域")
        }
    }

    @MainActor func testMouseMovementActuallySetsHandCursor() throws {
        _ = NSApplication.shared
        let controller = TerminalWindowController(model: WindowModel(shellCommand: "/bin/zsh -f"))
        let window = try XCTUnwrap(controller.window)
        let state = CursorFixtureState()
        let host = NSHostingView(rootView: CursorFixture(state: state))
        window.contentView = host
        window.orderFront(nil)
        defer { controller.model.disposeAll(); window.orderOut(nil); NSCursor.arrow.set() }
        settle(); host.layoutSubtreeIfNeeded()
        func regions(_ view: NSView) -> [PointerCursorView] {
            (view as? PointerCursorView).map { [$0] } ?? view.subviews.flatMap { regions($0) }
        }
        let overlays = regions(host)
        let enabled = try XCTUnwrap(overlays.first { $0.isPointerEnabled })
        func move(to point: NSPoint) throws {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: point,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
            window.sendEvent(event)
        }
        NSCursor.arrow.set()
        for overlay in overlays where overlay.isPointerEnabled {
            for offset in [0.0, 1.0] {
                NSCursor.arrow.set() // Simulate a native hosting view replacing the cursor.
                try move(to: overlay.convert(NSPoint(x: overlay.bounds.midX + offset, y: overlay.bounds.midY), to: nil))
                XCTAssertEqual(NSCursor.current, NSCursor.pointingHand, "按钮和菜单内持续移动时都必须实际切成手型")
            }
        }
        let disabled = try XCTUnwrap(overlays.first { !$0.isPointerEnabled })
        try move(to: disabled.convert(NSPoint(x: disabled.bounds.midX, y: disabled.bounds.midY), to: nil))
        XCTAssertEqual(NSCursor.current, NSCursor.arrow, "禁用按钮必须恢复箭头")
        try move(to: enabled.convert(NSPoint(x: enabled.bounds.midX, y: enabled.bounds.midY), to: nil))
        try move(to: NSPoint(x: 2, y: 2))
        XCTAssertEqual(NSCursor.current, NSCursor.arrow, "离开可点击区域后不得残留手型")
        try move(to: enabled.convert(NSPoint(x: enabled.bounds.midX, y: enabled.bounds.midY), to: nil))
        state.disabled = true
        settle()
        XCTAssertEqual(NSCursor.current, NSCursor.arrow, "鼠标不动但按钮被禁用时也必须恢复箭头")
        state.disabled = false
        settle()
        XCTAssertEqual(NSCursor.current, NSCursor.pointingHand)
        NSCursor.iBeam.set()
        try move(to: NSPoint(x: 2, y: 2))
        XCTAssertEqual(NSCursor.current, NSCursor.iBeam, "不得覆盖文本区域自己的光标")

        let nested = NSHostingView(rootView:
            HStack {
                IconButton(symbol: "xmark", help: "禁用的关闭按钮") {}.disabled(true)
                Text("可点击行")
            }.padding(20).pointingHandCursor()
        )
        window.contentView = nested
        settle(); nested.layoutSubtreeIfNeeded()
        let nestedDisabled = try XCTUnwrap(regions(nested).first { !$0.isPointerEnabled })
        try move(to: nestedDisabled.convert(NSPoint(x: nestedDisabled.bounds.midX, y: nestedDisabled.bounds.midY), to: nil))
        XCTAssertEqual(NSCursor.current, NSCursor.arrow, "可点击父行不得覆盖内部禁用按钮的箭头")
        try move(to: NSPoint(x: 2, y: 2))
        XCTAssertEqual(NSCursor.current, NSCursor.pointingHand, "离开禁用子按钮后应恢复父行手型")
    }

    @MainActor func testPointerOverlayRespectsDisabledStateWithoutInterceptingInput() {
        _ = NSApplication.shared
        let state = CursorFixtureState()
        let host = NSHostingView(rootView: CursorFixture(state: state))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 180), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; window.orderFront(nil)
        defer { window.orderOut(nil) }
        settle(); host.layoutSubtreeIfNeeded()
        func regions(_ view: NSView) -> [PointerCursorView] {
            (view as? PointerCursorView).map { [$0] } ?? view.subviews.flatMap { regions($0) }
        }
        var overlays = regions(host)
        XCTAssertEqual(overlays.count, 3)
        XCTAssertEqual(overlays.filter(\.isPointerEnabled).count, 2)
        for overlay in overlays {
            XCTAssertGreaterThan(overlay.bounds.width, 0)
            XCTAssertNil(overlay.hitTest(NSPoint(x: overlay.bounds.midX, y: overlay.bounds.midY)), "手型覆盖层不得截获按钮或输入框的鼠标事件")
        }
        state.disabled = true
        settle(); host.layoutSubtreeIfNeeded()
        overlays = regions(host)
        XCTAssertEqual(overlays.filter(\.isPointerEnabled).count, 0, "禁用父区域后，按钮和菜单都不能继续显示手型")
        state.disabled = false
        settle(); host.layoutSubtreeIfNeeded()
        XCTAssertEqual(regions(host).filter(\.isPointerEnabled).count, 2)
    }

    @MainActor func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.35)) }
    @MainActor func testWorkspaceMovePreservesSurfaceAndReleasesDestinationDefaultShell() {
        _ = NSApplication.shared
        let source = TerminalWindowController(model: WindowModel(shellCommand: "/bin/zsh -f"))
        AppDelegate.shared.windows.append(source)
        source.showWindow(nil); settle()
        let pane = source.model.selectedTab!.focusedPane
        source.model.addLocalTab(pane); settle()
        let workspace = source.model.workspace!
        let terminal = source.model.focusedTerminal!
        let surface = terminal.surface
        AppDelegate.shared.moveWorkspace(workspace.id, from: source.model)
        settle()
        let destination = AppDelegate.shared.windows.first { $0 !== source && $0.model.workspaces.contains { $0.id == workspace.id } }!
        XCTAssertEqual(Set(destination.model.terminals.keys), Set([pane, terminal.paneID]))
        XCTAssertTrue(destination.model.focusedTerminal === terminal)
        XCTAssertEqual(terminal.surface, surface)
        XCTAssertTrue(terminal.window === destination.window)
        XCTAssertFalse(source.model.workspaces.contains { $0.id == workspace.id })
        for controller in [source, destination] { controller.model.disposeAll(); controller.window?.orderOut(nil) }
        AppDelegate.shared.windows.removeAll { $0 === source || $0 === destination }
    }
    @MainActor func testPaneLocalTabsSwitchExtractAndDispose() {
        _ = NSApplication.shared
        let model = WindowModel(shellCommand: "/bin/zsh -f")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
        model.window = window; window.contentView = NSHostingView(rootView: RootView(model: model)); window.orderFront(nil)
        defer { model.disposeAll(); window.orderOut(nil); settle() }
        settle()
        let pane = model.selectedTab!.focusedPane
        let original = model.focusedTerminal!
        model.addLocalTab(pane); settle()
        let second = model.focusedTerminal!
        XCTAssertEqual(model.localTabs(pane).count, 2)
        XCTAssertNotNil(second.surface)
        XCTAssertNil(original.window)
        model.selectLocalTab(original.paneID, pane: pane); settle()
        XCTAssertTrue(model.focusedTerminal === original)
        XCTAssertTrue(original.window === window)
        XCTAssertNil(second.window)
        model.reorderLocalTab(second.paneID, pane: pane, target: original.paneID)
        XCTAssertEqual(model.localTabs(pane).first?.id, second.paneID)
        // Extracting the original terminal must not confuse its ID with its old pane.
        model.extractLocalTab(original.paneID, pane: pane); settle()
        let extractedPane = model.selectedTab!.focusedPane
        XCTAssertNotEqual(extractedPane, pane)
        XCTAssertTrue(model.focusedTerminal === original)
        XCTAssertTrue(original.window === window)
        model.focus(original.paneID)
        XCTAssertEqual(model.selectedTab!.focusedPane, extractedPane)
        let views = Array(model.terminals.values)
        model.disposeAll(); settle()
        XCTAssertTrue(model.terminals.isEmpty)
        XCTAssertTrue(views.allSatisfy { $0.surface == nil })
    }
    @MainActor func testNativeHostsSurviveTabAndSplitSwitches() throws {
        _ = NSApplication.shared
        let model = WindowModel(shellCommand: "/bin/zsh -f")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 760), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        model.window = window
        let host = NSHostingView(rootView: RootView(model: model))
        window.contentView = host; window.orderFront(nil)
        defer { model.disposeAll(); window.orderOut(nil) }
        settle(); host.layoutSubtreeIfNeeded()
        let original = model.selectedTab!
        let terminal = model.terminals[original.focusedPane]!
        XCTAssertNotNil(terminal.surface)
        XCTAssertGreaterThan(terminal.bounds.width, 350)
        XCTAssertGreaterThan(terminal.bounds.height, 400)
        model.addTab(); settle()
        XCTAssertNil(terminal.window)
        model.selectTab(original.id); settle()
        XCTAssertTrue(terminal.window === window)
        XCTAssertTrue(model.focusedTerminal === terminal)
        model.split(.horizontal); settle(); host.layoutSubtreeIfNeeded()
        let second = model.focusedTerminal!
        XCTAssertTrue(second.window === window)
        XCTAssertTrue(terminal.window === window)
        XCTAssertGreaterThan(second.bounds.width, 150)
        XCTAssertLessThan(second.bounds.width, 600)
        model.zoom(second.paneID); settle()
        XCTAssertNil(terminal.window)
        model.zoom(second.paneID); settle()
        XCTAssertTrue(terminal.window === window)
        // Export our own view rendering for layout inspection, without capturing the desktop.
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let data = bitmap.representation(using: .png, properties: [:]) {
                let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/ui-preview.png")
                try data.write(to: output)
            }
        }
    }
}

@MainActor private final class CursorFixtureState: ObservableObject {
    @Published var disabled = false
}

private struct CursorFixture: View {
    @ObservedObject var state: CursorFixtureState
    var body: some View {
        VStack {
            IconButton(symbol: "plus", help: "添加") {}
            IconButton(symbol: "minus", help: "禁用按钮") {}.disabled(true)
            Menu { Button("操作") {} } label: { Text("菜单") }
                .menuStyle(.borderlessButton).pointingHandCursor()
            TextField("输入框", text: .constant(""))
        }.padding(20).disabled(state.disabled)
    }
}

