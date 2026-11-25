import AppKit
import SwiftUI
import XCTest
@testable import CmuxClone

@MainActor
final class EditorWordWrapTests: XCTestCase {
    func testEditorReflowsWithViewportWidthAndPreservesSource() async throws {
        _ = NSApplication.shared
        let source = String(repeating: "let value = example 中文🙂 ", count: 12) + "\r\nnext"
        let document = LocalFileDocument(url: URL(fileURLWithPath: "/tmp/wrap.txt"), text: source,
                                         data: Data(source.utf8), isPreview: false)
        var changes: [String] = []
        let host = NSHostingView(rootView: SyntaxEditor(document: document, onChange: { changes.append($0) }, onSave: {}))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 500),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.orderOut(nil) }

        host.layoutSubtreeIfNeeded()
        for _ in 0..<100 {
            if findEditor(in: host) != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let editor = try XCTUnwrap(findEditor(in: host))
        let scroll = try XCTUnwrap(editor.enclosingScrollView)
        let ruler = try XCTUnwrap(scroll.verticalRulerView as? CodeLineRuler)
        let layout = try XCTUnwrap(editor.layoutManager)
        let container = try XCTUnwrap(editor.textContainer)
        func fragmentCount() -> Int {
            layout.ensureLayout(for: container)
            var count = 0
            layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { _, _, _, _, _ in
                count += 1
            }
            return count
        }

        let narrowCount = fragmentCount()
        XCTAssertGreaterThan(narrowCount, 2, "A long logical line should span multiple display rows.")
        XCTAssertFalse(scroll.hasHorizontalScroller)
        var numbers: [Int] = []
        ruler.enumerateVisibleLineNumbers { number, _ in numbers.append(number) }
        XCTAssertEqual(numbers, [1, 2])

        let firstLine = editor.logicalLineRect(at: 0)
        let firstRow = layout.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        let nextLine = editor.logicalLineRect(at: (source as NSString).range(of: "next").location)
        XCTAssertGreaterThan(firstLine.height, firstRow.height)
        XCTAssertEqual(firstLine.maxY, nextLine.minY, accuracy: 0.5)
        let selection = NSRange(location: 42, length: 7)
        editor.setSelectedRange(selection)

        window.setContentSize(NSSize(width: 700, height: 500))
        host.layoutSubtreeIfNeeded()
        XCTAssertLessThan(fragmentCount(), narrowCount)

        document.wordWrap = false
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(fragmentCount(), 2)
        XCTAssertTrue(scroll.hasHorizontalScroller)
        XCTAssertGreaterThan(editor.frame.width, scroll.contentSize.width)
        scroll.contentView.scroll(to: NSPoint(x: 100, y: 0))
        XCTAssertGreaterThan(scroll.contentView.bounds.minX, 0)

        document.wordWrap = true
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertGreaterThan(fragmentCount(), 2)
        XCTAssertEqual(scroll.contentView.bounds.minX, 0, accuracy: 0.5)
        XCTAssertEqual(editor.string, source)
        XCTAssertEqual(editor.selectedRange(), selection)
        XCTAssertTrue(changes.isEmpty)
        XCTAssertFalse(document.isDirty)
    }

    func testScrollingAcrossContinuationsReportsProgressWithinOneSourceLine() async throws {
        _ = NSApplication.shared
        let source = "title\r\n" + String(repeating: "long value ", count: 36) + "\r\nnext\n"
            + String(repeating: "later\n", count: 50)
        let document = LocalFileDocument(url: URL(fileURLWithPath: "/tmp/wrap.md"), text: source,
                                         data: Data(source.utf8), isPreview: false)
        var readingLines: [Double] = []
        let host = NSHostingView(rootView: SyntaxEditor(document: document, onChange: { _ in }, onSave: {},
                                                        onScroll: { readingLines.append($0) }))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 250),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        let editor = try XCTUnwrap(findEditor(in: host))
        let scroll = try XCTUnwrap(editor.enclosingScrollView)
        let ruler = try XCTUnwrap(scroll.verticalRulerView as? CodeLineRuler)
        let line = editor.logicalLineRect(at: (source as NSString).range(of: "long").location)
        for fraction in [0.25, 0.75] {
            readingLines.removeAll()
            scroll.contentView.scroll(to: NSPoint(x: 0, y: editor.textContainerOrigin.y + line.minY + fraction * line.height))
            scroll.reflectScrolledClipView(scroll.contentView)
            for _ in 0..<100 {
                if !readingLines.isEmpty { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(try XCTUnwrap(readingLines.last), 2 + fraction, accuracy: 0.03)
        }
        var numbers: [Int] = []
        ruler.enumerateVisibleLineNumbers { number, _ in numbers.append(number) }
        XCTAssertEqual(numbers.first, 3)
    }

    private func findEditor(in view: NSView) -> CodeTextView? {
        (view as? CodeTextView) ?? view.subviews.lazy.compactMap { self.findEditor(in: $0) }.first
    }
}
