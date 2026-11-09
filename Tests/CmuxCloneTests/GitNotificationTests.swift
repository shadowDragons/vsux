import AppKit
import SwiftUI
import XCTest
@testable import CmuxClone

final class GitNotificationTests: XCTestCase {
    @MainActor func testNotificationPresentationInBothThemesAndLanguages() async throws {
        _ = NSApplication.shared
        let language = LanguagePreferences.shared
        let original = language.language
        let originalDefault = UserDefaults.standard.object(forKey: "appLanguage")
        defer {
            language.language = original
            if let originalDefault { UserDefaults.standard.set(originalDefault, forKey: "appLanguage") }
            else { UserDefaults.standard.removeObject(forKey: "appLanguage") }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NotificationRender-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("sample.swift")
        try Data("// Editing remains available while notifications are visible\nlet project = \"vsux\"\n".utf8).write(to: file)
        let workspace = Workspace(name: "Project", directory: root.path)
        let model = WindowModel(workspaces: [workspace], shellCommand: "/bin/zsh -f")
        model.tools.sidebar = .files; model.tools.content = .editor
        model.tools.files(workspace).open(file, preview: false)
        let store = model.tools.notifications
        store.post(detail: "fatal: unable to access remote repository\nSSL_ERROR_SYSCALL in connection to example.invalid:443",
            repository: root.appendingPathComponent("admin"), workspaceID: workspace.id, kind: .operation, canShowOutput: false)
        store.post(detail: "fatal: Could not resolve host: example.invalid", repository: root.appendingPathComponent("java"),
            workspaceID: workspace.id, kind: .fetch, severity: .warning, silent: true, canShowOutput: false)
        let host = NSHostingView(rootView: RootView(model: model))
        let window = PointerCursorWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); model.disposeAll() }
        for (mode, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            window.appearance = NSAppearance(named: appearance)
            for locale in [AppLanguage.chinese, .english] {
                language.language = locale
                for center in [false, true] {
                    store.isCenterVisible = center
                    try await Task.sleep(for: .milliseconds(80))
                    host.layoutSubtreeIfNeeded()
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let path = ".build/git-notification-\(mode)-\(locale.catalogCode)-\(center ? "center" : "toast").png"
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to:
                        URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(path))
                    XCTAssertEqual(store.notices.count, 2)
                    XCTAssertEqual(model.tools.files(workspace).selectedDocument?.text.contains("vsux"), true)
                }
            }
        }
    }

    @MainActor func testBackgroundFailureDeduplicatesByRepositoryAndRespectsDismissalUntilRecovery() throws {
        let store = GitNotificationStore()
        let workspace = UUID()
        let first = URL(fileURLWithPath: "/tmp/project/first"), second = URL(fileURLWithPath: "/tmp/project/second")
        for index in 0..<100 {
            store.post(detail: "Network failure \(index)", repository: first, workspaceID: workspace,
                kind: .fetch, severity: .warning, silent: true)
        }
        store.post(detail: "Offline", repository: second, workspaceID: workspace, kind: .fetch, severity: .warning, silent: true)
        XCTAssertEqual(store.warningCount, 2)
        XCTAssertTrue(store.toastIDs.isEmpty)
        let entry = try XCTUnwrap(store.notices.first { $0.repositoryURL == first })
        XCTAssertEqual(entry.occurrences, 100)
        XCTAssertEqual(entry.detail, "Network failure 99")
        store.dismiss(entry.id)
        store.post(detail: "Another network failure", repository: first, workspaceID: workspace, kind: .fetch, severity: .warning, silent: true)
        XCTAssertEqual(store.warningCount, 1, "Periodic retries must not recreate a dismissed warning")
        store.resolveBackgroundFetch(repository: first, workspaceID: workspace)
        store.post(detail: "New outage", repository: first, workspaceID: workspace, kind: .fetch, severity: .warning, silent: true)
        XCTAssertEqual(store.warningCount, 2)
        store.resolveBackgroundFetch(repository: first, workspaceID: workspace)
        XCTAssertEqual(store.notices.map(\.repositoryURL), [second])
        store.clearAll()
        XCTAssertEqual(store.warningCount, 0)
    }

    @MainActor func testToastExpiresWithoutLosingDetailsAndPausesForInteractionOrInactiveApplication() throws {
        let store = GitNotificationStore()
        let root = URL(fileURLWithPath: "/tmp/project")
        store.post(detail: "fatal: failed\nfull error output", repository: root, workspaceID: nil, kind: .operation)
        let notice = try XCTUnwrap(store.notices.first)
        store.advanceToasts(by: 14, appIsActive: true)
        XCTAssertEqual(store.toastIDs, [notice.id])
        store.advanceToasts(by: 60, appIsActive: false)
        store.protectToast(notice.id, true)
        store.advanceToasts(by: 60, appIsActive: true)
        XCTAssertEqual(store.toastIDs, [notice.id])
        store.protectToast(notice.id, false)
        store.advanceToasts(by: 1, appIsActive: true)
        XCTAssertTrue(store.toasts.isEmpty)
        XCTAssertEqual(store.errorCount, 1)
        XCTAssertEqual(store.notices.first?.detail, "fatal: failed\nfull error output")
        store.showCenter(select: notice.id)
        XCTAssertTrue(store.isCenterVisible)
        XCTAssertEqual(store.selectedNoticeID, notice.id)
        store.dismiss(notice.id)
        XCTAssertEqual(store.errorCount, 0)
    }

    @MainActor func testToastAndHistoryLimitsAndWindowIsolation() {
        let first = GitNotificationStore(), second = GitNotificationStore()
        for index in 0..<120 {
            first.post(detail: "Failure \(index)", repository: URL(fileURLWithPath: "/tmp/repo"), workspaceID: nil, kind: .operation)
        }
        XCTAssertEqual(first.notices.count, 100)
        XCTAssertEqual(first.toasts.count, 3)
        XCTAssertTrue(second.notices.isEmpty)
        first.showCenter()
        XCTAssertTrue(first.toasts.isEmpty)
        first.post(detail: "While viewing history", repository: URL(fileURLWithPath: "/tmp/repo"), workspaceID: nil, kind: .operation)
        XCTAssertTrue(first.toasts.isEmpty)
        XCTAssertEqual(first.notices.first?.summary, "While viewing history")
    }

    @MainActor func testNativeClicksOpenCenterDismissAndLeaveContentUsable() async throws {
        _ = NSApplication.shared
        let store = GitNotificationStore()
        store.post(detail: "fatal: SSL connection failed\nLonger error output remains available in details.",
            repository: URL(fileURLWithPath: "/tmp/admin"), workspaceID: UUID(), kind: .operation)
        var contentClicks = 0
        let host = NSHostingView(rootView: VStack(spacing: 0) {
            VStack {
                Button { contentClicks += 1 } label: { Text("Content action").frame(width: 160, height: 44) }
                    .buttonStyle(.plain).pointingHandCursor()
                Spacer()
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay { GitNotificationOverlay(store: store, showOutput: { _ in }) }
            Divider()
            GitNotificationStatusBar(store: store)
        }.background(Color(nsColor: .windowBackgroundColor)))
        let window = PointerCursorWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(150))
        func regions(_ view: NSView) -> [PointerCursorView] {
            (view as? PointerCursorView).map { [$0] } ?? view.subviews.flatMap { regions($0) }
        }
        func click(_ region: PointerCursorView) throws {
            let point = region.convert(NSPoint(x: region.bounds.midX, y: region.bounds.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                NSApp.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: 1)))
            }
        }
        host.layoutSubtreeIfNeeded()
        // Blank areas of the notification overlay must pass clicks through to the content.
        let content = try XCTUnwrap(regions(host).first { abs($0.bounds.width - 160) < 0.1 && abs($0.bounds.height - 44) < 0.1 })
        try click(content)
        XCTAssertEqual(contentClicks, 1)
        let status = try XCTUnwrap(regions(host).first { abs($0.bounds.height - 24) < 0.1 && $0.convert(.zero, to: nil).x < 20 })
        try click(status)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(store.isCenterVisible)
        XCTAssertTrue(store.toasts.isEmpty)
        XCTAssertEqual(store.errorCount, 1)
        host.layoutSubtreeIfNeeded()
        // The lower of the two 26x26 controls clears the row; the other hides the center.
        let closeControls = regions(host).filter { abs($0.bounds.width - 26) < 0.1 && abs($0.bounds.height - 26) < 0.1 }
        let dismiss = try XCTUnwrap(closeControls.min { $0.convert(.zero, to: nil).y < $1.convert(.zero, to: nil).y })
        try click(dismiss)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(store.errorCount, 0)
        XCTAssertTrue(store.notices.isEmpty)
    }
}
