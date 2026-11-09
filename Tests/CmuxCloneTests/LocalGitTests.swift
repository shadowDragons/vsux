import Foundation
import AppKit
import SwiftUI
import XCTest
import Combine
@testable import CmuxClone

final class LocalGitTests: XCTestCase {
    @MainActor func testDiscardFilePreservesStagingAndOtherRepositoryAndClearsDiff() async throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("DiscardFile-" + UUID().uuidString)
        let first = try GitFixture(root: workspace.appendingPathComponent("first"))
        let second = try GitFixture(root: workspace.appendingPathComponent("second"))
        defer { try? FileManager.default.removeItem(at: workspace) }
        for fixture in [first, second] {
            try fixture.write("file.txt", "base\n")
            try fixture.write("deleted.txt", "restore me\n")
            _ = try fixture.git(["add", "."])
            _ = try fixture.git(["commit", "-m", "base"])
            try fixture.write("file.txt", "staged\n")
            _ = try fixture.git(["add", "file.txt"])
            try fixture.write("file.txt", "unstaged\n")
        }
        try FileManager.default.removeItem(at: second.root.appendingPathComponent("deleted.txt"))
        let model = SourceControlModel(directory: workspace)
        await model.refresh()
        model.selectRepository(second.root)
        let change = try XCTUnwrap(model.unstaged.first { $0.path == "file.txt" })
        await model.showDiff(change, staged: false)
        XCTAssertTrue(model.diffText.contains("+unstaged"))
        model.commitMessage = "keep draft"

        _ = NSApplication.shared
        let panel = NSHostingView(rootView: SourceControlPanel(model: model, openFile: { _ in }, showDiff: {}))
        panel.frame = NSRect(x: 0, y: 0, width: 360, height: 520)
        for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            panel.appearance = NSAppearance(named: appearance)
            panel.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(panel.bitmapImageRepForCachingDisplay(in: panel.bounds))
            panel.cacheDisplay(in: panel.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to:
                URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/git-discard-\(name).png"))
        }

        // The captured repository must win even if selection changed after confirmation.
        model.selectRepository(first.root)
        await model.discard(change, in: second.root)
        XCTAssertNil(model.error)
        XCTAssertEqual(try first.read("file.txt"), "unstaged\n")
        XCTAssertEqual(try second.read("file.txt"), "staged\n")
        XCTAssertEqual(try second.git(["show", ":file.txt"]), "staged\n")
        XCTAssertEqual(model.staged.first { $0.path == "file.txt" }?.status, "M ")
        XCTAssertEqual(model.commitMessage, "keep draft")
        XCTAssertEqual(model.diffText, L("选择一个变更文件以查看差异。"))
        XCTAssertFalse(model.diffLoading)

        let deleted = try XCTUnwrap(model.unstaged.first { $0.path == "deleted.txt" })
        await model.discard(deleted, in: second.root)
        XCTAssertEqual(try second.read("deleted.txt"), "restore me\n")
        XCTAssertTrue(model.unstaged.isEmpty)
        // A stale action must not discard a file that is now only staged.
        await model.discard(change, in: second.root)
        XCTAssertEqual(try second.read("file.txt"), "staged\n")
        XCTAssertEqual(try second.git(["show", ":file.txt"]), "staged\n")
    }

    @MainActor func testGitFailuresUseNotificationsAndBackgroundRecoveryClearsWarning() async throws {
        let fixture = try GitFixture()
        let remote = fixture.root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".git")
        defer { fixture.remove(); try? FileManager.default.removeItem(at: remote) }
        try fixture.write("seed.txt", "base\n")
        _ = try fixture.git(["add", "."])
        _ = try fixture.git(["commit", "-m", "base"])
        _ = try fixture.git(["remote", "add", "origin", remote.path])
        let notices = GitNotificationStore()
        let workspaceID = UUID()
        let model = SourceControlModel(directory: fixture.root, notifications: notices, workspaceID: workspaceID)
        await model.refresh()
        let original = model.snapshot
        model.commitMessage = "draft must remain"
        await model.refreshRemoteStatuses()
        XCTAssertEqual(notices.warningCount, 1)
        XCTAssertEqual(notices.errorCount, 0)
        XCTAssertTrue(notices.toasts.isEmpty)
        XCTAssertEqual(notices.notices.first?.workspaceID, workspaceID)
        XCTAssertEqual(notices.notices.first?.repositoryURL.path, fixture.root.path)
        XCTAssertTrue(notices.notices.first?.canShowOutput == true)
        XCTAssertEqual(model.snapshot, original)
        XCTAssertEqual(model.commitMessage, "draft must remain")
        XCTAssertFalse(model.isBusy)
        XCTAssertTrue(model.fetchingRemotePaths.isEmpty)
        _ = try fixture.git(["init", "--bare", remote.path])
        await model.refreshRemoteStatuses(force: true)
        XCTAssertTrue(notices.notices.isEmpty, "A successful Fetch clears its previous warning")
        await model.switchBranch("does-not-exist", in: fixture.root)
        XCTAssertEqual(notices.errorCount, 1)
        XCTAssertEqual(notices.toasts.count, 1)
        XCTAssertEqual(notices.notices.first?.kind, .operation)
        XCTAssertEqual(model.snapshot?.branch, "main")
        await model.showGitOutput()
        XCTAssertTrue(model.diffText.contains("does-not-exist"))
        XCTAssertEqual(model.commitMessage, "draft must remain")
    }

    func testDiffDoesNotExecuteRepositoryTextConverter() async throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }
        try fixture.write(".gitattributes", "*.txt diff=audit\n")
        try fixture.write("file.txt", "before\n")
        try fixture.git(["add", "."])
        try fixture.git(["commit", "-m", "fixture"])
        try fixture.write("converter.sh", "#!/bin/sh\ntouch converter-ran\ncat \"$1\"\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.root.appendingPathComponent("converter.sh").path)
        try fixture.git(["config", "diff.audit.textconv", "./converter.sh"])
        try fixture.write("file.txt", "after\n")
        let repository = try await fixture.repository()
        let unstaged = try await repository.diff(path: "file.txt")
        XCTAssertTrue(unstaged.contains("+after"))
        try await repository.stage(paths: ["file.txt"])
        let staged = try await repository.diff(path: "file.txt", staged: true)
        XCTAssertTrue(staged.contains("+after"))
        try fixture.write("untracked.txt", "new\n")
        let untracked = try await repository.diff(path: "untracked.txt")
        XCTAssertTrue(untracked.contains("+new"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("converter-ran").path))
        // Control: the same fixture executes the converter without our policy.
        try fixture.git(["diff", "--cached", "--no-ext-diff", "--", "file.txt"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("converter-ran").path))
    }

    func testSnapshotDoesNotExecuteRepositoryFilesystemMonitor() async throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }
        try fixture.write("file.txt", "content\n")
        try fixture.git(["add", "file.txt"])
        try fixture.write("monitor.sh", "#!/bin/sh\ntouch monitor-ran\nprintf 'token\\000'\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.root.appendingPathComponent("monitor.sh").path)
        try fixture.git(["config", "core.fsmonitor", "./monitor.sh"])
        let repository = try await fixture.repository()
        let snapshot = try await repository.snapshot()
        XCTAssertTrue(snapshot.changes.contains { $0.path == "file.txt" })
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("monitor-ran").path))
        try fixture.git(["status", "--porcelain"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("monitor-ran").path))
    }

    @MainActor func testMergePickerSearchAndReturnMergesIntoItsOwnRepository() async throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("MergePicker-" + UUID().uuidString)
        let first = try GitFixture(root: workspace.appendingPathComponent("first"))
        let fixture = try GitFixture(root: workspace.appendingPathComponent("second"))
        defer { try? FileManager.default.removeItem(at: workspace) }
        for repo in [first, fixture] {
            try repo.write("file.txt", "base\n")
            _ = try repo.git(["add", "."])
            _ = try repo.git(["commit", "-m", "base"])
        }
        _ = try fixture.git(["tag", "feature"])
        _ = try fixture.git(["switch", "-c", "feature"])
        try fixture.write("file.txt", "merged from picker\n")
        _ = try fixture.git(["commit", "-am", "unique searchable commit"])
        _ = try fixture.git(["switch", "main"])
        for index in 0..<40 { _ = try fixture.git(["branch", "backup/\(index)"]) }
        _ = try fixture.git(["update-ref", "refs/remotes/origin/feature", "refs/heads/feature"])
        let repository = try await fixture.repository()
        let snapshot = try await repository.snapshot()
        let model = SourceControlModel(directory: workspace)
        await model.refresh()
        model.selectRepository(first.root)
        XCTAssertEqual(model.snapshot?.rootURL.path, first.root.path)

        _ = NSApplication.shared
        let window = PointerCursorWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560), styleMask: [.titled], backing: .buffered, defer: false)
        let menuHost = NSHostingView(rootView: RepositoryActionsMenu(model: model, repository: snapshot, showDetails: {}).frame(width: 720, height: 560))
        window.contentView = menuHost; window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(100))
        menuHost.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
        let popup = try XCTUnwrap(descendants(menuHost).compactMap { $0 as? NSPopUpButton }.first)
        // Menu tracking uses its own run-loop mode; a main-queue callback can starve here.
        let closeMenu = Timer(timeInterval: 0.2, repeats: true) { _ in popup.menu?.cancelTrackingWithoutAnimation() }
        RunLoop.main.add(closeMenu, forMode: .eventTracking)
        popup.performClick(nil)
        closeMenu.invalidate()
        let menu = try XCTUnwrap(popup.menu)
        defer { window.orderOut(nil) }
        let branchMenu = try XCTUnwrap(menu.items.first { $0.title == L("Branch（分支）") }?.submenu)
        XCTAssertEqual(branchMenu.items.first?.title, L("Merge…（合并分支）"))
        XCTAssertEqual(branchMenu.items.dropFirst().first?.title, L("Rebase…（变基）"))
        XCTAssertNil(try XCTUnwrap(menu.items.first { $0.title == L("Checkout to…（切换到）") }).submenu)
        branchMenu.performActionForItem(at: 0)
        let sheetDeadline = Date().addingTimeInterval(4)
        while window.attachedSheet == nil && Date() < sheetDeadline { try await Task.sleep(for: .milliseconds(25)) }
        let sheet = try XCTUnwrap(window.attachedSheet, "Merge must open the searchable picker")
        let host = try XCTUnwrap(sheet.contentView)
        try await Task.sleep(for: .milliseconds(400))
        host.layoutSubtreeIfNeeded()
        for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            sheet.appearance = NSAppearance(named: appearance)
            try await Task.sleep(for: .milliseconds(50))
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to:
                URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/merge-branch-picker-\(name).png"))
        }
        func fields(_ view: NSView) -> [NSTextField] {
            (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { fields($0) }
        }
        let input = try XCTUnwrap(fields(host).first(where: \.isEditable))
        sheet.makeFirstResponder(input)
        let editor = try XCTUnwrap(input.currentEditor() as? NSTextView)
        editor.insertText("unique searchable commit", replacementRange: NSRange(location: 0, length: 0))
        try await Task.sleep(for: .milliseconds(100))
        // The two matching local/remote refs remain; Return uses the selected local ref.
        NSApp.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: sheet.windowNumber,
            context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)))
        let deadline = Date().addingTimeInterval(8)
        while try fixture.read("file.txt") != "merged from picker\n" && Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertNil(model.error)
        XCTAssertEqual(try fixture.read("file.txt"), "merged from picker\n")
        XCTAssertEqual(try first.read("file.txt"), "base\n")
        XCTAssertEqual(try fixture.git(["branch", "--show-current"]).trimmingCharacters(in: .whitespacesAndNewlines), "main")
    }

    @MainActor func testPublishBranchFillsComposerAndRowIconPublishesWithNativeClick() async throws {
        let fixture = try GitFixture()
        let remote = fixture.root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".git")
        defer { fixture.remove(); try? FileManager.default.removeItem(at: remote) }
        try fixture.write("seed.txt", "base\n")
        _ = try fixture.git(["add", "seed.txt"])
        _ = try fixture.git(["commit", "-m", "seed"])
        _ = try fixture.git(["init", "--bare", remote.path])
        _ = try fixture.git(["remote", "add", "origin", remote.path])
        let model = SourceControlModel(directory: fixture.root)
        await model.refresh()
        _ = NSApplication.shared
        func regions(_ view: NSView) -> [PointerCursorView] {
            (view as? PointerCursorView).map { [$0] } ?? view.subviews.flatMap { regions($0) }
        }
        for prominent in [true, false] {
            if !prominent {
                _ = try fixture.git(["checkout", "-b", "row-publish"])
                await model.refreshRepository(fixture.root)
            }
            let snapshot = try XCTUnwrap(model.snapshot)
            XCTAssertTrue(snapshot.canPublishBranch)
            let window = PointerCursorWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 40), styleMask: [.titled], backing: .buffered, defer: false)
            let host = NSHostingView(rootView: GitSyncActions(model: model, repository: snapshot, prominent: prominent))
            window.contentView = host; window.makeKeyAndOrderFront(nil)
            defer { window.orderOut(nil) }
            for width in [260.0, 360.0, 620.0] {
                window.setContentSize(NSSize(width: width, height: 40))
                try await Task.sleep(for: .milliseconds(50))
                host.layoutSubtreeIfNeeded()
                let button = try XCTUnwrap(regions(host).first)
                XCTAssertEqual(button.bounds.width, prominent ? width : 24, accuracy: 1)
                XCTAssertEqual(button.bounds.height, prominent ? 32 : 28, accuracy: 1)
            }
            let button = try XCTUnwrap(regions(host).first)
            // Click the far edge of the visible primary button, not just its text.
            let point = button.convert(NSPoint(x: button.bounds.maxX - 3, y: button.bounds.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                NSApp.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)))
            }
            let deadline = Date().addingTimeInterval(8)
            while model.snapshot?.canPublishBranch == true && Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
            XCTAssertNil(model.error)
            XCTAssertEqual(model.snapshot?.tracking?.upstream, prominent ? "origin/main" : "origin/row-publish")
        }

        _ = try fixture.git(["checkout", "-b", "preview"])
        // Multiple remotes use the same full-width label and open a remote picker.
        _ = try fixture.git(["remote", "add", "backup", remote.path])
        await model.refreshRepository(fixture.root)
        let picker = NSHostingView(rootView: GitSyncActions(model: model, repository: try XCTUnwrap(model.snapshot), prominent: true))
        for width in [260.0, 360.0, 620.0] {
            picker.frame = NSRect(x: 0, y: 0, width: width, height: 40)
            picker.layoutSubtreeIfNeeded()
            let control = try XCTUnwrap(regions(picker).first)
            XCTAssertEqual(control.bounds.width, width, accuracy: 1)
            XCTAssertEqual(control.bounds.height, 32, accuracy: 1, "Remote picker must keep the primary button height")
        }
        let panel = NSHostingView(rootView: SourceControlPanel(model: model, openFile: { _ in }, showDiff: {}))
        for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            panel.appearance = NSAppearance(named: appearance)
            panel.frame = NSRect(x: 0, y: 0, width: 360, height: 480)
            panel.layoutSubtreeIfNeeded()
            if let bitmap = panel.bitmapImageRepForCachingDisplay(in: panel.bounds) {
                panel.cacheDisplay(in: panel.bounds, to: bitmap)
                if let data = bitmap.representation(using: .png, properties: [:]) {
                    try data.write(to: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/git-publish-\(name).png"))
                }
            }
        }
    }

    @MainActor func testPushPullCountsAndDirectActionsHonorDifferentlyNamedUpstream() async throws {
        let fixture = try GitFixture()
        let peer = try GitFixture()
        let remote = fixture.root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".git")
        defer { fixture.remove(); peer.remove(); try? FileManager.default.removeItem(at: remote) }
        _ = try fixture.git(["config", "user.name", "Local Git Test"])
        _ = try fixture.git(["config", "user.email", "local-test@example.invalid"])
        _ = try fixture.git(["init", "--bare", "--initial-branch=published", remote.path])
        try fixture.write("seed.txt", "base\n")
        _ = try fixture.git(["add", "seed.txt"])
        _ = try fixture.git(["commit", "-m", "seed"])
        _ = try fixture.git(["remote", "add", "origin", remote.path])
        _ = try fixture.git(["push", "--set-upstream", "origin", "main:refs/heads/published"])
        _ = try peer.git(["remote", "add", "origin", remote.path])
        _ = try peer.git(["fetch", "origin"])
        _ = try peer.git(["checkout", "-B", "main", "origin/published"])
        let model = SourceControlModel(directory: fixture.root)
        await model.refresh()
        func clickSyncAction(push: Bool, until complete: () -> Bool) async throws {
            _ = NSApplication.shared
            let state = try XCTUnwrap(model.snapshot)
            let window = PointerCursorWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 40), styleMask: [.titled], backing: .buffered, defer: false)
            let host = NSHostingView(rootView: GitSyncActions(model: model, repository: state, prominent: true))
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            defer { window.orderOut(nil) }
            try await Task.sleep(for: .milliseconds(70))
            host.layoutSubtreeIfNeeded()
            func regions(_ view: NSView) -> [PointerCursorView] {
                (view as? PointerCursorView).map { [$0] } ?? view.subviews.flatMap { regions($0) }
            }
            let buttons = regions(host).sorted { $0.convert(.zero, to: nil).x < $1.convert(.zero, to: nil).x }
            XCTAssertEqual(buttons.count, 2)
            let button = try XCTUnwrap(buttons.indices.contains(push ? 1 : 0) ? buttons[push ? 1 : 0] : nil)
            let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                NSApp.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)))
            }
            let deadline = Date().addingTimeInterval(8)
            while !complete() && Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
            XCTAssertTrue(complete(), "A native click must execute the requested Git action")
        }
        XCTAssertEqual(model.snapshot?.tracking?.ahead, 0)
        XCTAssertEqual(model.snapshot?.tracking?.behind, 0)
        XCTAssertFalse(model.snapshot?.hasSyncChanges ?? true)
        try fixture.write("local.txt", "local change\n")
        await model.refreshRepository(fixture.root)
        model.commitMessage = "local commit"
        await model.requestCommit(in: fixture.root)
        XCTAssertEqual(model.snapshot?.tracking?.ahead, 1, "Commit refresh must immediately expose pending push")
        XCTAssertEqual(model.snapshot?.tracking?.behind, 0)
        XCTAssertTrue(model.snapshot?.changes.isEmpty == true)
        try await clickSyncAction(push: true) { model.snapshot?.tracking?.ahead == 0 }
        XCTAssertNil(model.error)
        XCTAssertEqual(model.snapshot?.tracking?.ahead, 0)
        XCTAssertEqual(model.snapshot?.tracking?.upstream, "origin/published")
        XCTAssertEqual(try fixture.git(["--git-dir", remote.path, "branch", "--list", "main"]), "", "Push must not create a new same-named remote branch")
        let peerRepository = try await peer.repository()
        try await peerRepository.perform(.pull(rebase: false))
        try peer.write("remote.txt", "remote change\n")
        try await peerRepository.stage(paths: ["remote.txt"])
        try await peerRepository.commit(message: "remote commit")
        try await peerRepository.perform(.pushUpstream)
        model.commitMessage = "keep draft"
        var becameBusy = false
        let subscription = model.$isBusy.dropFirst().sink { becameBusy = becameBusy || $0 }
        await model.refreshRemoteStatuses(force: true)
        subscription.cancel()
        XCTAssertFalse(becameBusy, "Fetching counts must not disable the whole sidebar")
        XCTAssertEqual(model.commitMessage, "keep draft")
        XCTAssertEqual(model.snapshot?.tracking?.behind, 1)
        XCTAssertEqual(model.snapshot?.tracking?.ahead, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("remote.txt").path), "Background fetch must not pull files")
        try await clickSyncAction(push: false) { model.snapshot?.tracking?.behind == 0 }
        XCTAssertNil(model.error)
        XCTAssertEqual(try fixture.read("remote.txt"), "remote change\n")
        XCTAssertEqual(model.snapshot?.tracking?.behind, 0)

        // Divergence displays both directions; direct actions must never force
        // push, silently merge, or discard either side of history.
        try fixture.write("local-only.txt", "local\n")
        await model.refreshRepository(fixture.root)
        model.commitMessage = "local divergent commit"
        await model.requestCommit(in: fixture.root)
        try peer.write("remote-only.txt", "remote\n")
        try await peerRepository.stage(paths: ["remote-only.txt"])
        try await peerRepository.commit(message: "remote divergent commit")
        try await peerRepository.perform(.pushUpstream)
        await model.refreshRemoteStatuses(force: true)
        XCTAssertEqual(model.snapshot?.tracking?.ahead, 1)
        XCTAssertEqual(model.snapshot?.tracking?.behind, 1)
        let localHead = try fixture.git(["rev-parse", "HEAD"])
        await model.perform(.pushUpstream, in: fixture.root)
        XCTAssertNotNil(model.error)
        await model.perform(.pull(rebase: false), in: fixture.root)
        XCTAssertNotNil(model.error)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), localHead)
        XCTAssertEqual(model.snapshot?.tracking?.ahead, 1)
        XCTAssertEqual(model.snapshot?.tracking?.behind, 1)

        // Render the actual sidebar with both counters and prominent actions.
        model.error = nil
        _ = NSApplication.shared
        let host = NSHostingView(rootView: SourceControlPanel(model: model, openFile: { _ in }, showDiff: {}))
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 650)
        host.layoutSubtreeIfNeeded()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let data = bitmap.representation(using: .png, properties: [:]) {
                try data.write(to: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/git-sync-preview.png"))
            }
        }
        let unavailable = remote.appendingPathExtension("offline")
        try FileManager.default.moveItem(at: remote, to: unavailable)
        defer { try? FileManager.default.moveItem(at: unavailable, to: remote) }
        await model.refreshRemoteStatuses(force: true)
        XCTAssertEqual(model.snapshot?.tracking?.ahead, 1)
        XCTAssertEqual(model.snapshot?.tracking?.behind, 1)
        XCTAssertNotNil(model.error)
        XCTAssertEqual(model.notifications.notices.first?.kind, .fetch)
        XCTAssertTrue(model.fetchingRemotePaths.isEmpty)
        XCTAssertFalse(model.isBusy)
    }

    func testMissingUpstreamDetachedAndDeletedRemoteRefDoNotInventCounts() async throws {
        let fixture = try GitFixture()
        let remote = fixture.root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".git")
        defer { fixture.remove(); try? FileManager.default.removeItem(at: remote) }
        let repo = try await fixture.repository()
        var state = try await repo.snapshot()
        XCTAssertNil(state.tracking)
        try fixture.write("seed.txt", "seed\n")
        try await repo.stage(paths: ["seed.txt"])
        try await repo.commit(message: "seed")
        _ = try fixture.git(["init", "--bare", remote.path])
        try await repo.perform(.addRemote("origin", remote.path))
        state = try await repo.snapshot()
        XCTAssertNil(state.tracking)
        XCTAssertTrue(state.canPublishBranch)
        await expectFailure { try await repo.perform(.pushUpstream) }
        try await repo.perform(.push("origin", tags: false))
        _ = try fixture.git(["update-ref", "-d", "refs/remotes/origin/main"])
        state = try await repo.snapshot()
        XCTAssertNotNil(state.tracking)
        XCTAssertNil(state.tracking?.ahead)
        XCTAssertNil(state.tracking?.behind)
        XCTAssertFalse(state.hasSyncChanges)
        _ = try fixture.git(["checkout", "--detach"])
        state = try await repo.snapshot()
        XCTAssertNil(state.tracking)
        XCTAssertFalse(state.canPublishBranch)
    }

    func testGuiCommitLoadsShellToolchainAndRunsPreCommitHook() async throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }
        let tools = fixture.root.appendingPathComponent("toolchain with spaces")
        let config = fixture.root.appendingPathComponent("shell-config")
        let hooks = fixture.root.appendingPathComponent(".husky")
        for directory in [tools, config, hooks] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let npm = tools.appendingPathComponent("npm")
        try Data("#!/bin/sh\nprintf hook-ran > hook-result\n".utf8).write(to: npm)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: npm.path)
        try Data("print startup-noise\nexport PATH='\(tools.path)':$PATH\n".utf8).write(to: config.appendingPathComponent(".zshrc"))
        let hook = hooks.appendingPathComponent("pre-commit")
        try Data("#!/bin/sh\nset -e\nnpm test\n".utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        _ = try fixture.git(["config", "core.hooksPath", hooks.path])
        var overrides = fixture.environment
        overrides["HOME"] = fixture.root.path
        let resolver = ShellEnvironment(base: ["HOME": fixture.root.path, "ZDOTDIR": config.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/zsh"], shell: URL(fileURLWithPath: "/bin/zsh"))
        let repository = LocalGitRepository(rootURL: fixture.root, environment: overrides, shellEnvironment: resolver)
        try fixture.write("code.txt", "change\n")
        try await repository.stage(paths: ["code.txt"])
        try await repository.commit(message: "with hook")
        XCTAssertEqual(try fixture.read("hook-result"), "hook-ran")
        XCTAssertEqual(try fixture.git(["log", "-1", "--format=%s"]), "with hook\n")
        // A genuine check failure must still reject a commit; never bypass hooks.
        let head = try fixture.git(["rev-parse", "HEAD"])
        try Data("#!/bin/sh\necho 'check rejected' >&2\nexit 3\n".utf8).write(to: npm)
        try fixture.write("code.txt", "second change\n")
        try await repository.stage(paths: ["code.txt"])
        await expectFailure { try await repository.commit(message: "must fail") }
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        let snapshot = try await repository.snapshot()
        XCTAssertTrue(snapshot.changes.contains { $0.path == "code.txt" && $0.isStaged })
        let log = await repository.outputLog()
        XCTAssertTrue(log.contains("check rejected"))
    }

    @MainActor func testCommitButtonIsEnabledForUnstagedChangesWithMessage() async throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }
        try fixture.write("intake.vue", "<template>updated</template>\n")
        let model = SourceControlModel(directory: fixture.root)
        await model.refresh()
        model.commitMessage = "更新"
        XCTAssertTrue(model.staged.isEmpty)
        XCTAssertEqual(model.unstaged.count, 1)
        XCTAssertTrue(model.canCommit, "提交按钮应允许直接提交未暂存的更改")
        XCTAssertFalse(model.canCommitStaged)
        model.commitMessage = " \n "
        XCTAssertFalse(model.canCommit)
    }

    @MainActor func testPrimaryCommitAutomaticallyStagesAndCommitsOnlySelectedRepository() async throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let first = try GitFixture(root: workspace.appendingPathComponent("first"))
        let second = try GitFixture(root: workspace.appendingPathComponent("second"))
        // Model discovery uses normal local Git configuration; set identity only in the fixture.
        _ = try first.git(["config", "user.name", "Local Git Test"])
        _ = try first.git(["config", "user.email", "local-test@example.invalid"])
        try first.write("intake.vue", "updated\n")
        try second.write("other.txt", "other repository\n")
        let model = SourceControlModel(directory: workspace)
        await model.refresh()
        model.selectRepository(first.root)
        model.commitMessage = "更新"
        await model.requestCommit(in: first.root)
        XCTAssertEqual(try first.git(["log", "-1", "--format=%s"]).trimmingCharacters(in: .whitespacesAndNewlines), "更新")
        XCTAssertTrue(try first.git(["status", "--porcelain"]).isEmpty)
        XCTAssertTrue(model.commitMessage.isEmpty)
        XCTAssertFalse(model.canCommit)
        XCTAssertEqual(try second.git(["diff", "--cached"]), "")
        XCTAssertFalse(try second.git(["status", "--porcelain"]).isEmpty)
        XCTAssertNil(model.error)
    }

    @MainActor func testPrimaryCommitWithStagedChangesKeepsOtherChangesUnstaged() async throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }
        _ = try fixture.git(["config", "user.name", "Local Git Test"])
        _ = try fixture.git(["config", "user.email", "local-test@example.invalid"])
        try fixture.write("staged.txt", "staged\n")
        try fixture.write("unstaged.txt", "leave this alone\n")
        _ = try fixture.git(["add", "staged.txt"])
        let model = SourceControlModel(directory: fixture.root)
        await model.refresh()
        model.commitMessage = "index only"
        XCTAssertTrue(model.canCommitStaged)
        await model.requestCommit(in: fixture.root)
        XCTAssertEqual(try fixture.git(["ls-tree", "--name-only", "HEAD"]), "staged.txt\n")
        XCTAssertEqual(model.unstaged.map(\.path), ["unstaged.txt"])
        XCTAssertTrue(model.staged.isEmpty)
        XCTAssertNil(model.error)
    }

    @MainActor func testBranchDirtyMarkerTracksUntrackedStagedModifiedAndCommittedFiles() async throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }
        let model = SourceControlModel(directory: fixture.root)
        await model.refresh()
        XCTAssertEqual(model.snapshot?.branchDisplayName, "main")
        try fixture.write("file.txt", "initial\n")
        await model.refreshRepository(fixture.root)
        XCTAssertEqual(model.snapshot?.branchDisplayName, "main*")
        await model.stage(model.unstaged)
        XCTAssertTrue(model.unstaged.isEmpty)
        XCTAssertEqual(model.snapshot?.branchDisplayName, "main*", "Staged changes remain uncommitted")
        // Commit using isolated fixture credentials; refresh through the same row action.
        _ = try fixture.git(["commit", "-m", "initial"])
        await model.refreshRepository(fixture.root)
        XCTAssertEqual(model.snapshot?.branchDisplayName, "main")
        try fixture.write("file.txt", "modified\n")
        await model.refreshRepository(fixture.root)
        XCTAssertEqual(model.snapshot?.branchDisplayName, "main*")
        _ = try fixture.git(["restore", "file.txt"])
        await model.refreshRepository(fixture.root)
        XCTAssertEqual(model.snapshot?.branchDisplayName, "main")
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("file.txt"))
        await model.refreshRepository(fixture.root)
        XCTAssertEqual(model.snapshot?.branchDisplayName, "main*")
        _ = try fixture.git(["restore", "file.txt"])
        _ = try fixture.git(["checkout", "--detach"])
        try fixture.write("file.txt", "detached changes\n")
        await model.refreshRepository(fixture.root)
        XCTAssertEqual(model.snapshot?.branchDisplayName, "HEAD*")
        XCTAssertNil(model.snapshot?.branch, "The marker must never change the branch used by Git operations")
        XCTAssertNil(model.error)
    }

    @MainActor func testRepositoryRefreshOnlyUpdatesRequestedRepository() async throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("GitRowRefresh-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let first = try GitFixture(root: workspace.appendingPathComponent("first", isDirectory: true))
        let second = try GitFixture(root: workspace.appendingPathComponent("second", isDirectory: true))
        let model = SourceControlModel(directory: workspace)
        await model.refresh()
        model.selectRepository(first.root)
        model.commitMessage = "draft"
        try first.write("first.txt", "first\n")
        try second.write("second.txt", "second\n")
        _ = try GitFixture(root: workspace.appendingPathComponent("third", isDirectory: true))
        var becameBusy = false
        let subscription = model.$isBusy.dropFirst().sink { becameBusy = becameBusy || $0 }
        await model.refreshRepository(second.root)
        subscription.cancel()
        XCTAssertFalse(becameBusy)
        XCTAssertTrue(model.refreshingRepositoryPaths.isEmpty)
        XCTAssertEqual(model.repositories.count, 2)
        XCTAssertEqual(model.snapshot?.rootURL.path, first.root.path)
        XCTAssertEqual(model.commitMessage, "draft")
        XCTAssertTrue(model.unstaged.isEmpty)
        XCTAssertEqual(model.snapshot?.branchDisplayName, "main")
        XCTAssertEqual(model.repositories.first { $0.rootURL.path == second.root.path }?.branchDisplayName, "main*")
        model.selectRepository(second.root)
        XCTAssertEqual(model.unstaged.map(\.path), ["second.txt"])
        XCTAssertNil(model.error)
    }

    @MainActor func testActivationRefreshDoesNotLockPanelOrRescanWorkspace() async throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("GitActivation-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let first = try GitFixture(root: workspace.appendingPathComponent("first"))
        let second = try GitFixture(root: workspace.appendingPathComponent("second"))
        let model = SourceControlModel(directory: workspace)
        await model.refresh()
        model.selectRepository(second.root)
        model.commitMessage = "保留未完成的提交说明"
        try second.write("external.txt", "written while minimized\n")
        _ = try GitFixture(root: workspace.appendingPathComponent("new-repository"))
        var activationLockedPanel = false
        let subscription = model.$isBusy.dropFirst().sink { busy in
            activationLockedPanel = activationLockedPanel || busy
        }
        await model.refreshOnActivation()
        withExtendedLifetime(subscription) {}
        XCTAssertFalse(activationLockedPanel, "恢复窗口的后台刷新不应禁用 Git 面板或显示阻塞进度")
        XCTAssertEqual(model.repositories.count, 2, "恢复窗口只刷新已知仓库，不重新递归遍历工作区")
        XCTAssertEqual(model.snapshot?.rootURL.path, second.root.path)
        XCTAssertEqual(model.commitMessage, "保留未完成的提交说明")
        XCTAssertEqual(model.unstaged.map(\.path), ["external.txt"])
        subscription.cancel()
        model.selectRepository(first.root)
        XCTAssertEqual(model.snapshot?.rootURL.path, first.root.path)
        model.selectRepository(second.root)
        XCTAssertEqual(model.commitMessage, "保留未完成的提交说明")
        await model.showGitOutput()
        let outputBeforeRepeatedActivation = model.diffText
        await model.refreshOnActivation()
        await model.showGitOutput()
        XCTAssertEqual(model.diffText, outputBeforeRepeatedActivation, "连续恢复/激活事件应合并，避免重复读取 Git")
        await model.loadIfNeeded()
        XCTAssertEqual(model.repositories.count, 2, "重建面板时应复用已加载的仓库")
        // Explicit refresh remains the way to discover newly added child repositories.
        await model.refresh()
        XCTAssertEqual(model.repositories.count, 3)
    }

    @MainActor func testActivationKeepsCachedRepositoryOnReadFailure() async throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }
        let model = SourceControlModel(directory: fixture.root)
        await model.refresh()
        let previous = model.repositories
        model.commitMessage = "draft"
        let gitDirectory = fixture.root.appendingPathComponent(".git")
        let unavailable = fixture.root.appendingPathComponent("git-temporarily-unavailable")
        try FileManager.default.moveItem(at: gitDirectory, to: unavailable)
        defer { try? FileManager.default.moveItem(at: unavailable, to: gitDirectory) }
        await model.refreshOnActivation()
        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(model.repositories, previous)
        XCTAssertEqual(model.commitMessage, "draft")
        XCTAssertNotNil(model.error)
    }

    func testCheckoutPickerReferencesAndCreateFromSelectedBase() async throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }
        let repository = try await fixture.repository()
        let empty = try await repository.checkoutReferences()
        XCTAssertTrue(empty.isEmpty)
        try fixture.write("seed.txt", "base\n")
        try await repository.stage(paths: ["seed.txt"])
        try await repository.commit(message: "初始提交")
        let base = try await repository.snapshot().head
        _ = try fixture.git(["tag", "-a", "发布/v1", "-m", "release annotation"])
        _ = try fixture.git(["update-ref", "refs/remotes/origin/main", "HEAD"])
        _ = try fixture.git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"])
        try await repository.checkout(branch: "开发/测试", create: true)
        try fixture.write("seed.txt", "feature\n")
        try await repository.stage(paths: ["seed.txt"])
        try await repository.commit(message: "开发提交")
        let refs = try await repository.checkoutReferences()
        XCTAssertEqual(Set(refs.map(\.name)), ["main", "开发/测试", "origin/main", "发布/v1"])
        let tag = try XCTUnwrap(refs.first { $0.kind == .tag })
        XCTAssertEqual(tag.subject, "初始提交")
        XCTAssertNotNil(tag.timestamp)
        XCTAssertFalse(tag.author.isEmpty)
        XCTAssertEqual(tag.shortHash, String(try XCTUnwrap(base).prefix(tag.shortHash.count)))
        try await repository.checkout(branch: "从主分支创建", create: true, startPoint: "refs/heads/main")
        XCTAssertEqual(try fixture.read("seed.txt"), "base\n")
        try await repository.perform(.checkoutDetached("refs/tags/发布/v1"))
        let detached = try await repository.snapshot()
        XCTAssertNil(detached.branch)
        XCTAssertEqual(detached.head, base)
        await expectFailure { try await repository.perform(.checkoutDetached("--force")) }
        await expectFailure { try await repository.checkout(branch: "bad-base", create: true, startPoint: "missing-ref") }
        XCTAssertFalse(try fixture.git(["branch", "--list", "bad-base"]).contains("bad-base"))
    }

    @MainActor func testCheckoutFromRepositoryRowTargetsThatRepositoryAndPreservesDirtyFiles() async throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("CheckoutPicker-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let first = try GitFixture(root: workspace.appendingPathComponent("first"))
        let second = try GitFixture(root: workspace.appendingPathComponent("second"))
        for fixture in [first, second] {
            try fixture.write("file.txt", "base\n")
            _ = try fixture.git(["add", "."])
            _ = try fixture.git(["commit", "-m", "base"])
            _ = try fixture.git(["branch", "feature"])
        }
        _ = try second.git(["switch", "feature"])
        try second.write("file.txt", "feature\n")
        _ = try second.git(["commit", "-am", "feature change"])
        _ = try second.git(["switch", "main"])
        let model = SourceControlModel(directory: workspace)
        await model.refresh()
        model.selectRepository(first.root)
        let refs = try await model.checkoutReferences(in: second.root)
        XCTAssertTrue(refs.contains { $0.name == "feature" })
        await model.switchBranch("feature", in: second.root)
        XCTAssertEqual(model.snapshot?.branch, "feature")
        XCTAssertEqual(try first.git(["branch", "--show-current"]).trimmingCharacters(in: .whitespacesAndNewlines), "main")
        await model.switchBranch("main", in: second.root)
        try second.write("file.txt", "uncommitted user edit\n")
        await model.switchBranch("feature", in: second.root)
        XCTAssertNotNil(model.error)
        XCTAssertEqual(model.snapshot?.branch, "main")
        XCTAssertEqual(try second.read("file.txt"), "uncommitted user edit\n")
    }

    func testDiscoversRepositoryFromNestedFolderAndHandlesUnbornIndex() async throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }
        let nested = fixture.root.appendingPathComponent("nested/folder", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let repository = try await fixture.repository(at: nested)
        let initial = try await repository.snapshot()
        XCTAssertEqual(initial.rootURL.resolvingSymlinksInPath(), fixture.root.resolvingSymlinksInPath())
        XCTAssertEqual(initial.branch, "main")
        XCTAssertNil(initial.head)
        XCTAssertTrue(initial.changes.isEmpty)

        try fixture.write("new.txt", "new contents\n")
        try await repository.stage(paths: ["new.txt"])
        var snapshot = try await repository.snapshot()
        XCTAssertEqual(snapshot.changes.first?.status, "A ")
        XCTAssertTrue(snapshot.changes.first?.isStaged == true)
        XCTAssertFalse(snapshot.changes.first?.isUnstaged == true)
        try fixture.write("new.txt", "newer working tree\n")
        try await repository.unstage(paths: ["new.txt"])
        snapshot = try await repository.snapshot()
        XCTAssertEqual(snapshot.changes.first?.status, "??")
        XCTAssertTrue(snapshot.changes.first?.isUntracked == true)
        XCTAssertTrue(snapshot.changes.first?.isUnstaged == true)
        XCTAssertEqual(try fixture.read("new.txt"), "newer working tree\n")
    }

    func testDiscoversMultipleRepositoriesInsideWorkspaceIncludingWorktrees() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("CmuxLocalGitWorkspace-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let mini = try GitFixture(root: workspace.appendingPathComponent("mini", isDirectory: true))
        let opsBackend = try GitFixture(root: workspace.appendingPathComponent("services/ops-backend", isDirectory: true))
        try mini.write("seed.txt", "committed\n")
        _ = try mini.git(["add", "seed.txt"])
        _ = try mini.git(["commit", "-m", "seed"])

        let linkedWorktree = workspace.appendingPathComponent("linked-worktree", isDirectory: true)
        _ = try mini.git(["worktree", "add", "--detach", linkedWorktree.path])
        XCTAssertTrue(try String(contentsOf: linkedWorktree.appendingPathComponent(".git"), encoding: .utf8).hasPrefix("gitdir:"))

        try mini.write("mini-change.txt", "mini\n")
        try opsBackend.write("ops-change.txt", "ops\n")

        let repositories = try await LocalGitRepository.discoverAll(in: workspace, environment: mini.environment)
        let roots = repositories.map { $0.rootURL.standardizedFileURL.path }
        XCTAssertEqual(Set(roots), Set([mini.root.path, opsBackend.root.path, linkedWorktree.path]))
        XCTAssertEqual(roots.count, 3)

        let snapshots = try await repositories.asyncMap { try await $0.snapshot() }
        let changesByRoot = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.rootURL.standardizedFileURL.path, Set($0.changes.map(\.path))) })
        XCTAssertEqual(changesByRoot[mini.root.path], ["mini-change.txt"])
        XCTAssertEqual(changesByRoot[opsBackend.root.path], ["ops-change.txt"])
        XCTAssertEqual(changesByRoot[linkedWorktree.path], [])
    }

    func testRepositoryDiscoverySkipsDependencyContainersButKeepsProjectRepositories() async throws {
        let workspace = try GitFixture()
        defer { workspace.remove() }
        // Reproduce SwiftPM checkouts, plus common dependencies at multiple depths.
        for path in [".build/checkouts/swift-markdown", ".build/checkouts/swift-cmark",
                     "web/node_modules/dependency", "ios/Pods/dependency",
                     "ios/DerivedData/checkouts/dependency", ".swiftpm/checkouts/dependency",
                     "api/.venv/dependency", "api/venv/dependency", ".gradle/dependency",
                     "__pycache__/dependency", ".cache/dependency", "web/.next/dependency",
                     "web/.nuxt/dependency", ".turbo/dependency", ".dart_tool/dependency",
                     "ios/Carthage/Checkouts/dependency"] {
            _ = try GitFixture(root: workspace.root.appendingPathComponent(path, isDirectory: true))
        }
        let service = try GitFixture(root: workspace.root.appendingPathComponent("services/api", isDirectory: true))
        let hiddenProject = try GitFixture(root: workspace.root.appendingPathComponent(".projects/tool", isDirectory: true))
        let vendorProject = try GitFixture(root: workspace.root.appendingPathComponent("vendor/library", isDirectory: true))
        let repositories = try await LocalGitRepository.discoverAll(in: workspace.root, environment: workspace.environment)
        XCTAssertEqual(Set(repositories.map { $0.rootURL.path }),
                       [workspace.root.path, service.root.path, hiddenProject.root.path, vendorProject.root.path])

        // Users can still intentionally open a dependency repository as a workspace.
        let dependency = workspace.root.appendingPathComponent(".build/checkouts/swift-markdown", isDirectory: true)
        let explicit = try await LocalGitRepository.discoverAll(in: dependency, environment: workspace.environment)
        XCTAssertEqual(explicit.map { $0.rootURL.path }, [dependency.path])
        let namedWorkspace = try GitFixture(root: workspace.root.appendingPathComponent("node_modules", isDirectory: true))
        let explicitNamed = try await LocalGitRepository.discoverAll(in: namedWorkspace.root, environment: workspace.environment)
        XCTAssertEqual(explicitNamed.map { $0.rootURL.path }, [namedWorkspace.root.path])
    }

    func testFindsEnclosingAndNestedRepositoriesWithoutFollowingSymlinks() async throws {
        let parent = try GitFixture()
        let outside = try GitFixture()
        defer { parent.remove(); outside.remove() }
        let workspace = parent.root.appendingPathComponent("workspace", isDirectory: true)
        let child = try GitFixture(root: workspace.appendingPathComponent("nested/repository", isDirectory: true))
        try FileManager.default.createSymbolicLink(at: workspace.appendingPathComponent("outside-link"), withDestinationURL: outside.root)
        try FileManager.default.createSymbolicLink(at: workspace.appendingPathComponent("loop"), withDestinationURL: workspace)
        let repositories = try await LocalGitRepository.discoverAll(in: workspace, environment: parent.environment)
        XCTAssertEqual(Set(repositories.map { $0.rootURL.path }), [parent.root.path, child.root.path])
    }

    @MainActor func testWorkspaceRepositorySelectionKeepsChangesAndOperationsSeparate() async throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("CmuxLocalGitSelection-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let mini = try GitFixture(root: workspace.appendingPathComponent("mini", isDirectory: true))
        let ops = try GitFixture(root: workspace.appendingPathComponent("ops-backend", isDirectory: true))
        try mini.write("same.txt", "mini content\n")
        try ops.write("same.txt", "ops content\n")
        let model = SourceControlModel(directory: workspace)
        await model.refresh()
        XCTAssertNil(model.error)
        XCTAssertEqual(model.repositories.count, 2)
        model.selectRepository(mini.root)
        model.commitMessage = "mini draft"
        let change = try XCTUnwrap(model.unstaged.first)
        await model.showDiff(change, staged: false)
        XCTAssertTrue(model.diffText.contains("+mini content"))
        await model.stage([change])
        XCTAssertEqual(model.staged.map(\.path), ["same.txt"])

        model.selectRepository(ops.root)
        XCTAssertTrue(model.commitMessage.isEmpty)
        XCTAssertTrue(model.staged.isEmpty)
        XCTAssertEqual(model.unstaged.map(\.path), ["same.txt"])
        XCTAssertFalse(model.diffText.contains("mini content"))
        model.commitMessage = "ops draft"
        await model.showDiff(try XCTUnwrap(model.unstaged.first), staged: false)
        XCTAssertTrue(model.diffText.contains("+ops content"))
        await model.refresh()
        XCTAssertEqual(model.snapshot?.rootURL, ops.root)
        XCTAssertEqual(model.commitMessage, "ops draft")
        model.selectRepository(mini.root)
        XCTAssertEqual(model.commitMessage, "mini draft")
        XCTAssertEqual(model.staged.map(\.path), ["same.txt"])
        XCTAssertEqual(try ops.git(["diff", "--cached"]), "")

        // Exercise the actual SwiftUI list and export our own panel for visual QA.
        _ = NSApplication.shared
        let host = NSHostingView(rootView: SourceControlPanel(model: model, openFile: { _ in }, showDiff: {}))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 760)
        host.layoutSubtreeIfNeeded()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let data = bitmap.representation(using: .png, properties: [:]) {
                let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/git-repositories-preview.png")
                try data.write(to: output)
            }
        }
    }

    func testCommitIncludesOnlyIndexAndDiffUsesCorrectLayer() async throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }
        let repository = try await fixture.repository()
        try fixture.write("code.swift", "let value = 1\n")
        try await repository.stage(paths: ["code.swift"])
        try await repository.commit(message: "initial")
        try fixture.write("code.swift", "let value = 2\n")
        try await repository.stage(paths: ["code.swift"])
        try fixture.write("code.swift", "let value = 3\n")
        let staged = try await repository.diff(path: "code.swift", staged: true)
        let working = try await repository.diff(path: "code.swift")
        XCTAssertTrue(staged.contains("+let value = 2"))
        XCTAssertTrue(working.contains("+let value = 3"))
        let mixed = try await repository.snapshot()
        XCTAssertEqual(mixed.changes.first?.status, "MM")
        try await repository.commit(message: "index only")
        XCTAssertEqual(try fixture.git(["show", "HEAD:code.swift"]), "let value = 2\n")
        let after = try await repository.snapshot()
        XCTAssertEqual(after.changes.first?.status, " M")
        XCTAssertFalse(after.changes.first?.isStaged == true)
        XCTAssertTrue(after.changes.first?.isUnstaged == true)
    }

    func testNullSeparatedPathsAndLiteralPathspecsArePreserved() async throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }
        let repository = try await fixture.repository()
        let names = ["space name.swift", "中文\nline.txt", ":(glob)*", "--option"]
        for name in names { try fixture.write(name, "contents of \(name)\n") }
        let initial = try await repository.snapshot()
        XCTAssertEqual(Set(initial.changes.map(\.path)), Set(names))
        try await repository.stage(paths: [":(glob)*"])
        let selective = try await repository.snapshot()
        XCTAssertEqual(selective.changes.filter(\.isStaged).map(\.path), [":(glob)*"])
        XCTAssertEqual(selective.changes.filter(\.isUntracked).count, 3)
        try await repository.stage(paths: names)
        try await repository.commit(message: "special filenames")
        let clean = try await repository.snapshot()
        XCTAssertTrue(clean.changes.isEmpty)
        try fixture.write("中文\nline.txt", "modified unicode\n")
        try await repository.stage(paths: ["中文\nline.txt"])
        try await repository.unstage(paths: ["中文\nline.txt"])
        let unicodeChange = try await repository.snapshot()
        XCTAssertEqual(unicodeChange.changes.first?.path, "中文\nline.txt")
    }

    func testRenameCanBeUnstagedWithoutLosingSourceRemovalOrContents() async throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }
        let repository = try await fixture.repository()
        try fixture.write("before name.txt", "unchanged contents\n")
        try await repository.stage(paths: ["before name.txt"])
        try await repository.commit(message: "seed")
        _ = try fixture.git(["mv", "--", "before name.txt", "after\nname.txt"])
        let renamed = try await repository.snapshot()
        XCTAssertEqual(renamed.changes.count, 1)
        XCTAssertEqual(renamed.changes.first?.path, "after\nname.txt")
        XCTAssertEqual(renamed.changes.first?.previousPath, "before name.txt")
        try await repository.unstage(paths: ["after\nname.txt"])
        let unstaged = try await repository.snapshot()
        XCTAssertTrue(unstaged.changes.allSatisfy { !$0.isStaged })
        XCTAssertEqual(Set(unstaged.changes.map(\.path)), ["before name.txt", "after\nname.txt"])
        XCTAssertEqual(try fixture.read("after\nname.txt"), "unchanged contents\n")
    }

    func testLocalBranchesAndConflictsAreReported() async throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }
        let repository = try await fixture.repository()
        try fixture.write("conflict.txt", "base\n")
        try await repository.stage(paths: ["conflict.txt"])
        try await repository.commit(message: "seed")
        try await repository.checkout(branch: "feature", create: true)
        try fixture.write("conflict.txt", "feature\n")
        try await repository.stage(paths: ["conflict.txt"])
        try await repository.commit(message: "feature")
        try await repository.checkout(branch: "main")
        try fixture.write("conflict.txt", "main\n")
        try await repository.stage(paths: ["conflict.txt"])
        try await repository.commit(message: "main")
        _ = try fixture.git(["merge", "feature"], allowFailure: true)
        let conflicted = try await repository.snapshot()
        XCTAssertEqual(conflicted.branch, "main")
        XCTAssertEqual(Set(conflicted.branches), ["main", "feature"])
        XCTAssertEqual(conflicted.changes.first?.status, "UU")
        XCTAssertTrue(conflicted.changes.first?.isConflicted == true)
    }

    func testUntrackedDiffAndValidationFailures() async throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }
        let repository = try await fixture.repository()
        try fixture.write("new.txt", "new content\n")
        let diff = try await repository.diff(path: "new.txt")
        XCTAssertTrue(diff.contains("+new content"))
        await expectFailure { try await repository.stage(paths: ["../outside"]) }
        await expectFailure { try await repository.stage(paths: ["/tmp/outside"]) }
        await expectFailure { try await repository.commit(message: " \n ") }
        await expectFailure { try await repository.checkout(branch: "--force") }
        await expectFailure { try await repository.checkout(branch: "does-not-exist") }
        let outside = fixture.root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        await expectFailure { _ = try await LocalGitRepository.discover(at: outside, environment: fixture.environment) }
    }

    func testRemoteOperationsRoundTripThroughLocalBareRepository() async throws {
        let fixture = try GitFixture()
        let remote = fixture.root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".git")
        let clone = fixture.root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { fixture.remove(); try? FileManager.default.removeItem(at: remote); try? FileManager.default.removeItem(at: clone) }
        _ = try fixture.git(["init", "--bare", "--initial-branch=main", remote.path])
        let repository = try await fixture.repository()
        try fixture.write("shared.txt", "version 1\n")
        try await repository.stage(paths: ["shared.txt"])
        try await repository.commit(message: "seed")
        try await repository.perform(.addRemote("origin", remote.path))
        try await repository.perform(.renameRemote("origin", "backup"))
        try await repository.perform(.setRemoteURL("backup", remote.path))
        let url = try await repository.remoteURL("backup")
        XCTAssertEqual(url, remote.path)
        try await repository.perform(.push("backup", tags: false))

        let cloned = try await LocalGitRepository.clone(from: remote.path, to: clone, environment: fixture.environment)
        let clonedSnapshot = try await cloned.snapshot()
        XCTAssertEqual(clonedSnapshot.remoteBranches, ["origin/main"])
        XCTAssertEqual(try String(contentsOf: clone.appendingPathComponent("shared.txt"), encoding: .utf8), "version 1\n")
        try fixture.write("shared.txt", "version 2\n")
        try await repository.stage(paths: ["shared.txt"])
        try await repository.commit(message: "second")
        try await repository.perform(.push("backup", tags: false))
        try await cloned.perform(.fetch("origin"))
        try await cloned.perform(.fetchAll)
        try await cloned.perform(.pull(rebase: false))
        XCTAssertEqual(try String(contentsOf: clone.appendingPathComponent("shared.txt"), encoding: .utf8), "version 2\n")

        try Data("from clone\n".utf8).write(to: clone.appendingPathComponent("shared.txt"))
        try await cloned.stage(paths: ["shared.txt"])
        try await cloned.commit(message: "clone commit")
        try await cloned.perform(.push("origin", tags: false))
        try await repository.perform(.pull(rebase: true))
        XCTAssertEqual(try fixture.read("shared.txt"), "from clone\n")
        try await repository.perform(.createTag("v1.0"))
        try await repository.perform(.push("backup", tags: true))
        XCTAssertTrue(try fixture.git(["--git-dir", remote.path, "show-ref", "refs/tags/v1.0"]).contains("refs/tags/v1.0"))
        try await repository.perform(.removeRemote("backup"))
        let final = try await repository.snapshot()
        XCTAssertTrue(final.remotes.isEmpty)
        let log = await repository.outputLog()
        XCTAssertTrue(log.contains("git push"))
        await expectFailure { try await repository.perform(.addRemote("--bad", remote.path)) }
        await expectFailure { try await repository.perform(.addRemote("bad", "ext::sh -c something")) }
        await expectFailure { _ = try await LocalGitRepository.clone(from: "--upload-pack=bad", to: clone, environment: fixture.environment) }
    }

    func testStashTagAndWorktreeMenusHaveRealOperations() async throws {
        let fixture = try GitFixture()
        let worktree = fixture.root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { fixture.remove(); try? FileManager.default.removeItem(at: worktree) }
        let repository = try await fixture.repository()
        try fixture.write("tracked.txt", "seed\n")
        try await repository.stage(paths: ["tracked.txt"])
        try await repository.commit(message: "initial")
        try fixture.write("tracked.txt", "work in progress\n")
        try fixture.write("untracked.txt", "new\n")
        try await repository.perform(.saveStash("menu test"))
        var snapshot = try await repository.snapshot()
        XCTAssertTrue(snapshot.changes.isEmpty)
        XCTAssertEqual(snapshot.stashes.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("untracked.txt").path))
        try await repository.perform(.applyStash("stash@{0}", pop: false))
        XCTAssertEqual(try fixture.read("untracked.txt"), "new\n")
        try await repository.perform(.saveStash("second stash"))
        try await repository.perform(.dropStash("stash@{1}"))
        try await repository.perform(.applyStash("stash@{0}", pop: true))
        snapshot = try await repository.snapshot()
        XCTAssertTrue(snapshot.stashes.isEmpty)
        XCTAssertEqual(try fixture.read("tracked.txt"), "work in progress\n")
        try await repository.perform(.discardTracked(["tracked.txt"]))
        XCTAssertEqual(try fixture.read("tracked.txt"), "seed\n")

        try await repository.perform(.createTag("release/test"))
        snapshot = try await repository.snapshot()
        XCTAssertEqual(snapshot.tags, ["release/test"])
        try await repository.perform(.checkoutTag("release/test"))
        snapshot = try await repository.snapshot()
        XCTAssertNil(snapshot.branch)
        try await repository.checkout(branch: "main")
        try await repository.perform(.deleteTag("release/test"))
        try await repository.perform(.addWorktree(worktree))
        snapshot = try await repository.snapshot()
        XCTAssertTrue(snapshot.worktrees.contains(where: { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == worktree.resolvingSymlinksInPath().path && $0.branch == nil }), "\(snapshot.worktrees)")
        XCTAssertTrue(snapshot.worktrees.contains(where: { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == fixture.root.resolvingSymlinksInPath().path && $0.branch == "main" }), "\(snapshot.worktrees)")
        try Data("dirty\n".utf8).write(to: worktree.appendingPathComponent("tracked.txt"))
        await expectFailure { try await repository.perform(.removeWorktree(worktree)) }
        try Data("seed\n".utf8).write(to: worktree.appendingPathComponent("tracked.txt"))
        try await repository.perform(.removeWorktree(worktree))
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree.path))
        await expectFailure { try await repository.perform(.removeWorktree(fixture.root)) }
        await expectFailure { try await repository.perform(.createTag("--invalid")) }
    }

    func testBranchRenameMergeAndCommitAmendUndo() async throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }
        let repository = try await fixture.repository()
        try fixture.write("file.txt", "one\n")
        try await repository.stage(paths: ["file.txt"])
        try await repository.commit(message: "initial")
        try await repository.commit(message: "amended", amend: true)
        let history = try await repository.history()
        XCTAssertTrue(history.contains("amended"))
        XCTAssertFalse(history.contains("initial"))
        try await repository.checkout(branch: "feature", create: true)
        try await repository.perform(.renameBranch("feature", "renamed"))
        try fixture.write("file.txt", "two\n")
        try await repository.stage(paths: ["file.txt"])
        try await repository.commit(message: "feature commit")
        try await repository.checkout(branch: "main")
        try await repository.perform(.mergeBranch("renamed"))
        XCTAssertEqual(try fixture.read("file.txt"), "two\n")
        try await repository.perform(.deleteBranch("renamed"))
        try await repository.perform(.undoCommit)
        let snapshot = try await repository.snapshot()
        XCTAssertEqual(snapshot.branches, ["main"])
        XCTAssertEqual(snapshot.changes.first?.status, "M ")
        XCTAssertEqual(try fixture.read("file.txt"), "two\n")
    }

    private func expectFailure(_ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected a Git error", file: file, line: line) }
        catch { XCTAssertFalse(error.localizedDescription.isEmpty, file: file, line: line) }
    }
}

private final class GitFixture {
    let root: URL
    let environment: [String: String]

    init(root: URL? = nil) throws {
        self.root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("CmuxLocalGitTests-" + UUID().uuidString, isDirectory: true)
        environment = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0", "GIT_AUTHOR_NAME": "Local Git Test", "GIT_AUTHOR_EMAIL": "local-test@example.invalid", "GIT_COMMITTER_NAME": "Local Git Test", "GIT_COMMITTER_EMAIL": "local-test@example.invalid"]
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        _ = try git(["init", "--initial-branch=main"])
        _ = try git(["config", "commit.gpgSign", "false"])
        _ = try git(["config", "core.hooksPath", "/dev/null"])
        _ = try git(["config", "core.autocrlf", "false"])
    }

    func repository(at url: URL? = nil) async throws -> LocalGitRepository {
        try await LocalGitRepository.discover(at: url ?? root, environment: environment)
    }

    func write(_ name: String, _ contents: String) throws {
        try Data(contents.utf8).write(to: root.appendingPathComponent(name))
    }

    func read(_ name: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
    }

    @discardableResult func git(_ arguments: [String], allowFailure: Bool = false) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", root.path] + arguments
        var env = ProcessInfo.processInfo.environment
        env.merge(environment, uniquingKeysWith: { _, new in new })
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        guard allowFailure || process.terminationStatus == 0 else {
            throw NSError(domain: "LocalGitTests", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: output])
        }
        return output
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private extension Sequence {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var results: [T] = []
        for element in self { results.append(try await transform(element)) }
        return results
    }
}
