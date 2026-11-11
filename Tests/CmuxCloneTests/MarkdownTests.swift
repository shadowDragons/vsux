import XCTest
import AppKit
import SwiftUI
import WebKit
@testable import CmuxClone

final class MarkdownTests: XCTestCase {
    let root = URL(fileURLWithPath: "/tmp/markdown-workspace")
    func testGFMRenderingAndSourceMapping() {
        var renderer = MarkdownRenderer(documentURL: root.appendingPathComponent("readme.md"), rootURL: root)
        let html = renderer.render("""
        # 标题

        **加粗** 和 *斜体*，~~删除~~ 与 `代码`。

        - [x] 已完成
        - 普通列表
          - 子项

        > 引用

        | 左 | 右 |
        | :-- | --: |
        | A | B |

        ```swift
        let value = "<tag>"
        ```

        # 标题
        """)
        for expected in ["id=\"标题\"", "id=\"标题-1\"", "data-line=\"1\"", "<strong>加粗</strong>", "<em>斜体</em>", "<del>删除</del>", "<code>代码</code>", "disabled checked", "<blockquote", "<thead>", "text-align:right", "tok-keyword", "&lt;tag&gt;", "copy-code"] {
            XCTAssertTrue(html.contains(expected), "缺少 \(expected)")
        }
    }
    func testHTMLAndDangerousLinksRemainInert() {
        var renderer = MarkdownRenderer(documentURL: root.appendingPathComponent("readme.md"), rootURL: root)
        let html = renderer.render("""
        <script>window.pwned=true</script>

        [危险](javascript:alert(1)) ![远程](https://example.com/a.png)

        ![越界](../secret.png) [正常](guide.md#section)
        """)
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertFalse(html.contains("href=\"javascript:"))
        XCTAssertFalse(html.contains("<img"))
        XCTAssertTrue(html.contains("&lt;script&gt;"))
        XCTAssertTrue(html.contains("href=\"guide.md#section\""))
    }
    func testHeadingAnchorsRemainUniqueWhenSuffixesCollide() {
        var renderer = MarkdownRenderer(documentURL: root.appendingPathComponent("readme.md"), rootURL: root)
        let html = renderer.render("# 标题\n\n# 标题-1\n\n# 标题\n\n# 标题-1")
        for id in ["标题", "标题-1", "标题-2", "标题-1-1"] {
            XCTAssertEqual(html.components(separatedBy: "id=\"\(id)\"").count - 1, 1)
        }
    }
    func testLinkPolicyRejectsTraversalSymlinksAndUnapprovedSchemes() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let document = base.appendingPathComponent("docs/readme.md")
        try FileManager.default.createSymbolicLink(at: base.appendingPathComponent("escape"), withDestinationURL: URL(fileURLWithPath: "/etc"))
        func resolve(_ value: String) -> MarkdownLinkTarget { MarkdownLinkPolicy.resolve(value, document: document, root: base) }
        XCTAssertEqual(resolve("#中文"), .anchor("中文"))
        XCTAssertEqual(resolve("../guide.md#hello"), .local(base.appendingPathComponent("guide.md"), "hello"))
        XCTAssertEqual(resolve("../escape/passwd"), .blocked)
        for bad in ["../../secret.md", "command:workbench.action", "javascript:alert(1)", "data:text/html,hello", "file://other-host/etc/passwd"] { XCTAssertEqual(resolve(bad), .blocked) }
        guard case .external = resolve("https://example.com") else { return XCTFail("HTTPS 应交给系统浏览器") }
        XCTAssertEqual(MarkdownLinkPolicy.localImage("图%20片.png", document: document, root: base)?.lastPathComponent, "图 片.png")
        XCTAssertNil(MarkdownLinkPolicy.localImage("https://example.com/a.png", document: document, root: base))
    }

    @MainActor func testLivePreviewImagesLinksAndBidirectionalScrollInRealViews() async throws {
        _ = NSApplication.shared
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in NSColor.systemBlue.setFill(); rect.fill(); return true }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: base.appendingPathComponent("图 片.png"))
        let file = base.appendingPathComponent("readme.md")
        let source = "# Live Preview\n\n![示例](图%20片.png)\n\n[下一篇](next.md#target)\n\n" + (1...100).map { "## Section \($0)\n\nParagraph \($0) with **bold** and `code`.\n\n" }.joined()
        try Data(source.utf8).write(to: file)
        let model = FileWorkspaceModel(rootURL: base); model.open(file)
        let document = try XCTUnwrap(model.selectedDocument); document.markdownPreview = true
        let host = NSHostingView(rootView: FileEditorArea(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; window.orderFront(nil)
        defer { window.orderOut(nil) }
        var web: WKWebView?
        try await eventually {
            host.layoutSubtreeIfNeeded(); web = self.find(WKWebView.self, in: host)
            guard let web else { return false }
            return (try? await self.js(web, "document.querySelector('h1')?.textContent")) as? String == "Live Preview"
        }
        let preview = try XCTUnwrap(web)
        let previewWidth = preview.frame.width
        try await eventually { (try? await self.js(preview, "document.querySelector('img')?.naturalWidth")) as? Int == bitmap.pixelsWide }
        model.update(document, text: source.replacingOccurrences(of: "Live Preview", with: "Unsaved Live Update"))
        try await eventually { (try? await self.js(preview, "document.querySelector('h1')?.textContent")) as? String == "Unsaved Live Update" }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), source, "预览不得隐式保存文件")
        XCTAssertTrue(document.isDirty)
        XCTAssertEqual(preview.frame.width, previewWidth, accuracy: 1, "实时更新不得改变分栏宽度")
        let editor = try XCTUnwrap(find(CodeTextView.self, in: host))
        let scroll = try XCTUnwrap(editor.enclosingScrollView)
        editor.layoutManager?.ensureLayout(for: editor.textContainer!)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 1800)); scroll.reflectScrolledClipView(scroll.contentView)
        try await eventually { ((try? await self.js(preview, "scrollY")) as? Double ?? 0) > 500 }
        try await Task.sleep(nanoseconds: 250_000_000)
        let oldY = scroll.contentView.bounds.minY
        _ = try await js(preview, "window.scrollTo(0,scrollY+1600)")
        try await eventually { scroll.contentView.bounds.minY > oldY + 100 }
        let settled = scroll.contentView.bounds.minY
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(scroll.contentView.bounds.minY, settled, accuracy: 5, "双向同步不得形成滚动循环")
        XCTAssertEqual(preview.frame.width, previewWidth, accuracy: 1, "滚动同步不得挤窄预览")
        // Reading mode must reuse both views, protect the hidden editor, and preserve undo history.
        window.makeFirstResponder(editor)
        editor.insertText("\n\nDraft note.", replacementRange: NSRange(location: (editor.string as NSString).length, length: 0))
        try await eventually { document.text.hasSuffix("Draft note.") }
        XCTAssertTrue(editor.undoManager?.canUndo == true)
        _ = try await js(preview, "[...document.querySelectorAll('#outline-list a')].find(a=>a.textContent==='Section 50').click()")
        try await eventually { (try? await self.js(preview, "document.querySelector('#outline-list [aria-current]').textContent")) as? String == "Section 50" }
        document.markdownPreviewOnly = true
        try await eventually { preview.frame.width > previewWidth * 1.9 && !editor.isEditable }
        XCTAssertTrue(find(WKWebView.self, in: host) === preview, "切换布局不得重建预览")
        XCTAssertFalse(window.firstResponder === editor, "隐藏源码后不得继续接收键盘输入")
        XCTAssertTrue(editor.undoManager?.canUndo == true)
        let readingPosition = try await js(preview, "document.querySelector('#outline-list [aria-current]').textContent")
        XCTAssertEqual(readingPosition as? String, "Section 50")
        _ = try await js(preview, "[...document.querySelectorAll('#outline-list a')].find(a=>a.textContent==='Section 75').click()")
        try await eventually { (try? await self.js(preview, "document.querySelector('#outline-list [aria-current]').textContent")) as? String == "Section 75" }
        document.markdownPreviewOnly = false
        try await eventually { abs(preview.frame.width - previewWidth) < 1 && editor.isEditable }
        XCTAssertTrue(find(CodeTextView.self, in: host) === editor, "恢复分栏不得重建编辑器或丢失撤销记录")
        let restoredPosition = try await js(preview, "document.querySelector('#outline-list [aria-current]').textContent")
        XCTAssertEqual(restoredPosition as? String, "Section 75")
        editor.undoManager?.undo()
        try await eventually { !document.text.hasSuffix("Draft note.") }
        XCTAssertTrue(document.isDirty)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), source)
        // Verify the current rendered HTML cannot execute document-supplied scripts.
        model.update(document, text: "# Safety\n\n<script>window.pwned=1</script>\n\n[坏链接](javascript:alert(1))")
        try await eventually { (try? await self.js(preview, "document.querySelector('h1')?.textContent")) as? String == "Safety" }
        let scriptExecuted = try await js(preview, "!!window.pwned || !!document.querySelector('main script') || !!document.querySelector('a[href^=javascript]')")
        XCTAssertEqual(scriptExecuted as? Bool, false)
        // Local Markdown navigation goes through the workspace model and opens a matching preview.
        let destination = "# Destination\n\n" + String(repeating: "Intro paragraph.\n\n", count: 50) + "## Target\n\n" + String(repeating: "After paragraph.\n\n", count: 50)
        try Data(destination.utf8).write(to: base.appendingPathComponent("next.md"))
        document.markdownPreviewOnly = true
        model.update(document, text: "# Links\n\n[下一篇](next.md#target)")
        try await eventually { (try? await self.js(preview, "document.querySelector('a')?.textContent")) as? String == "下一篇" }
        _ = try await js(preview, "document.querySelector('a').click()")
        try await eventually { model.selectedDocument?.url.lastPathComponent == "next.md" && model.selectedDocument?.markdownPreview == true }
        XCTAssertEqual(model.selectedDocument?.markdownAnchor, "target")
        XCTAssertEqual(model.selectedDocument?.markdownPreviewOnly, true)
        try await eventually {
            guard let linked = self.find(WKWebView.self, in: host),
                  (try? await self.js(linked, "document.querySelector('h1')?.textContent")) as? String == "Destination" else { return false }
            return ((try? await self.js(linked, "scrollY")) as? Double ?? 0) > 500
        }
        // A retained tab keeps its own preview, and closing/reopening the pane works.
        model.selectedDocumentID = document.id
        try await eventually {
            guard let restored = self.find(WKWebView.self, in: host) else { return false }
            return (try? await self.js(restored, "document.querySelector('h1')?.textContent")) as? String == "Links"
        }
        document.markdownPreview = false
        try await eventually { self.find(WKWebView.self, in: host) == nil }
        document.markdownPreview = true
        try await eventually {
            guard let reopened = self.find(WKWebView.self, in: host) else { return false }
            return (try? await self.js(reopened, "document.querySelector('h1')?.textContent")) as? String == "Links"
        }
    }

    @MainActor func testOutlineNavigationLiveUpdatesAndVisibility() async throws {
        _ = NSApplication.shared
        let source = "# 文档\n\n" + (1...30).map {
            "## 第\($0)章：**操作说明**\n\n" + String(repeating: "正文内容。\n\n", count: 8) + "### 核对结果\n\n确认完成。\n\n"
        }.joined() + "```md\n# 代码块中的标题\n```\n"
        var reportedLine: Double = 0
        func content(_ text: String, outline: Bool = true) -> MarkdownPreview {
            MarkdownPreview(source: text, documentURL: root.appendingPathComponent("readme.md"), rootURL: root,
                showOutline: outline, onScroll: { reportedLine = $0 })
        }
        let host = NSHostingView(rootView: content(source))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; window.orderFront(nil)
        defer { window.orderOut(nil) }
        var web: WKWebView?
        try await eventually {
            host.layoutSubtreeIfNeeded(); web = self.find(WKWebView.self, in: host)
            guard let web else { return false }
            return (try? await self.js(web, "document.querySelectorAll('#outline-list a').length")) as? Int == 61
        }
        let preview = try XCTUnwrap(web)
        let firstChildDepth = try await js(preview, "document.querySelectorAll('#outline-list a')[2].style.getPropertyValue('--depth')")
        XCTAssertEqual(firstChildDepth as? String, "2")
        let plainTitle = try await js(preview, "document.querySelectorAll('#outline-list a')[1].textContent")
        XCTAssertEqual(plainTitle as? String, "第1章：操作说明")
        // Repeated Chinese titles must navigate to their own heading, and report its source line.
        _ = try await js(preview, "document.querySelectorAll('#outline-list a')[30].click()")
        try await eventually {
            (try? await self.js(preview, "Math.abs(document.querySelectorAll('main h3')[14].getBoundingClientRect().top)<3 && document.querySelectorAll('#outline-list a')[30].getAttribute('aria-current')==='location'")) as? Bool == true
        }
        let targetLine = try await js(preview, "+document.querySelectorAll('main h3')[14].dataset.line")
        XCTAssertEqual(reportedLine, try XCTUnwrap(targetLine as? Double))
        // Scrolling updates the active outline entry without a click.
        _ = try await js(preview, "document.querySelectorAll('main h2')[20].scrollIntoView()")
        try await eventually {
            (try? await self.js(preview, "document.querySelector('#outline-list [aria-current]').textContent")) as? String == "第21章：操作说明"
        }
        let beforeToggle = try await js(preview, "topLine()") as? Double
        host.rootView = content(source, outline: false)
        try await eventually { (try? await self.js(preview, "document.getElementById('markdown-outline').hidden")) as? Bool == true }
        let afterToggle = try await js(preview, "topLine()") as? Double
        XCTAssertEqual(try XCTUnwrap(beforeToggle), try XCTUnwrap(afterToggle), accuracy: 3)
        let activeAfterToggle = try await js(preview, "document.querySelector('#outline-list [aria-current]').textContent")
        XCTAssertEqual(activeAfterToggle as? String, "第21章：操作说明")
        host.rootView = content(source)
        try await eventually { (try? await self.js(preview, "document.getElementById('markdown-outline').hidden")) as? Bool == false }
        window.setContentSize(NSSize(width: 500, height: 650))
        try await eventually {
            (try? await self.js(preview, "innerWidth===500 && document.querySelector('#outline-list [aria-current]').textContent==='第21章：操作说明' && document.documentElement.scrollWidth<=innerWidth")) as? Bool == true
        }
        // Heading IDs that match the shell must not acquire sidebar styling or change UI labels.
        host.rootView = content("# markdown-outline\n\n## outline-title\n\n## outline-empty\n\n正文")
        try await eventually { (try? await self.js(preview, "document.querySelectorAll('#outline-list a').length")) as? Int == 3 }
        let shellCollision = try await js(preview, "getComputedStyle(document.querySelector('main h1')).position==='static' && document.querySelectorAll('main h2')[0].textContent==='outline-title'")
        XCTAssertEqual(shellCollision as? Bool, true)
        // An edit rebuilds the outline safely; a document with no headings shows an empty state.
        host.rootView = content("## 更新后的 `标题` <img onerror=alert(1)>\n\n正文")
        try await eventually { (try? await self.js(preview, "document.querySelectorAll('#outline-list a').length")) as? Int == 1 }
        let injectedElement = try await js(preview, "!!document.querySelector('#outline-list img')")
        XCTAssertEqual(injectedElement as? Bool, false)
        host.rootView = content("没有标题的正文。")
        try await eventually { (try? await self.js(preview, "document.querySelectorAll('#outline-list a').length===0 && !document.getElementById('outline-empty').hidden && document.getElementById('outline-empty').textContent.length>0")) as? Bool == true }
    }

    @MainActor func testReturningToEditorRestoresSelectionAndScroll() async throws {
        _ = NSApplication.shared
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let source = (1...200).map { "Line \($0) " + String(repeating: "content ", count: 40) }.joined(separator: "\n")
        let file = base.appendingPathComponent("readme.md")
        try Data(source.utf8).write(to: file)
        let model = FileWorkspaceModel(rootURL: base); model.open(file, preview: false)
        let document = try XCTUnwrap(model.selectedDocument)
        let host = NSHostingView(rootView: AnyView(FileEditorArea(model: model)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; window.orderFront(nil)
        defer { window.orderOut(nil) }
        try await eventually { host.layoutSubtreeIfNeeded(); return self.find(CodeTextView.self, in: host) != nil }
        let editor = try XCTUnwrap(find(CodeTextView.self, in: host))
        let scroll = try XCTUnwrap(editor.enclosingScrollView)
        // A previously consumed search result must not be replayed on every return.
        document.searchSelection = EditorSelectionRequest(range: NSRange(location: 20, length: 4))
        try await eventually { editor.selectedRange() == NSRange(location: 20, length: 4) }
        editor.layoutManager?.ensureLayout(for: editor.textContainer!)
        let selection = (source as NSString).range(of: "Line 90")
        editor.setSelectedRange(selection)
        scroll.contentView.scroll(to: NSPoint(x: 150, y: 1400)); scroll.reflectScrolledClipView(scroll.contentView)
        let origin = scroll.contentView.bounds.origin
        // The content switch removes FileEditorArea, just as switching to the terminal does.
        for _ in 0..<2 {
            host.rootView = AnyView(Text("Terminal"))
            try await eventually { host.layoutSubtreeIfNeeded(); return self.find(CodeTextView.self, in: host) == nil }
            host.rootView = AnyView(FileEditorArea(model: model))
            try await eventually { host.layoutSubtreeIfNeeded(); return self.find(CodeTextView.self, in: host) != nil }
            let restored = try XCTUnwrap(find(CodeTextView.self, in: host))
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertEqual(restored.selectedRange(), selection)
            XCTAssertEqual(restored.enclosingScrollView?.contentView.bounds.origin.x ?? 0, origin.x, accuracy: 1)
            XCTAssertEqual(restored.enclosingScrollView?.contentView.bounds.origin.y ?? 0, origin.y, accuracy: 1)
        }
        host.rootView = AnyView(Text("Terminal"))
        try await eventually { host.layoutSubtreeIfNeeded(); return self.find(CodeTextView.self, in: host) == nil }
        let newTarget = (source as NSString).range(of: "Line 150")
        document.searchSelection = EditorSelectionRequest(range: newTarget)
        host.rootView = AnyView(FileEditorArea(model: model))
        try await eventually { host.layoutSubtreeIfNeeded(); return self.find(CodeTextView.self, in: host)?.selectedRange() == newTarget }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(find(CodeTextView.self, in: host)?.selectedRange(), newTarget, "新的搜索跳转应优先于旧位置")
        // Each open tab remembers its own position as well.
        let secondFile = base.appendingPathComponent("other.txt")
        try Data("Other file".utf8).write(to: secondFile)
        model.open(secondFile, preview: false)
        try await eventually { self.find(CodeTextView.self, in: host)?.string == "Other file" }
        model.selectedDocumentID = document.id
        try await eventually { self.find(CodeTextView.self, in: host)?.selectedRange() == newTarget }
        document.markdownPreview = true
        try await eventually {
            guard let web = self.find(WKWebView.self, in: host) else { return false }
            return (try? await self.js(web, "document.querySelector('main')?.textContent.includes('Line 200')")) as? Bool == true
        }
        let preview = try XCTUnwrap(find(WKWebView.self, in: host))
        try await Task.sleep(nanoseconds: 200_000_000)
        _ = try await js(preview, "window.scrollTo(0,1800)")
        try await Task.sleep(nanoseconds: 200_000_000)
        let currentLine = try await js(preview, "topLine()") as? Double
        let readingLine = try XCTUnwrap(currentLine)
        XCTAssertGreaterThan(readingLine, 1)
        host.rootView = AnyView(Text("Terminal"))
        try await eventually { host.layoutSubtreeIfNeeded(); return self.find(WKWebView.self, in: host) == nil }
        host.rootView = AnyView(FileEditorArea(model: model))
        try await eventually {
            host.layoutSubtreeIfNeeded()
            guard let web = self.find(WKWebView.self, in: host),
                  let line = (try? await self.js(web, "topLine()")) as? Double else { return false }
            return abs(line - readingLine) < 1
        }
    }

    @MainActor private func js(_ web: WKWebView, _ script: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            web.evaluateJavaScript(script) { value, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: value) }
            }
        }
    }
    @MainActor private func eventually(_ condition: () async throws -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<120 {
            if try await condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("等待界面状态超时", file: file, line: line)
        throw NSError(domain: "MarkdownTests", code: 1)
    }
    @MainActor private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let result = view as? T { return result }
        for child in view.subviews { if let result = find(type, in: child) { return result } }
        return nil
    }
}
