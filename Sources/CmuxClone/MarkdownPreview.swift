import AppKit
import SwiftUI
import WebKit

struct EditorScrollRequest: Equatable {
    let id = UUID()
    let line: Double
}

struct MarkdownEditorPane: View {
    @ObservedObject private var languagePreferences = LanguagePreferences.shared
    @ObservedObject var model: FileWorkspaceModel
    @ObservedObject var document: LocalFileDocument
    var onSelection: (Int, Int) -> Void
    @State private var previewLine: Double = 1
    @State private var editorScroll: EditorScrollRequest?
    @State private var syncScroll = true
    @State private var fraction = 0.5
    @State private var dragStart: CGFloat?
    var body: some View {
        let _ = languagePreferences.language
        GeometryReader { geometry in
            let split = document.language == .markdown && document.markdownPreview
            let available = max(0, geometry.size.width - 5)
            let first = max(min(180, available * 0.45), min(available - min(220, available * 0.45), available * fraction))
            HStack(spacing: 0) {
                SyntaxEditor(document: document, onChange: { model.update(document, text: $0) },
                    onSave: { _ = model.save(document) }, onSelection: onSelection,
                    onScroll: { if syncScroll { previewLine = $0 } }, scrollRequest: editorScroll)
                    .frame(width: split ? first : geometry.size.width)
                if split {
                    Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1).frame(width: 5).contentShape(Rectangle())
                        .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            if dragStart == nil { dragStart = first }
                            fraction = max(0.05, min(0.95, ((dragStart ?? first) + value.translation.width) / max(1, available)))
                        }.onEnded { _ in dragStart = nil })
                        .simultaneousGesture(TapGesture(count: 2).onEnded { fraction = 0.5 })
                        .accessibilityLabel(L("调整 Markdown 分栏宽度"))
                        .accessibilityAdjustableAction { direction in
                            fraction = max(0.05, min(0.95, fraction + (direction == .increment ? 0.05 : -0.05)))
                        }
                    preview.frame(width: available - first)
                }
            }.frame(height: geometry.size.height)
        }
    }
    private var preview: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.richtext").foregroundStyle(.secondary)
                Text(L("预览 \(document.url.lastPathComponent)")).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                Toggle(L("同步滚动"), isOn: $syncScroll).toggleStyle(.checkbox).pointingHandCursor()
                IconButton(symbol: "xmark", help: L("关闭 Markdown 预览")) { document.markdownPreview = false }
            }.font(.system(size: 11)).padding(.horizontal, 10).frame(height: 32).background(.bar)
            Divider()
            MarkdownPreview(source: document.text, documentURL: document.url, rootURL: model.rootURL,
                sourceLine: syncScroll ? previewLine : nil, anchor: document.markdownAnchor,
                onScroll: { if syncScroll { previewLine = $0; editorScroll = EditorScrollRequest(line: $0) } }, onLink: openLink)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func openLink(_ raw: String) {
        switch MarkdownLinkPolicy.resolve(raw, document: document.url, root: model.rootURL) {
        case let .external(url): NSWorkspace.shared.open(url)
        case let .local(url, fragment):
            model.open(url, preview: false)
            if let opened = model.selectedDocument, opened.url.standardizedFileURL == url.standardizedFileURL, opened.language == .markdown {
                opened.markdownPreview = true; opened.markdownAnchor = fragment
            }
        case .anchor, .blocked: break
        }
    }
}

/// Document renderer only: generated local HTML, isolated storage, no browsing UI.
struct MarkdownPreview: NSViewRepresentable {
    @ObservedObject private var languagePreferences = LanguagePreferences.shared
    @ObservedObject private var preferences = Preferences.shared
    let source: String
    let documentURL: URL
    let rootURL: URL
    var sourceLine: Double?
    var anchor: String?
    var onScroll: (Double) -> Void = { _ in }
    var onLink: (String) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(MarkdownImageHandler(root: rootURL), forURLScheme: "cmux-md")
        config.userContentController.add(context.coordinator, name: "markdown")
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.setAccessibilityIdentifier("markdown-preview")
        web.setAccessibilityLabel(L("Markdown 预览"))
        context.coordinator.web = web
        web.loadHTMLString(Self.shell, baseURL: nil)
        context.coordinator.update(self)
        return web
    }
    func updateNSView(_ web: WKWebView, context: Context) { context.coordinator.update(self) }
    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
        coordinator.work?.cancel(); web.stopLoading()
        web.configuration.userContentController.removeScriptMessageHandler(forName: "markdown")
        web.navigationDelegate = nil
    }
    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: MarkdownPreview
        weak var web: WKWebView?
        var ready = false
        var work: DispatchWorkItem?
        private var lastSource: String?
        private var lastLanguage: AppLanguage?
        private var generation = UUID()
        private var html: String?
        private var lastLine: Double?
        private var lastAnchor: String?
        private var lastFontSize: CGFloat?
        init(_ parent: MarkdownPreview) { self.parent = parent }
        func update(_ value: MarkdownPreview) {
            parent = value
            web?.setAccessibilityLabel(L("Markdown 预览"))
            pushFontSize()
            let language = Localization.language
            if value.source != lastSource || language != lastLanguage {
                lastSource = value.source; lastLanguage = language; work?.cancel()
                let ticket = UUID(); generation = ticket
                let work = DispatchWorkItem { [weak self] in
                    var renderer = MarkdownRenderer(documentURL: value.documentURL, rootURL: value.rootURL)
                    let html = renderer.render(value.source)
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.generation == ticket else { return }
                        self.html = html; self.pushContent()
                    }
                }
                self.work = work
                Self.renderQueue.asyncAfter(deadline: .now() + 0.12, execute: work)
            }
            pushPosition()
        }
        private static let renderQueue = DispatchQueue(label: "local.markdown.render", qos: .userInitiated)
        private func pushContent() {
            guard ready, let html else { return }
            pushFontSize()
            web?.evaluateJavaScript("setLanguage(\(Self.json(L("复制"))),\(Self.json(L("已复制"))),\(Self.json(L("Markdown 预览"))),\(Self.json(Localization.language.rawValue)))", completionHandler: nil)
            web?.evaluateJavaScript("setContent(\(Self.json(html)))", completionHandler: nil)
            if let anchor = parent.anchor, anchor != lastAnchor {
                lastAnchor = anchor; web?.evaluateJavaScript("revealAnchor(\(Self.json(anchor)))", completionHandler: nil)
            }
            else if let line = parent.sourceLine, line.isFinite {
                lastLine = line; web?.evaluateJavaScript("revealLine(\(line))", completionHandler: nil)
            }
        }
        private func pushFontSize() {
            let size = CGFloat(min(40, max(9, parent.preferences.terminal.fontSize)))
            guard ready, size != lastFontSize, let web else { return }
            lastFontSize = size
            web.evaluateJavaScript("document.body && (document.body.style.fontSize='\(size)px')", completionHandler: { _, _ in })
        }
        private func pushPosition() {
            guard ready, html != nil else { return }
            if let anchor = parent.anchor, anchor != lastAnchor {
                lastAnchor = anchor; web?.evaluateJavaScript("revealAnchor(\(Self.json(anchor)))", completionHandler: nil)
            } else if let line = parent.sourceLine, line != lastLine, line.isFinite {
                lastLine = line; web?.evaluateJavaScript("revealLine(\(line))", completionHandler: nil)
            }
        }
        static func json(_ string: String) -> String {
            String(data: try! JSONSerialization.data(withJSONObject: string, options: [.fragmentsAllowed]), encoding: .utf8)!
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true; pushContent()
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Only the initial in-memory shell may navigate. Links are handled by native policy.
            decisionHandler(navigationAction.request.url?.absoluteString == "about:blank" && navigationAction.navigationType == .other ? .allow : .cancel)
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any], let kind = body["type"] as? String else { return }
            if kind == "scroll", let line = body["line"] as? Double, line.isFinite, line >= 1 { parent.onScroll(line) }
            if kind == "link", let href = body["href"] as? String { parent.onLink(href) }
            if kind == "copy", let text = body["text"] as? String {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
            }
        }
    }

    static let shell = #"""
    <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src cmux-md:; style-src 'unsafe-inline'; script-src 'nonce-local-markdown'; base-uri 'none'; form-action 'none'; connect-src 'none'">
    <style>
    :root{color-scheme:light dark;--fg:#24292f;--bg:#fff;--muted:#57606a;--border:#d0d7de;--code:#f6f8fa;--link:#0969da}
    @media(prefers-color-scheme:dark){:root{--fg:#d4d4d4;--bg:#1e1e1e;--muted:#999;--border:#454545;--code:#282828;--link:#6cb6ff}}
    *{box-sizing:border-box}body{color:var(--fg);background:var(--bg);font:var(--body-font-size,14px)/1.6 -apple-system,BlinkMacSystemFont,sans-serif;margin:0;padding:20px 26px 80px;overflow-wrap:break-word}
    main{max-width:980px;margin:auto}h1,h2,h3,h4,h5,h6{line-height:1.25;font-weight:600;margin:24px 0 16px}h1{font-size:2em}h2{font-size:1.5em}h1,h2{border-bottom:1px solid var(--border);padding-bottom:.3em}h3{font-size:1.25em}
    p,pre,blockquote,ul,ol,.table-wrap{margin:0 0 16px}li>p{margin-bottom:8px}li+li{margin-top:4px}ul,ol{padding-left:2em}a{color:var(--link);cursor:pointer;text-decoration:none}a:hover{text-decoration:underline}
    code{font:12px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace;background:var(--code);padding:.15em .35em;border-radius:3px}pre{padding:16px;background:var(--code);overflow:auto;border-radius:3px}pre code{padding:0;background:none;white-space:pre}
    .code-block{position:relative}.copy-code{position:absolute;right:8px;top:6px;color:var(--muted);background:var(--code);border:1px solid var(--border);border-radius:3px;font-size:11px;padding:2px 6px;cursor:pointer}.copy-code:hover{color:var(--fg)}
    blockquote{border-left:4px solid var(--border);padding:0 16px;color:var(--muted)}hr{height:1px;border:0;background:var(--border);margin:24px 0}img{max-width:100%;height:auto}.image-placeholder{color:var(--muted)}
    .table-wrap{overflow:auto}table{border-collapse:collapse}th,td{padding:6px 13px;border:1px solid var(--border)}tr:nth-child(2n){background:var(--code)}input[type=checkbox]{vertical-align:middle}li>input+p{display:inline}
    .tok-keyword{color:#0000ff}.tok-string,.tok-deleted{color:#a31515}.tok-regexp{color:#811f3f}.tok-comment{color:#008000}.tok-number,.tok-inserted{color:#098658}.tok-type{color:#267f99}.tok-function{color:#795e26}.tok-property{color:#0451a5}.tok-tag{color:#800000}.tok-heading{color:#000080}.tok-meta,.tok-control{color:#af00db}
    @media(prefers-color-scheme:dark){.tok-string,.tok-deleted{color:#ce9178}.tok-regexp{color:#d16969}.tok-keyword,.tok-tag,.tok-heading{color:#569cd6}.tok-type{color:#4ec9b0}.tok-number,.tok-inserted{color:#b5cea8}.tok-comment{color:#6a9955}.tok-function{color:#dcdcaa}.tok-property{color:#9cdcfe}.tok-meta,.tok-control{color:#c586c0}}
    </style></head><body><main id="markdown-body" aria-label="Markdown Preview"></main>
    <script nonce="local-markdown">
    let syncUntil=0, timer, desiredLine=1;
    let uiCopy={copy:'Copy',copied:'Copied'};
    function setLanguage(copy,copied,label,language){uiCopy.copy=copy;uiCopy.copied=copied;document.getElementById('markdown-body').setAttribute('aria-label',label);document.documentElement.lang=language;document.querySelectorAll('.copy-code').forEach(b=>b.textContent=copy)}
    function setFontSize(size){document.documentElement.style.setProperty('--body-font-size',size+'px')}
    function markers(){return [...document.querySelectorAll('[data-line]')].filter(e=>!e.querySelector('[data-line]')).map(e=>({e,line:+e.dataset.line,end:+(e.dataset.endLine||e.dataset.line),y:e.getBoundingClientRect().top+scrollY,h:e.getBoundingClientRect().height})).sort((a,b)=>a.y-b.y||a.line-b.line)}
    function topLine(){const m=markers();if(!m.length)return 1;let a=m[0];for(const b of m){if(b.y>scrollY+2)break;a=b}return a.line+Math.max(0,Math.min(1,(scrollY-a.y)/Math.max(1,a.h)))*Math.max(0,a.end-a.line)}
    function revealLine(line){desiredLine=line;const m=markers();if(!m.length)return;let a=m[0];for(const b of m){if(b.line>line)break;a=b}let next=m.find(b=>b.line>Math.max(a.line,a.end));let y=a.y;if(line>a.line){y+=line<=a.end?(line-a.line)/Math.max(1,a.end-a.line+1)*a.h:next?(line-a.line)/Math.max(1,next.line-a.line)*(next.y-a.y):a.h}syncUntil=Date.now()+140;window.scrollTo(0,line<=1?0:Math.max(0,y-2))}
    function revealAnchor(id){const e=document.getElementById(id);if(e){syncUntil=Date.now()+140;desiredLine=+(e.dataset.line||1);e.scrollIntoView();window.webkit.messageHandlers.markdown.postMessage({type:'scroll',line:desiredLine})}}
    function setContent(html){const line=topLine();document.getElementById('markdown-body').innerHTML=html;document.querySelectorAll('img').forEach(i=>i.addEventListener('load',()=>revealLine(desiredLine),{once:true}));revealLine(line)}
    addEventListener('scroll',()=>{clearTimeout(timer);timer=setTimeout(()=>{if(Date.now()>syncUntil){desiredLine=topLine();window.webkit.messageHandlers.markdown.postMessage({type:'scroll',line:desiredLine})}},50)},{passive:true});
    document.addEventListener('click',e=>{const copy=e.target.closest('.copy-code');if(copy){window.webkit.messageHandlers.markdown.postMessage({type:'copy',text:copy.parentElement.querySelector('code').textContent});copy.textContent=uiCopy.copied;setTimeout(()=>copy.textContent=uiCopy.copy,1200);return}const a=e.target.closest('a');if(!a)return;e.preventDefault();const href=a.getAttribute('href');if(href.startsWith('#')){try{revealAnchor(decodeURIComponent(href.slice(1)))}catch{}}else window.webkit.messageHandlers.markdown.postMessage({type:'link',href})});
    </script></body></html>
    """#
}

/// Only bounded raster resources inside the current workspace can enter WebKit.
final class MarkdownImageHandler: NSObject, WKURLSchemeHandler {
    let root: URL
    init(root: URL) { self.root = root }
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let types = ["png":"image/png", "jpg":"image/jpeg", "jpeg":"image/jpeg", "gif":"image/gif", "webp":"image/webp", "avif":"image/avif", "ico":"image/x-icon", "bmp":"image/bmp"]
        guard let requestURL = task.request.url, requestURL.host == "asset" else { task.didFailWithError(URLError(.noPermissionsToReadFile)); return }
        let file = URL(fileURLWithPath: requestURL.path).resolvingSymlinksInPath()
        guard MarkdownLinkPolicy.inside(file, root: root), let type = types[file.pathExtension.lowercased()],
              let size = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), size.isRegularFile == true,
              (size.fileSize ?? .max) <= 16 * 1024 * 1024, let data = try? Data(contentsOf: file) else {
            task.didFailWithError(URLError(.noPermissionsToReadFile)); return
        }
        task.didReceive(URLResponse(url: requestURL, mimeType: type, expectedContentLength: data.count, textEncodingName: nil))
        task.didReceive(data); task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
