import AppKit
import SwiftUI
import XCTest
@testable import CmuxClone

@MainActor
final class EditorIndentationTests: XCTestCase {
    private func editor(_ text: String, selection: NSRange) -> CodeTextView {
        _ = NSApplication.shared
        let editor = CodeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        editor.isRichText = false
        editor.allowsUndo = true
        editor.string = text
        editor.setSelectedRange(selection)
        return editor
    }

    func testTabIndentsSelectedLinesWithoutReplacingTheirContents() {
        _ = NSApplication.shared
        let editor = CodeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        editor.isRichText = false
        editor.string = "key: value\nsecret: example\nnext: value\n"
        editor.setSelectedRange(NSRange(location: 0, length: 26))
        editor.insertTab(nil)
        XCTAssertEqual(editor.string, "    key: value\n    secret: example\nnext: value\n")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 34))
    }

    func testIndentationFixturesAreSelfContained() {
        // Synthetic cases stay with the tests so a clean checkout needs no local reports.
        let fixtures: [(name: String, text: String, selection: [Int], outdent: Bool, expected: String)] = [
            ("partial multiline", "first: item\nsecond: item\nlast: item", [1, 2, 2, 7], false,
             "    first: item\n    second: item\nlast: item"),
            ("end at next line start", "red\ngreen\nblue", [1, 1, 3, 1], false,
             "    red\n    green\nblue"),
            ("empty lines skipped", "x\n\n  \ny", [1, 1, 4, 2], false,
             "    x\n\n    \n    y"),
            ("ragged indentation", "  x\n     y", [1, 1, 2, 7], false,
             "    x\n        y"),
            ("full single line", "cat\ndog", [1, 1, 1, 4], false, "    cat\ndog"),
            ("partial single line replaces selection", "planet", [1, 2, 1, 4], false, "p   net"),
            ("caret advances to stop", "cat", [1, 3, 1, 3], false, "ca  t"),
            ("outdent multiline", "    x\n  y\nz", [1, 1, 3, 2], true, "x\ny\nz"),
            ("outdent caret", "      cat", [1, 9, 1, 9], true, "    cat"),
            ("mixed tabs normalize to spaces", "\t x\n\ty", [1, 1, 2, 3], false,
             "        x\n        y"),
            ("outdent tab", "\t  x", [1, 4, 1, 4], true, "    x"),
        ]
        for fixture in fixtures {
            let lines = fixture.text.components(separatedBy: "\n")
            func offset(_ line: Int, _ column: Int) -> Int {
                lines.prefix(line - 1).reduce(0) { $0 + ($1 as NSString).length + 1 } + column - 1
            }
            let selection = fixture.selection
            let start = offset(selection[0], selection[1]), end = offset(selection[2], selection[3])
            let view = editor(fixture.text, selection: NSRange(location: start, length: end - start))
            if fixture.outdent { view.insertBacktab(nil) } else { view.insertTab(nil) }
            XCTAssertEqual(view.string, fixture.expected, fixture.name)
        }
    }

    func testPartialMultilineSelectionTracksTextAndCanIndentRepeatedly() {
        let view = editor("alpha\nbeta\ngamma", selection: NSRange(location: 2, length: 6))
        view.insertTab(nil)
        XCTAssertEqual(view.string, "    alpha\n    beta\ngamma")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 6, length: 10))
        view.insertTab(nil)
        XCTAssertEqual(view.string, "        alpha\n        beta\ngamma")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 10, length: 14))
        view.insertBacktab(nil)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 6, length: 10))
    }

    func testCRLFUnicodeEmptyFinalLineAndNoIndentNoOp() {
        let source = "中文🙂: 值\r\nsecond\r\nthird"
        let end = (source as NSString).range(of: "third").location
        let view = editor(source, selection: NSRange(location: 0, length: end))
        view.insertTab(nil)
        XCTAssertEqual(view.string, "    中文🙂: 值\r\n    second\r\nthird")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: end + 8))
        view.insertBacktab(nil)
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: end))
        view.insertBacktab(nil)
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: end))
        let empty = editor("a\n", selection: NSRange(location: 2, length: 0))
        empty.insertTab(nil)
        XCTAssertEqual(empty.string, "a\n    ")
        XCTAssertEqual(empty.selectedRange(), NSRange(location: 6, length: 0))
    }

    func testUndoRedoPreserveWholeBlockAndSelectionInOneStep() throws {
        let source = "first\nsecond\nlast"
        let selected = NSRange(location: 0, length: 12)
        let view = editor(source, selection: selected)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.makeFirstResponder(view)
        defer { window.orderOut(nil) }
        view.insertTab(nil)
        let indented = view.string, selection = view.selectedRange()
        let undo = try XCTUnwrap(view.undoManager)
        XCTAssertTrue(undo.canUndo)
        undo.undo()
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(view.selectedRange(), selected)
        undo.redo()
        XCTAssertEqual(view.string, indented)
        XCTAssertEqual(view.selectedRange(), selection)
        view.insertBacktab(nil)
        XCTAssertEqual(view.string, source)
        undo.undo()
        XCTAssertEqual(view.string, indented)
    }

    func testReadOnlyMarkedTextAndDelegateVetoLeaveTextAndSelectionUntouched() {
        let source = "one\ntwo"
        let selected = NSRange(location: 0, length: 7)
        let view = editor(source, selection: selected)
        view.isEditable = false
        view.insertTab(nil)
        view.insertBacktab(nil)
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(view.selectedRange(), selected)
        view.isEditable = true
        final class Veto: NSObject, NSTextViewDelegate {
            func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool { false }
        }
        let veto = Veto()
        view.delegate = veto
        view.insertTab(nil)
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(view.selectedRange(), selected)
        view.delegate = nil
        view.setMarkedText("拼音", selectedRange: NSRange(location: 2, length: 0), replacementRange: selected)
        let marked = view.string, markedSelection = view.selectedRange()
        XCTAssertTrue(view.hasMarkedText())
        view.insertTab(nil)
        view.insertBacktab(nil)
        XCTAssertEqual(view.string, marked)
        XCTAssertEqual(view.selectedRange(), markedSelection)
    }

    func testNativeTabAndShiftTabUpdateDocumentKeepFocusAndSave() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("indent.yaml")
        let source = "key: example\nvalue: example\nnext: example\n"
        try Data(source.utf8).write(to: file)
        let model = FileWorkspaceModel(rootURL: directory)
        model.open(file, preview: false)
        let document = try XCTUnwrap(model.selectedDocument)
        let host = NSHostingView(rootView: SyntaxEditor(document: document, onChange: { document.text = $0 }, onSave: { model.save(document) }))
        let window = PointerCursorWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        func find(_ view: NSView) -> CodeTextView? {
            (view as? CodeTextView) ?? view.subviews.lazy.compactMap { find($0) }.first
        }
        for _ in 0..<100 {
            if find(host) != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let view = try XCTUnwrap(find(host))
        window.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: 0, length: (source as NSString).range(of: "next").location))
        func pressTab(shift: Bool) {
            let characters = shift ? "\u{19}" : "\t"
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? [.shift] : [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 48)!
            window.sendEvent(event)
        }
        pressTab(shift: false)
        XCTAssertEqual(document.text, "    key: example\n    value: example\nnext: example\n")
        XCTAssertTrue(document.isDirty)
        XCTAssertTrue(window.firstResponder === view)
        try await Task.sleep(for: .milliseconds(150)) // Includes SwiftUI update and delayed highlighting.
        XCTAssertEqual(view.string, document.text)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: 36))
        pressTab(shift: true)
        XCTAssertEqual(document.text, source)
        XCTAssertTrue(window.firstResponder === view)
        pressTab(shift: false)
        model.save(document)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), document.text)
        XCTAssertFalse(document.isDirty)
    }
}
