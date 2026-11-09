import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import CmuxClone

final class HighlightingTests: XCTestCase {
    private func kind(_ needle: String, in source: String, language: CodeLanguage, occurrence: Int = 0) -> CodeToken.Kind? {
        let ns = source as NSString
        var search = NSRange(location: 0, length: ns.length)
        var match = NSRange()
        for _ in 0...occurrence {
            match = ns.range(of: needle, range: search)
            guard match.location != NSNotFound else { XCTFail("缺少测试文本 \(needle)"); return nil }
            search = NSRange(location: NSMaxRange(match), length: ns.length - NSMaxRange(match))
        }
        return CodeHighlighter.tokens(in: source, language: language).first { NSLocationInRange(match.location, $0.range) }?.kind
    }

    func testFileAndFenceLanguageSelection() {
        let cases: [String: CodeLanguage] = ["a.java": .java, "a.rs": .rust, "a.go": .go, "a.kt": .kotlin, "a.cpp": .cpp, "a.c": .c, "a.mm": .objectivec, "a.cs": .csharp, "a.tsx": .typescript, "a.jsx": .javascript, "a.vue": .vue, "a.svg": .xml, "a.scss": .scss, "a.less": .less, "a.toml": .ini, "Dockerfile": .dockerfile, "Dockerfile.dev": .dockerfile, "Makefile": .makefile, ".zshrc": .shell, "a.unknown": .plain]
        for (name, expected) in cases { XCTAssertEqual(CodeLanguage.forFile(URL(fileURLWithPath: "/tmp/" + name)), expected, name) }
        XCTAssertEqual(CodeLanguage.forFile(URL(fileURLWithPath: "/tmp/script"), firstLine: "#!/usr/bin/env python3"), .python)
        XCTAssertEqual(CodeLanguage.forFile(URL(fileURLWithPath: "/tmp/script"), firstLine: "#!/bin/zsh"), .shell)
        XCTAssertEqual(CodeLanguage.forFile(URL(fileURLWithPath: "/tmp/script"), firstLine: "#!/usr/bin/env ts-node"), .typescript)
        XCTAssertEqual(CodeLanguage.forFile(URL(fileURLWithPath: "/tmp/text.txt"), firstLine: "#!/bin/bash"), .plain)
        for (name, expected) in ["c++": CodeLanguage.cpp, "typescript": .typescript, "js": .javascript, "java": .java, "vue": .vue, "bash": .shell, "text": .plain] { XCTAssertEqual(CodeLanguage.forFence(name), expected) }
    }

    func testStringsAndCommentsCannotOverwriteEachOther() {
        let source = #"let url = "https://host/#hash"; /* "quoted" // not code */ let number = 42 // "note""#
        XCTAssertEqual(kind("https", in: source, language: .swift), .string)
        XCTAssertEqual(kind("quoted", in: source, language: .swift), .comment)
        XCTAssertEqual(kind("number", in: source, language: .swift), nil)
        XCTAssertEqual(kind("42", in: source, language: .swift), .number)
        XCTAssertEqual(kind("note", in: source, language: .swift), .comment)
        let python = "url = '#not-comment'\n# 'not-string'\n"
        XCTAssertEqual(kind("#not-comment", in: python, language: .python), .string)
        XCTAssertEqual(kind("not-string", in: python, language: .python), .comment)
    }

    @MainActor func testDocumentRefreshPreservesActiveInputMethodComposition() async throws {
        _ = NSApplication.shared
        let source = "let value = 1"
        let document = LocalFileDocument(url: URL(fileURLWithPath: "/tmp/ime.swift"), text: source, data: Data(source.utf8), isPreview: false)
        let editor = SyntaxEditor(document: document, onChange: { _ in }, onSave: {})
        let coordinator = editor.makeCoordinator()
        let view = CodeTextView(frame: .zero)
        view.string = source
        coordinator.textView = view
        view.setMarkedText("sh", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 4, length: 5))
        XCTAssertTrue(view.hasMarkedText())

        coordinator.install("stale model update", language: .swift)
        XCTAssertTrue(view.hasMarkedText(), "A model refresh must not cancel an active input method composition")
        view.unmarkText()
        coordinator.install("committed composition", language: .swift)
        XCTAssertEqual(view.string, "committed composition", "The editor must resume model synchronization after composition ends")
    }

    func testMultilineStatesAndTemplateInterpolation() {
        let java = "/* opening\npublic class Hidden {}\n*/\npublic class Visible {}"
        XCTAssertEqual(kind("Hidden", in: java, language: .java), .comment)
        XCTAssertEqual(kind("Visible", in: java, language: .java), .type)
        let python = "message = \"\"\"first\n#still string\nlast\"\"\"\nreturn 42"
        XCTAssertEqual(kind("#still string", in: python, language: .python), .string)
        XCTAssertEqual(kind("return", in: python, language: .python), .control)
        let ts = "const message = `hello ${count + 42}`; const pattern = /ab+c/g;"
        XCTAssertEqual(kind("hello", in: ts, language: .typescript), .string)
        XCTAssertEqual(kind("count", in: ts, language: .typescript), nil)
        XCTAssertEqual(kind("42", in: ts, language: .typescript), .number)
        XCTAssertEqual(kind("/ab+c/g", in: ts, language: .typescript), .regexp)
    }

    func testLanguageSpecificTypesFunctionsPropertiesAndEmbeddedVue() {
        let java = "public class Hello { public static void main(String[] args) { return; } }"
        XCTAssertEqual(kind("Hello", in: java, language: .java), .type)
        XCTAssertEqual(kind("main", in: java, language: .java), .function)
        let rust = "fn main() { let message = r#\"raw // literal\"#; }"
        XCTAssertEqual(kind("fn", in: rust, language: .rust), .keyword)
        XCTAssertEqual(kind("raw // literal", in: rust, language: .rust), .string)
        XCTAssertEqual(kind("func", in: "package main\nfunc main() {}", language: .go), .keyword)
        let json = #"{"answer": 42, "message": "// value"}"#
        XCTAssertEqual(kind("answer", in: json, language: .json), .property)
        XCTAssertEqual(kind("// value", in: json, language: .json), .string)
        let vue = "<template><p :id=\"id\">Hi</p></template>\n<script setup lang=\"ts\">\nconst count: number = 42;\n</script>\n<style scoped>\n.card { color: red; }\n</style>"
        XCTAssertEqual(kind("template", in: vue, language: .vue), .tag)
        XCTAssertEqual(kind(":id", in: vue, language: .vue), .property)
        XCTAssertEqual(kind("const", in: vue, language: .vue), .keyword)
        XCTAssertEqual(kind("number", in: vue, language: .vue), .type)
        XCTAssertEqual(kind("42", in: vue, language: .vue), .number)
        XCTAssertEqual(kind("color", in: vue, language: .vue), .property)
    }

    func testAllRegisteredGrammarsLoadAndProduceTokens() {
        let samples: [CodeLanguage: String] = [.swift: "let x = 42", .javascript: "const x = 42", .typescript: "const x: number = 42", .json: "{\"x\":42}", .python: "def hello(): return 42", .shell: "echo \"hello\"", .markdown: "# Heading", .yaml: "key: 42", .html: "<p id=\"x\">Hello</p>", .xml: "<p id=\"x\"/>", .vue: "<script>const n = 42;</script>", .css: "p { color: red; }", .scss: "$x: 42px;", .less: "@x: 42px;", .c: "int main() { return 42; }", .cpp: "class Hello {};", .objectivec: "@interface Hello : NSObject", .java: "public class Hello {}", .kotlin: "fun hello() = 42", .go: "func main() {}", .rust: "fn main() {}", .csharp: "public class Hello {}", .ruby: "def hello; 42; end", .sql: "SELECT * FROM table_name", .php: "<?php echo 42;", .dockerfile: "FROM alpine:latest", .ini: "[section]\nx=42", .makefile: "all:\n\techo hello", .diff: "--- a.txt\n+++ b.txt\n-old\n+new", .lua: "local n = 42", .perl: "my $x = 42;", .r: "function(x) { x + 1 }", .graphql: "query { user(id: 42) { name } }"]
        XCTAssertEqual(samples.count, CodeLanguage.allCases.count - 1)
        for language in CodeLanguage.allCases where language != .plain {
            XCTAssertFalse(CodeHighlighter.tokens(in: samples[language] ?? "", language: language).isEmpty, "语法未加载: \(language)")
        }
    }

    func testUTF16RangesAreOrderedAndNeverSplitEmoji() {
        let source = "// 中文 😀\nlet message = \"你好 🧑🏽‍💻\"\nlet value = 42\n"
        let ns = source as NSString
        let tokens = CodeHighlighter.tokens(in: source, language: .swift)
        var end = 0
        for token in tokens {
            XCTAssertGreaterThanOrEqual(token.range.location, end)
            XCTAssertLessThanOrEqual(NSMaxRange(token.range), ns.length)
            XCTAssertNotNil(Range(token.range, in: source), "不得拆开 Unicode 字符")
            end = NSMaxRange(token.range)
        }
        XCTAssertEqual(kind("你好", in: source, language: .swift), .string)
        XCTAssertEqual(kind("42", in: source, language: .swift), .number)
    }

    func testBoundsAndUnknownFallback() {
        XCTAssertTrue(CodeHighlighter.tokens(in: "let n = 42", language: .plain).isEmpty)
        XCTAssertTrue(CodeHighlighter.tokens(in: String(repeating: "x", count: CodeHighlighter.maximumLength + 1), language: .javascript).isEmpty)
        let long = String(repeating: "x", count: CodeHighlighter.maximumLineLength + 1)
        let source = "const first = 1;\n" + long + "\nconst last = 2;"
        let tokens = CodeHighlighter.tokens(in: source, language: .javascript)
        let longRange = (source as NSString).range(of: long)
        XCTAssertFalse(tokens.contains { NSIntersectionRange($0.range, longRange).length > 0 })
        XCTAssertEqual(kind("last", in: source, language: .javascript), nil)
        XCTAssertEqual(kind("2", in: source, language: .javascript), .number)
        // A parse failure or oversized document must not poison the shared parser.
        XCTAssertFalse(CodeHighlighter.tokens(in: "let n = 42", language: .swift).isEmpty)
    }

    @MainActor func testNativeTypingRefreshUndoSelectionScrollAndAppearance() async throws {
        _ = NSApplication.shared
        let original = "/* comment\nlet hidden = 42\n*/\n" + String(repeating: "let value = \"中文 😀\"\n", count: 90)
        let doc = LocalFileDocument(url: URL(fileURLWithPath: "/tmp/highlight.swift"), text: original, data: Data(original.utf8), isPreview: false)
        let host = NSHostingView(rootView: SyntaxEditor(document: doc, onChange: { doc.text = $0 }, onSave: {}))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; window.appearance = NSAppearance(named: .aqua); window.orderFront(nil)
        defer { window.orderOut(nil) }
        var editor: CodeTextView?
        try await eventually { host.layoutSubtreeIfNeeded(); editor = self.find(in: host); return editor != nil }
        let view = try XCTUnwrap(editor)
        let hidden = (original as NSString).range(of: "hidden").location
        try await eventually { self.isColor(view, at: hidden, kind: .comment, dark: false) }
        XCTAssertFalse(doc.isDirty, "高亮不能标记文档为已修改")
        let scroll = try XCTUnwrap(view.enclosingScrollView)
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 250)); scroll.reflectScrolledClipView(scroll.contentView)
        view.setSelectedRange(NSRange(location: 10, length: 0))
        let origin = scroll.contentView.bounds.origin
        // Recoloring must preserve selection, scroll and the original text.
        window.appearance = NSAppearance(named: .darkAqua)
        try await eventually { self.isColor(view, at: hidden, kind: .comment, dark: true) }
        XCTAssertEqual(view.selectedRange(), NSRange(location: 10, length: 0))
        XCTAssertEqual(scroll.contentView.bounds.origin, origin)
        XCTAssertEqual(doc.text, original)
        window.makeFirstResponder(view)
        // Closing the comment early changes tokenization on the next line.
        view.insertText("*/", replacementRange: NSRange(location: 10, length: 0))
        let newLet = (view.string as NSString).range(of: "let hidden").location
        try await eventually { self.isColor(view, at: newLet, kind: .keyword, dark: true) }
        XCTAssertTrue(doc.isDirty)
        let selection = view.selectedRange()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(view.selectedRange(), selection)
        XCTAssertTrue(view.undoManager?.canUndo == true)
        view.undoManager?.undo()
        try await eventually { doc.text == original && self.isColor(view, at: hidden, kind: .comment, dark: true) }
        XCTAssertFalse(doc.isDirty)
        // Queue a large old parse then replace it immediately. It must never repaint the new text.
        doc.text = String(repeating: "let stale = 42\n", count: 4000)
        try await Task.sleep(nanoseconds: 20_000_000)
        doc.text = "// latest only"
        try await eventually { view.string == doc.text && self.isColor(view, at: 4, kind: .comment, dark: true) }
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(view.string, "// latest only")
        XCTAssertTrue(isColor(view, at: 4, kind: .comment, dark: true))
    }

    @MainActor func testEditorFontSizeFollowsSettingsImmediately() async throws {
        _ = NSApplication.shared
        let preferences = Preferences.shared
        let original = preferences.terminal
        let document = LocalFileDocument(url: URL(fileURLWithPath: "/tmp/font-size.swift"), text: "let value = 1\n", data: Data("let value = 1\n".utf8), isPreview: false)
        let host = NSHostingView(rootView: SyntaxEditor(document: document, onChange: { document.text = $0 }, onSave: {}))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; window.orderFront(nil)
        defer {
            preferences.terminal = original
            window.orderOut(nil)
        }
        var editor: CodeTextView?
        try await eventually { host.layoutSubtreeIfNeeded(); editor = self.find(in: host); return editor != nil }
        let view = try XCTUnwrap(editor)
        preferences.terminal.fontSize = 24
        try await eventually { abs((view.font?.pointSize ?? 0) - 24) < 0.01 }
        XCTAssertEqual(view.font?.pointSize ?? 0, CGFloat(24), accuracy: 0.01)
    }

    @MainActor func testMarkdownPreviewFontSizeFollowsSettingsImmediately() async throws {
        _ = NSApplication.shared
        let preferences = Preferences.shared
        let original = preferences.terminal
        let host = NSHostingView(rootView: MarkdownPreview(source: "# Heading\n\nBody", documentURL: URL(fileURLWithPath: "/tmp/font-size.md"), rootURL: URL(fileURLWithPath: "/tmp")))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; window.orderFront(nil)
        defer {
            preferences.terminal = original
            window.orderOut(nil)
        }
        var web: WKWebView?
        for _ in 0..<120 {
            host.layoutSubtreeIfNeeded()
            web = findWebView(in: host)
            if web != nil { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let preview = try XCTUnwrap(web)
        preferences.terminal.fontSize = 24
        var size = ""
        for _ in 0..<160 {
            size = (try? await preview.evaluateJavaScript("getComputedStyle(document.body).fontSize") as? String) ?? ""
            if size == "24px" { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Markdown 预览未应用设置字号，实际为 \(size)")
    }

    @MainActor private func isColor(_ view: NSTextView, at index: Int, kind: CodeToken.Kind, dark: Bool) -> Bool {
        guard let color = view.textStorage?.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor else { return false }
        var equal = false
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            guard let rgb = color.usingColorSpace(.sRGB), let expected = CodePalette.color(kind).usingColorSpace(.sRGB) else { return }
            equal = abs(rgb.redComponent - expected.redComponent) < 0.002 && abs(rgb.greenComponent - expected.greenComponent) < 0.002 && abs(rgb.blueComponent - expected.blueComponent) < 0.002
        }
        return equal
    }
    @MainActor private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<120 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("等待高亮超时", file: file, line: line)
        throw NSError(domain: "HighlightingTests", code: 1)
    }
    @MainActor private func find(in view: NSView) -> CodeTextView? {
        if let result = view as? CodeTextView { return result }
        for child in view.subviews { if let result = find(in: child) { return result } }
        return nil
    }
    @MainActor private func findWebView(in view: NSView) -> WKWebView? {
        if let result = view as? WKWebView { return result }
        for child in view.subviews { if let result = findWebView(in: child) { return result } }
        return nil
    }
}
