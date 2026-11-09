import AppKit
import SwiftUI
import XCTest
@testable import CmuxClone

@MainActor
final class EditorFindTests: XCTestCase {
    private func query(_ text: String, matchCase: Bool = false, wholeWord: Bool = false, regex: Bool = false) -> WorkspaceSearchQuery {
        WorkspaceSearchQuery(text: text, matchCase: matchCase, wholeWord: wholeWord, regex: regex)
    }
    private func settle(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let until = Date().addingTimeInterval(3)
        while !predicate(), Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(predicate(), file: file, line: line)
    }
    private func mounted(_ source: String, query: WorkspaceSearchQuery) -> (NSWindow, CodeTextView, EditorFindController) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 380), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = CodeEditorScrollView(frame: NSRect(x: 0, y: 0, width: 820, height: 380))
        let editor = CodeTextView(frame: NSRect(x: 0, y: 0, width: 820, height: 380))
        editor.isRichText = false; editor.allowsUndo = true; editor.string = source
        editor.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        editor.textContainerInset = NSSize(width: 15, height: 60)
        scroll.documentView = editor; window.contentView = scroll
        let session = EditorFindSession(); session.query = query
        let controller = EditorFindController(editor: editor, session: session)
        controller.attach(to: scroll)
        editor.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        controller.open()
        // Engine/controller fixtures explicitly set a query after testing the open path.
        // Opening normally seeds the caret word, as VS Code does.
        session.query = query; controller.input.stringValue = query.text; controller.refresh(move: false)
        settle { controller.result.ranges.count > 0 || controller.result.error != nil }
        window.makeKeyAndOrderFront(nil)
        return (window, editor, controller)
    }
    func testLiteralCaseWholeWordAndUTF16() {
        let text = "🙂 cat Cat scatter cat_ cat\r\n猫 cat"
        XCTAssertEqual(EditorFindEngine.search(text, query: query("cat")).ranges.count, 6)
        XCTAssertEqual(EditorFindEngine.search(text, query: query("cat", matchCase: true)).ranges.count, 5)
        let ranges = EditorFindEngine.search(text, query: query("cat", wholeWord: true)).ranges
        XCTAssertEqual(ranges.count, 4)
        XCTAssertEqual(ranges.first, NSRange(location: 3, length: 3))
        XCTAssertEqual(EditorFindEngine.search("a.b axb", query: query("a.b")).ranges, [NSRange(location: 0, length: 3)])
    }
    func testRegexInvalidEmptyMultilineZeroWidthAndScopeBoundaries() {
        XCTAssertTrue(EditorFindEngine.search("abc", query: query("")).ranges.isEmpty)
        XCTAssertNotNil(EditorFindEngine.search("abc", query: query("[", regex: true)).error)
        XCTAssertEqual(EditorFindEngine.search("a\nb\na\nb", query: query("a\\nb", regex: true)).ranges.count, 2)
        XCTAssertEqual(EditorFindEngine.search("a\nb\n", query: query("^", regex: true)).ranges.map(\.location), [0, 2])
        XCTAssertTrue(EditorFindEngine.search("scatter", query: query("cat", wholeWord: true), scope: NSRange(location: 1, length: 3)).ranges.isEmpty)
        XCTAssertTrue(EditorFindEngine.search("xxcat", query: query("^cat", regex: true), scope: NSRange(location: 2, length: 3)).ranges.isEmpty)
    }
    func testSelectionSeedingAndMultilineScope() {
        let text = "alpha\r\nbeta\r\ngamma"
        XCTAssertEqual(EditorFindEngine.seed(in: text, selection: NSRange(location: 2, length: 0)), "alpha")
        XCTAssertEqual(EditorFindEngine.seed(in: text, selection: NSRange(location: 1, length: 3)), "lph")
        XCTAssertNil(EditorFindEngine.seed(in: text, selection: NSRange(location: 0, length: 8)))
        XCTAssertEqual(EditorFindEngine.scope(NSRange(location: 2, length: 11), in: text), NSRange(location: 0, length: 11))
        XCTAssertEqual(EditorFindEngine.scope(NSRange(location: 2, length: 7), in: text), NSRange(location: 0, length: 11))
        XCTAssertEqual(EditorFindEngine.scope(NSRange(location: 1, length: 3), in: text), NSRange(location: 1, length: 3))
    }
    func testLimitsAndCancellation() {
        let result = EditorFindEngine.search(String(repeating: "a ", count: 20_100), query: query("a"))
        XCTAssertEqual(result.ranges.count, EditorFindEngine.limit); XCTAssertTrue(result.limitHit)
        XCTAssertTrue(EditorFindEngine.search("abc abc", query: query("abc"), cancelled: { true }).ranges.isEmpty)
    }
    func testRegexReplacementAndLiteralDollar() throws {
        let text = "🙂 cat1 cat2"
        let q = query("cat(\\d)", regex: true)
        let ranges = EditorFindEngine.search(text, query: q).ranges
        let edit = try XCTUnwrap(EditorFindEngine.replacement(in: text, ranges: ranges, query: q, value: "dog$1"))
        XCTAssertEqual((text as NSString).replacingCharacters(in: edit.range, with: edit.text), "🙂 dog1 dog2")
        let literal = query("cat")
        let value = try XCTUnwrap(EditorFindEngine.replacement(in: "cat cat", ranges: EditorFindEngine.search("cat cat", query: literal).ranges, query: literal, value: "$1\\n"))
        XCTAssertEqual(value.text, "$1\\n $1\\n")
    }
    func testNavigationWrapsAndCloseRestoresFocusWithoutDirtyingText() {
        let (window, editor, find) = mounted("cat x cat", query: query("cat"))
        defer { window.close() }
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        find.next(); XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 3))
        find.next(); XCTAssertEqual(editor.selectedRange(), NSRange(location: 6, length: 3))
        find.next(); XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 3))
        find.previous(); XCTAssertEqual(editor.selectedRange(), NSRange(location: 6, length: 3))
        XCTAssertEqual(editor.string, "cat x cat"); XCTAssertFalse(editor.undoManager?.canUndo ?? false)
        XCTAssertNotNil(editor.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: 0, effectiveRange: nil))
        find.close()
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertNil(editor.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: 0, effectiveRange: nil))
        XCTAssertEqual(find.session.history.first, "cat")
    }
    func testZeroWidthNavigationMakesProgress() {
        let (window, editor, find) = mounted("a\nb\n", query: query("(?=a|b|\\z)", regex: true))
        defer { window.close() }
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        find.next(); XCTAssertEqual(editor.selectedRange().location, 2)
        find.next(); XCTAssertEqual(editor.selectedRange().location, 4)
        find.next(); XCTAssertEqual(editor.selectedRange().location, 0)
    }
    func testReplaceAllIsOneUndoTransactionAndRedo() {
        let (window, editor, find) = mounted("cat x cat", query: query("cat"))
        defer { window.close() }
        find.session.replacement = "doggy"
        find.replaceAll()
        XCTAssertEqual(editor.string, "doggy x doggy")
        XCTAssertTrue(editor.undoManager?.canUndo == true)
        editor.undoManager?.undo(); XCTAssertEqual(editor.string, "cat x cat")
        editor.undoManager?.redo(); XCTAssertEqual(editor.string, "doggy x doggy")
    }
    func testSelectionReplacementAndReadOnly() {
        let (window, editor, find) = mounted("cat cat cat", query: query("cat"))
        defer { window.close() }
        editor.setSelectedRange(NSRange(location: 4, length: 3)); find.toggleScope()
        settle { find.result.ranges.count == 1 }
        find.session.replacement = "elephant"; find.replaceAll()
        XCTAssertEqual(editor.string, "cat elephant cat")
        XCTAssertEqual(find.scope, NSRange(location: 4, length: 8))
        editor.isEditable = false
        XCTAssertFalse(editor.replaceForFind(range: NSRange(location: 0, length: 3), text: "dog"))
        XCTAssertEqual(editor.string, "cat elephant cat")
    }
    func testRapidQueriesPublishOnlyLatestAndClosingCancels() {
        let (window, editor, find) = mounted("cat dog dog", query: query("cat"))
        defer { window.close() }
        find.session.query.text = "cat"; find.refresh(move: true)
        find.session.query.text = "dog"; find.refresh(move: true)
        settle { find.result.ranges.count == 2 }
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 4, length: 3))
        find.session.query.text = "cat"; find.refresh(move: true); find.close()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(find.panel.isHidden)
        XCTAssertNil(editor.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: 0, effectiveRange: nil))
    }
    func testRealRepresentableReceivesControlFFindUpdatesBufferAndSave() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("sample.txt"); try "cat cat\n".write(to: url, atomically: true, encoding: .utf8)
        let model = FileWorkspaceModel(rootURL: root); model.open(url)
        let document = try XCTUnwrap(model.selectedDocument)
        let host = NSHostingView(rootView: SyntaxEditor(document: document, onChange: { model.update(document, text: $0) }, onSave: { _ = model.save(document) }))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 380), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        settle { descendants(host).contains { $0 is CodeTextView } }
        let editor = try XCTUnwrap(descendants(host).compactMap { $0 as? CodeTextView }.first)
        editor.setSelectedRange(NSRange(location: 0, length: 3)); window.makeFirstResponder(editor)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3))
        XCTAssertTrue(editor.performKeyEquivalent(with: event))
        XCTAssertTrue(document.findSession.visible)
        XCTAssertEqual(document.findSession.query.text, "cat")
        XCTAssertFalse(document.isDirty)
        document.findSession.replacement = "dog"
        let replace = try XCTUnwrap(descendants(host).compactMap { $0 as? NSButton }.first { $0.action == #selector(EditorFindController.replaceAll) })
        settle { replace.isEnabled }
        replace.performClick(nil)
        settle { document.text == "dog dog\n" }
        XCTAssertTrue(document.isDirty)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "cat cat\n")
        XCTAssertTrue(model.save(document))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "dog dog\n")
        editor.undoManager?.undo(); settle { document.text == "cat cat\n" }
        XCTAssertTrue(document.isDirty)
    }
    func testNativeBarLayoutScreenshot() throws {
        let (window, editor, find) = mounted("let cat = \"cat\"\n// Find in the current file\ncat.run()", query: query("cat"))
        defer { window.close() }
        window.appearance = NSAppearance(named: .darkAqua)
        find.next(); window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(find.input.frame.width, 80)
        XCTAssertGreaterThan(find.panel.frame.height, 35)
        XCTAssertLessThanOrEqual(find.panel.frame.maxX, window.contentView!.bounds.maxX)
        let target = ProcessInfo.processInfo.environment["EDITOR_FIND_SCREENSHOT"]
        if let target, let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: target))
        }
        XCTAssertEqual(editor.string, "let cat = \"cat\"\n// Find in the current file\ncat.run()")
    }

    func testNarrowLayoutReplacementAndEnglishCopy() throws {
        let original = Localization.language
        Localization.setLanguage(.english)
        defer { Localization.setLanguage(original) }
        let (window, _, find) = mounted("cat cat", query: query("cat"))
        defer { window.close() }
        window.setContentSize(NSSize(width: 240, height: 380))
        find.toggleReplace(); window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(find.panel.frame.height, 90)
        for view in find.panel.subviews where !view.isHidden {
            XCTAssertGreaterThanOrEqual(view.frame.minX, 0)
            XCTAssertLessThanOrEqual(view.frame.maxX, find.panel.bounds.width)
            XCTAssertLessThanOrEqual(view.frame.maxY, find.panel.bounds.height)
        }
        XCTAssertEqual(find.input.placeholderString, "Find (↑↓ for history)")
        XCTAssertFalse(find.replacementInput.isHidden)
        if let target = ProcessInfo.processInfo.environment["EDITOR_FIND_SCREENSHOT"], let view = window.contentView,
           let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: target.replacingOccurrences(of: ".png", with: "-narrow.png")))
        }
    }

    func testScopeTracksEditsBeforeInsideAndAfterSelection() {
        let range = NSRange(location: 4, length: 3)
        XCTAssertEqual(EditorFindEngine.track(range, from: "cat dog end", to: "xcat dog end"), NSRange(location: 5, length: 3))
        XCTAssertEqual(EditorFindEngine.track(range, from: "cat dog end", to: "cat dooog end"), NSRange(location: 4, length: 5))
        XCTAssertEqual(EditorFindEngine.track(range, from: "cat dog end", to: "cat dog end!"), range)
        XCTAssertEqual(EditorFindEngine.track(range, from: "cat dog end", to: "cat  end"), NSRange(location: 4, length: 0))
    }

    func testEmptyZeroWidthReplaceMovesToNextHit() {
        let (window, editor, find) = mounted("a\nb", query: query("^", regex: true))
        defer { window.close() }
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        find.session.replacement = ""; find.replaceOne()
        settle { editor.selectedRange().location == 2 }
        XCTAssertEqual(editor.string, "a\nb")
    }

    func testHistoryKeyboardAndEscape() {
        let (window, _, find) = mounted("cat dog", query: query("cat"))
        defer { window.close() }
        find.session.remember(); find.session.query.text = "dog"; find.session.remember()
        let fieldEditor = NSTextView()
        XCTAssertTrue(find.control(find.input, textView: fieldEditor, doCommandBy: #selector(NSResponder.moveUp(_:))))
        XCTAssertEqual(find.input.stringValue, "dog")
        XCTAssertTrue(find.control(find.input, textView: fieldEditor, doCommandBy: #selector(NSResponder.moveUp(_:))))
        XCTAssertEqual(find.input.stringValue, "cat")
        XCTAssertTrue(find.control(find.input, textView: fieldEditor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertFalse(find.session.visible)
    }

    func testFindCommandRoutesByCurrentContentAndKeepsFileSearchSeparate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("file.txt"); try "cat".write(to: url, atomically: true, encoding: .utf8)
        let model = WindowModel(workspaces: [Workspace(name: "Find fixture", directory: root.path)])
        defer { model.disposeAll() }
        let workspace = try XCTUnwrap(model.workspace)
        let files = model.tools.files(workspace); files.open(url)
        model.tools.content = .editor
        AppDelegate.shared.beginFind(in: model)
        XCTAssertNotNil(files.selectedDocument?.findRequest)
        XCTAssertFalse(model.showFind)
        XCTAssertFalse(model.tools.showFileSearch)
        let request = files.selectedDocument?.findRequest
        model.tools.content = .terminal
        AppDelegate.shared.beginFind(in: model)
        XCTAssertTrue(model.showFind)
        XCTAssertEqual(files.selectedDocument?.findRequest, request)
    }

    func testFileFindCommandDoesNotInterceptTerminal() throws {
        _ = NSApplication.shared
        let window = PointerCursorWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3))
        var inEditor = false, opens = 0
        window.onShortcut = { command in
            guard command == .findFile, inEditor else { return false }
            opens += 1; return true
        }
        _ = window.performKeyEquivalent(with: event)
        XCTAssertEqual(opens, 0)
        inEditor = true
        XCTAssertTrue(window.performKeyEquivalent(with: event)); XCTAssertEqual(opens, 1)
    }

    func testDelegateVetoAndMarkedTextPreventReplacement() {
        final class Veto: NSObject, NSTextViewDelegate {
            func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool { false }
        }
        let (window, editor, _) = mounted("cat cat", query: query("cat"))
        defer { window.close() }
        let veto = Veto(); editor.delegate = veto
        XCTAssertFalse(editor.replaceForFind(range: NSRange(location: 0, length: 3), text: "dog"))
        XCTAssertEqual(editor.string, "cat cat")
        editor.delegate = nil
        editor.setMarkedText("猫", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        let source = editor.string
        XCTAssertFalse(editor.replaceForFind(range: NSRange(location: 0, length: 1), text: "dog"))
        XCTAssertEqual(editor.string, source)
        editor.unmarkText()
    }
}
