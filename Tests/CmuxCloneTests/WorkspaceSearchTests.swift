import AppKit
import SwiftUI
import XCTest
@testable import CmuxClone

@MainActor
final class WorkspaceSearchTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vsux-search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    @discardableResult private func write(_ path: String, _ text: String) throws -> URL {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file); return file
    }
    private func git(_ arguments: [String]) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path] + arguments
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
    }
    private func wait(_ search: WorkspaceSearchModel) async throws {
        for _ in 0..<300 {
            if !search.searching { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Search did not finish")
    }
    func testLiteralCaseAndWholeWordWithMultipleMatchesPerLine() throws {
        try write("a.txt", "Java java JavaScript java_ java.\nJAVA")
        var query = WorkspaceSearchQuery(text: "java")
        XCTAssertEqual(try WorkspaceSearchEngine.search(root: root, query: query).count, 6)
        query.wholeWord = true
        XCTAssertEqual(try WorkspaceSearchEngine.search(root: root, query: query).count, 4)
        query.matchCase = true
        XCTAssertEqual(try WorkspaceSearchEngine.search(root: root, query: query).count, 2)
        query.text = "."; query.wholeWord = false
        XCTAssertEqual(try WorkspaceSearchEngine.search(root: root, query: query).count, 1)
    }
    func testUnicodeCRLFMultilineAndLongPreviewPreserveUTF16Ranges() throws {
        let text = "😀 中文\r\n" + String(repeating: "😀", count: 50) + " Java 中文\r\nnext line"
        try write("unicode.txt", text)
        let file = try XCTUnwrap(WorkspaceSearchEngine.search(root: root, query: WorkspaceSearchQuery(text: "java")).files.first)
        let match = try XCTUnwrap(file.matches.first)
        XCTAssertEqual(match.line, 2); XCTAssertEqual(match.column, 102)
        XCTAssertEqual((text as NSString).substring(with: match.range), "Java")
        XCTAssertEqual((match.preview as NSString).substring(with: match.previewRange), "Java")
        XCTAssertFalse(match.preview.contains("�")); XCTAssertTrue(match.preview.hasPrefix("…"))
        let multiline = try WorkspaceSearchEngine.search(root: root, query: WorkspaceSearchQuery(text: "中文\\r?\\nnext", regex: true))
        XCTAssertEqual(multiline.count, 1)
        XCTAssertEqual(multiline.files.first?.matches.first?.line, 2)
    }
    func testRegexCapturesAndLiteralReplacementCharacters() throws {
        try write("a.txt", "java12 java34")
        let query = WorkspaceSearchQuery(text: "java(\\d+)", regex: true)
        let file = try XCTUnwrap(WorkspaceSearchEngine.search(root: root, query: query).files.first)
        XCTAssertEqual(try WorkspaceSearchEngine.replacing(file, matches: file.matches, query: query, replacement: "type$1"), "type12 type34")
        let literal = WorkspaceSearchQuery(text: "java")
        let plain = try XCTUnwrap(WorkspaceSearchEngine.search(root: root, query: literal).files.first)
        XCTAssertEqual(try WorkspaceSearchEngine.replacing(plain, matches: plain.matches, query: literal, replacement: "$1\\x"), "$1\\x12 $1\\x34")
    }
    func testInvalidAndZeroWidthRegexAndCancellation() throws {
        XCTAssertThrowsError(try WorkspaceSearchQuery(text: "[", regex: true).expression())
        let expression = try WorkspaceSearchQuery(text: "(?=a)", regex: true).expression()
        XCTAssertEqual(WorkspaceSearchEngine.find(in: "aaa", expression: expression).map(\.range.location), [0, 1, 2])
        XCTAssertTrue(WorkspaceSearchEngine.find(in: String(repeating: "a", count: 1000), expression: expression, cancelled: { true }).isEmpty)
    }
    func testIncludeExcludeGlobsAndDefaultDirectories() throws {
        try write("src/a.swift", "needle"); try write("src/a.ts", "needle")
        try write("Tests/b.swift", "needle"); try write("node_modules/a.swift", "needle")
        let query = WorkspaceSearchQuery(text: "needle", includes: "**/*.swift", excludes: "Tests/**")
        XCTAssertEqual(try WorkspaceSearchEngine.search(root: root, query: query).files.map(\.path), ["src/a.swift"])
        XCTAssertEqual(try WorkspaceSearchEngine.search(root: root, query: WorkspaceSearchQuery(text: "needle", useIgnores: false)).count, 4)
        XCTAssertTrue(SearchPathFilter("src/").matches("src/a.ts"))
        XCTAssertTrue(SearchPathFilter("*.swift, *.ts").matches("src/a.ts"))
        XCTAssertFalse(SearchPathFilter("src/?.ts").matches("src/long.ts"))
    }
    func testGitIgnoreNegationsAndSubdirectoryWorkspace() throws {
        try git(["init", "-q"])
        try write(".gitignore", "ignored/\n*.log\n!keep.log\n")
        try write("a.txt", "needle"); try write("ignored/a.txt", "needle")
        try write("drop.log", "needle"); try write("keep.log", "needle")
        try write("sub/a.txt", "needle")
        let query = WorkspaceSearchQuery(text: "needle")
        XCTAssertEqual(try WorkspaceSearchEngine.search(root: root, query: query).files.map(\.path), ["a.txt", "keep.log", "sub/a.txt"])
        XCTAssertEqual(try WorkspaceSearchEngine.search(root: root.appendingPathComponent("sub"), query: query).files.map(\.path), ["a.txt"])
    }
    func testSkipsBinaryOversizedAndSymlinkFiles() throws {
        try write("normal.txt", "needle")
        try Data([0, 1, 2]).write(to: root.appendingPathComponent("binary.bin"))
        try write("large.txt", String(repeating: "n", count: WorkspaceSearchEngine.maxFileBytes + 1))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.txt"), withDestinationURL: root.appendingPathComponent("normal.txt"))
        let result = try WorkspaceSearchEngine.search(root: root, query: WorkspaceSearchQuery(text: "needle"))
        XCTAssertEqual(result.files.map(\.path), ["normal.txt"]); XCTAssertEqual(result.skipped, 2)
    }
    func testResultLimitNeverCreatesEmptyFileGroups() throws {
        try write("a.txt", String(repeating: "x ", count: WorkspaceSearchEngine.maxMatches))
        try write("b.txt", "x")
        let result = try WorkspaceSearchEngine.search(root: root, query: WorkspaceSearchQuery(text: "x"))
        XCTAssertEqual(result.count, WorkspaceSearchEngine.maxMatches); XCTAssertTrue(result.limitHit)
        XCTAssertEqual(result.files.count, 1)
    }
    func testSearchUsesDirtyBufferAndOpensExactMatch() async throws {
        let url = try write("a.txt", "disk")
        let files = FileWorkspaceModel(rootURL: root); files.open(url)
        let doc = try XCTUnwrap(files.selectedDocument)
        files.update(doc, text: "😀\nunsaved needle")
        let search = files.search; search.query.text = "needle"; search.schedule(immediate: true)
        try await wait(search)
        let file = try XCTUnwrap(search.results.files.first), match = try XCTUnwrap(file.matches.first)
        XCTAssertTrue(search.open(file, match: match))
        XCTAssertEqual(doc.searchSelection?.range, match.range)
        XCTAssertEqual(match.line, 2); XCTAssertEqual(match.column, 9)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "disk")
    }
    func testLatestQueryWinsAndClearCancelsPendingWork() async throws {
        try write("a.txt", "alpha beta beta")
        let files = FileWorkspaceModel(rootURL: root), search = files.search
        search.query.text = "alpha"; search.schedule(immediate: true)
        search.query.text = "beta"; search.schedule(immediate: true)
        try await wait(search)
        XCTAssertEqual(search.results.count, 2); XCTAssertEqual(search.completedQuery?.text, "beta")
        search.query.text = "alpha"; search.clear()
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(search.results.count, 0); XCTAssertFalse(search.searching); XCTAssertFalse(search.hasSearched)
    }
    func testBatchReplacePreservesDiskAndCanUndo() async throws {
        let a = try write("a.txt", "java12 java34"), b = try write("b.txt", "java56")
        let files = FileWorkspaceModel(rootURL: root), search = files.search
        search.query = WorkspaceSearchQuery(text: "java(\\d+)", regex: true)
        search.schedule(immediate: true); try await wait(search)
        search.replacement = "type$1"
        XCTAssertTrue(search.replace()); XCTAssertEqual(files.documents.count, 2)
        XCTAssertTrue(files.documents.allSatisfy(\.isDirty)); XCTAssertTrue(search.canUndoReplacement)
        XCTAssertEqual(files.documents.first { $0.url == a }?.text, "type12 type34")
        XCTAssertEqual(try String(contentsOf: b, encoding: .utf8), "java56")
        search.undoReplacement()
        XCTAssertEqual(files.documents.first { $0.url == a }?.text, "java12 java34")
        XCTAssertFalse(search.canUndoReplacement)
        search.cancel()
    }
    func testStaleBatchIsRejectedBeforeChangingAnyBuffer() async throws {
        let a = try write("a.txt", "needle"), b = try write("b.txt", "needle")
        let files = FileWorkspaceModel(rootURL: root), search = files.search
        search.query.text = "needle"; search.schedule(immediate: true); try await wait(search)
        try Data("external change".utf8).write(to: b)
        search.replacement = "new"
        XCTAssertFalse(search.replace()); XCTAssertNotNil(search.error)
        XCTAssertTrue(files.documents.isEmpty)
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "needle")
    }
    func testSingleReplacementAndSubsequentBufferEditRefresh() async throws {
        let url = try write("a.txt", "needle needle")
        let files = FileWorkspaceModel(rootURL: root), search = files.search
        search.query.text = "needle"; search.schedule(immediate: true); try await wait(search)
        let file = try XCTUnwrap(search.results.files.first)
        search.replacement = "other"; XCTAssertTrue(search.replace(file: file, match: file.matches[0]))
        try await wait(search)
        XCTAssertEqual(search.results.count, 1)
        let doc = try XCTUnwrap(files.documents.first { $0.url == url })
        files.update(doc, text: "changed")
        try await Task.sleep(for: .milliseconds(20)); try await wait(search)
        XCTAssertEqual(search.results.count, 0); XCTAssertFalse(search.canUndoReplacement)
    }
    func testNativePanelAndEditorSelectAndRevealSearchMatch() async throws {
        _ = NSApplication.shared
        try write("src/languages.ts", "// Languages used by the workspace\nconst languages = ['Java', 'Python', 'JavaScript'];\n\nexport function isJava(name: string) {\n    return name.toLowerCase() === 'java';\n}\n")
        try write("docs/environment.md", "# Development environment\n\nSet JAVA_HOME before starting the Java compiler.\n\nJavaScript tools use the local Node runtime.\n")
        try write("package.json", "{\n  \"description\": \"Java and JavaScript workspace\"\n}\n")
        let files = FileWorkspaceModel(rootURL: root), search = files.search
        search.query.text = "java"; search.showReplace = true
        search.schedule(immediate: true); try await wait(search)
        let file = try XCTUnwrap(search.results.files.first { $0.path == "src/languages.ts" })
        let match = file.matches[1]
        XCTAssertTrue(search.open(file, match: match))
        let window = PointerCursorWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 680), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: HStack(spacing: 0) {
            WorkspaceSearchPanel(model: search, onOpen: {}).frame(width: 360)
            Divider()
            FileEditorArea(model: files)
        }.frame(width: 1100, height: 680))
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); search.cancel() }
        try await Task.sleep(for: .milliseconds(250)); host.layoutSubtreeIfNeeded()
        func editors(_ view: NSView) -> [CodeTextView] {
            (view as? CodeTextView).map { [$0] } ?? view.subviews.flatMap { editors($0) }
        }
        let editor = try XCTUnwrap(editors(host).first)
        XCTAssertEqual(editor.selectedRange(), match.range)
        XCTAssertEqual((editor.string as NSString).substring(with: editor.selectedRange()), "Java")
        XCTAssertEqual(files.selectedDocument?.isPreview, true)
        // A fresh click request must also work in an editor that is already mounted.
        XCTAssertTrue(search.open(file, match: file.matches.last!))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(editor.selectedRange(), file.matches.last?.range)
        // Exercise the visible result button, not only the model entry point.
        let point = NSPoint(x: 180, y: 680 - 206)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            window.sendEvent(event)
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(files.selectedDocument?.url.lastPathComponent, "environment.md")
        XCTAssertEqual(editors(host).first?.selectedRange(), search.results.files.first?.matches.first?.range)
        XCTAssertTrue(search.open(file, match: file.matches.last!))
        try await Task.sleep(for: .milliseconds(100))
        if let destination = ProcessInfo.processInfo.environment["CMUX_SEARCH_SNAPSHOT"] {
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: destination))
        }
    }
    func testFindInFilesMenuUsesCommandShiftF() throws {
        _ = NSApplication.shared
        AppDelegate.shared.makeMenus()
        let edit = try XCTUnwrap(NSApp.mainMenu?.items.first { $0.title == L("编辑") }?.submenu)
        let item = try XCTUnwrap(edit.items.first { $0.title == L("在文件中搜索…") })
        XCTAssertEqual(item.keyEquivalent, "f")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .shift])
    }

    func testWorkbenchZoomMenuUsesControlPlusMinusAndZero() throws {
        _ = NSApplication.shared
        AppDelegate.shared.makeMenus()
        let view = try XCTUnwrap(NSApp.mainMenu?.items.first { $0.title == L("显示") }?.submenu)
        let increase = try XCTUnwrap(view.items.first { $0.title == L("放大界面") })
        let decrease = try XCTUnwrap(view.items.first { $0.title == L("缩小界面") })
        let reset = try XCTUnwrap(view.items.first { $0.title == L("重置界面缩放") })
        XCTAssertEqual(increase.keyEquivalent, "+")
        XCTAssertEqual(increase.keyEquivalentModifierMask, [.control])
        XCTAssertEqual(decrease.keyEquivalent, "-")
        XCTAssertEqual(decrease.keyEquivalentModifierMask, [.control])
        XCTAssertEqual(reset.keyEquivalent, "0")
        XCTAssertEqual(reset.keyEquivalentModifierMask, [.control])
    }
}
