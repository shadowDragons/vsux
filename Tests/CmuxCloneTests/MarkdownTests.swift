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
        // Verify the current rendered HTML cannot execute document-supplied scripts.
        model.update(document, text: "# Safety\n\n<script>window.pwned=1</script>\n\n[坏链接](javascript:alert(1))")
        try await eventually { (try? await self.js(preview, "document.querySelector('h1')?.textContent")) as? String == "Safety" }
        let scriptExecuted = try await js(preview, "!!window.pwned || !!document.querySelector('main script') || !!document.querySelector('a[href^=javascript]')")
        XCTAssertEqual(scriptExecuted as? Bool, false)
        // Local Markdown navigation goes through the workspace model and opens a matching preview.
        let destination = "# Destination\n\n" + String(repeating: "Intro paragraph.\n\n", count: 50) + "## Target\n\n" + String(repeating: "After paragraph.\n\n", count: 50)
        try Data(destination.utf8).write(to: base.appendingPathComponent("next.md"))
        model.update(document, text: "# Links\n\n[下一篇](next.md#target)")
        try await eventually { (try? await self.js(preview, "document.querySelector('a')?.textContent")) as? String == "下一篇" }
        _ = try await js(preview, "document.querySelector('a').click()")
        try await eventually { model.selectedDocument?.url.lastPathComponent == "next.md" && model.selectedDocument?.markdownPreview == true }
        XCTAssertEqual(model.selectedDocument?.markdownAnchor, "target")
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
