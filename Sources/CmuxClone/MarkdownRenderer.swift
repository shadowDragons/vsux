import Foundation
import Markdown

/// Parses Markdown as data. Raw HTML is displayed as text, never executed.
struct MarkdownRenderer {
    let documentURL: URL
    let rootURL: URL
    private var slugs: [String: Int] = [:]
    private var usedSlugs: Set<String> = []

    init(documentURL: URL, rootURL: URL) {
        self.documentURL = documentURL
        self.rootURL = rootURL
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    mutating func render(_ source: String) -> String {
        slugs = [:]
        usedSlugs = []
        let document = Document(parsing: source, options: [.disableSmartOpts])
        return node(document) + "<div data-line=\"\(source.components(separatedBy: "\n").count)\"></div>"
    }

    private mutating func children(_ markup: Markup) -> String { markup.children.map { node($0) }.joined() }
    private func mapping(_ markup: Markup) -> String {
        guard let range = markup.range else { return "" }
        return " data-line=\"\(range.lowerBound.line)\" data-end-line=\"\(range.upperBound.line)\""
    }
    private mutating func node(_ markup: Markup) -> String {
        let map = mapping(markup)
        switch markup {
        case let text as Markdown.Text: return Self.escape(text.string)
        case let code as InlineCode: return "<code>\(Self.escape(code.code))</code>"
        case is SoftBreak: return "\n"
        case is LineBreak: return "<br>"
        case let heading as Heading:
            let base = heading.plainText.lowercased().filter { $0.isLetter || $0.isNumber || $0.isWhitespace || $0 == "-" || $0 == "_" }
                .replacingOccurrences(of: " ", with: "-")
            var count = slugs[base, default: 0]
            var slug = count == 0 ? base : "\(base)-\(count)"
            while usedSlugs.contains(slug) { count += 1; slug = "\(base)-\(count)" }
            slugs[base] = count + 1; usedSlugs.insert(slug)
            return "<h\(heading.level) id=\"\(Self.escape(slug))\"\(map)>\(children(heading))</h\(heading.level)>"
        case is Paragraph: return "<p\(map)>\(children(markup))</p>"
        case is Strong: return "<strong>\(children(markup))</strong>"
        case is Emphasis: return "<em>\(children(markup))</em>"
        case is Strikethrough: return "<del>\(children(markup))</del>"
        case is BlockQuote: return "<blockquote\(map)>\(children(markup))</blockquote>"
        case is ThematicBreak: return "<hr\(map)>"
        case is UnorderedList: return "<ul\(map)>\(children(markup))</ul>"
        case let list as OrderedList: return "<ol start=\"\(list.startIndex)\"\(map)>\(children(markup))</ol>"
        case let item as ListItem:
            let checkbox = item.checkbox.map { "<input type=\"checkbox\" disabled\($0 == .checked ? " checked" : "")> " } ?? ""
            return "<li\(map)>\(checkbox)\(children(item))</li>"
        case let code as CodeBlock:
            return "<div class=\"code-block\"><button class=\"copy-code\" title=\"\(Self.escape(L("复制代码块")))\">\(Self.escape(L("复制")))</button><pre\(map)><code class=\"language-\(Self.escape(code.language ?? "text"))\">\(highlight(code.code, language: code.language))</code></pre></div>"
        case let link as Link:
            let destination = link.destination ?? ""
            guard MarkdownLinkPolicy.resolve(destination, document: documentURL, root: rootURL) != .blocked else { return children(link) }
            return "<a href=\"\(Self.escape(destination))\" title=\"\(Self.escape(link.title ?? ""))\">\(children(link))</a>"
        case let image as Markdown.Image:
            let alt = Self.escape(image.plainText)
            guard let url = MarkdownLinkPolicy.localImage(image.source ?? "", document: documentURL, root: rootURL) else {
                return "<span class=\"image-placeholder\">\(Self.escape(L("[图片：\(image.plainText)]")))</span>"
            }
            var components = URLComponents(); components.scheme = "cmux-md"; components.host = "asset"; components.path = url.path
            return "<img src=\"\(Self.escape(components.string ?? ""))\" alt=\"\(alt)\" title=\"\(Self.escape(image.title ?? ""))\">"
        case let html as HTMLBlock: return "<pre\(map)>\(Self.escape(html.rawHTML))</pre>"
        case let html as InlineHTML: return Self.escape(html.rawHTML)
        case let table as Table:
            func alignment(_ index: Int) -> String {
                guard index < table.columnAlignments.count, let value = table.columnAlignments[index] else { return "" }
                return " style=\"text-align:\(value == .center ? "center" : value == .right ? "right" : "left")\""
            }
            let head = table.head.children.enumerated().map { "<th\(alignment($0.offset))>\(children($0.element))</th>" }.joined()
            let body = table.body.children.map { row in
                "<tr\(mapping(row))>" + row.children.enumerated().map { "<td\(alignment($0.offset))>\(children($0.element))</td>" }.joined() + "</tr>"
            }.joined()
            return "<div class=\"table-wrap\"\(map)><table><thead><tr>\(head)</tr></thead><tbody>\(body)</tbody></table></div>"
        default: return children(markup)
        }
    }

    private func highlight(_ source: String, language: String?) -> String {
        let language = CodeLanguage.forFence(language ?? "")
        let ns = source as NSString
        guard ns.length <= 100_000 else { return Self.escape(source) }
        var result = ""; var end = 0
        for token in CodeHighlighter.tokens(in: source, language: language) {
            result += Self.escape(ns.substring(with: NSRange(location: end, length: token.range.location - end)))
            result += "<span class=\"tok-\(token.kind.rawValue)\">\(Self.escape(ns.substring(with: token.range)))</span>"
            end = NSMaxRange(token.range)
        }
        result += Self.escape(ns.substring(from: end))
        return result
    }
}

enum MarkdownLinkTarget: Equatable {
    case anchor(String), local(URL, String?), external(URL), blocked
}

enum MarkdownLinkPolicy {
    static func inside(_ url: URL, root: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        return path == base || path.hasPrefix(base == "/" ? "/" : base + "/")
    }
    static func resolve(_ raw: String, document: URL, root: URL) -> MarkdownLinkTarget {
        guard !raw.isEmpty, !raw.contains("\0") else { return .blocked }
        if raw.hasPrefix("#") { return .anchor(String(raw.dropFirst()).removingPercentEncoding ?? String(raw.dropFirst())) }
        // Foundation otherwise double-encodes an existing %20 when the same
        // destination also contains unescaped Unicode (e.g. 图%20片.png).
        let allowed = CharacterSet.urlFragmentAllowed.union(CharacterSet(charactersIn: "#%[]"))
        guard let encoded = raw.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: encoded, relativeTo: document)?.absoluteURL,
              let scheme = url.scheme?.lowercased() else { return .blocked }
        if ["https", "http", "mailto"].contains(scheme) { return .external(url) }
        guard scheme == "file", url.host == nil || url.host == "" || url.host == "localhost", inside(url, root: root) else { return .blocked }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
        let fragment = components?.fragment; components?.fragment = nil; components?.query = nil
        guard let local = components?.url else { return .blocked }
        return .local(local, fragment)
    }
    static func localImage(_ raw: String, document: URL, root: URL) -> URL? {
        guard case let .local(url, _) = resolve(raw, document: document, root: root),
              ["png", "jpg", "jpeg", "gif", "webp", "avif", "ico", "bmp"].contains(url.pathExtension.lowercased()) else { return nil }
        return url
    }
}
