import AppKit
import JavaScriptCore

enum CodeLanguage: String, CaseIterable {
    case swift = "Swift", javascript = "JavaScript", typescript = "TypeScript", json = "JSON"
    case python = "Python", shell = "Shell", markdown = "Markdown", yaml = "YAML"
    case html = "HTML", xml = "XML", vue = "Vue", css = "CSS", scss = "SCSS", less = "Less"
    case c = "C", cpp = "C++", objectivec = "Objective-C", java = "Java", kotlin = "Kotlin"
    case go = "Go", rust = "Rust", csharp = "C#", ruby = "Ruby", sql = "SQL", php = "PHP"
    case dockerfile = "Dockerfile", ini = "INI", makefile = "Makefile", diff = "Diff"
    case lua = "Lua", perl = "Perl", r = "R", graphql = "GraphQL", plain = "纯文本"
    var title: String { self == .plain ? L("纯文本") : rawValue }

    var grammar: String {
        switch self {
        case .shell: return "bash"
        case .html: return "xml"
        case .plain: return "plaintext"
        default: return rawValue.lowercased().replacingOccurrences(of: "c++", with: "cpp").replacingOccurrences(of: "c#", with: "csharp").replacingOccurrences(of: "objective-c", with: "objectivec")
        }
    }

    static func forFile(_ url: URL, firstLine: String = "") -> CodeLanguage {
        let name = url.lastPathComponent.lowercased()
        if name == "dockerfile" || name.hasPrefix("dockerfile.") { return .dockerfile }
        if ["makefile", "gnumakefile"].contains(name) { return .makefile }
        if [".zshrc", ".bashrc", ".bash_profile", ".profile"].contains(name) { return .shell }
        switch url.pathExtension.lowercased() {
        case "swift": return .swift
        case "js", "jsx", "mjs", "cjs": return .javascript
        case "ts", "tsx", "cts", "mts": return .typescript
        case "json", "jsonc": return .json
        case "py", "pyi": return .python
        case "sh", "zsh", "bash", "fish": return .shell
        case "md", "markdown", "mdown": return .markdown
        case "yaml", "yml": return .yaml
        case "html", "htm": return .html
        case "xml", "svg", "xsl", "plist": return .xml
        case "vue": return .vue
        case "css": return .css
        case "scss": return .scss
        case "less": return .less
        case "c", "h": return .c
        case "cc", "cpp", "cxx", "hpp", "hxx", "hh": return .cpp
        case "m", "mm": return .objectivec
        case "java", "jav": return .java
        case "kt", "kts": return .kotlin
        case "go": return .go
        case "rs": return .rust
        case "cs", "csx": return .csharp
        case "rb", "rake", "gemspec": return .ruby
        case "sql": return .sql
        case "php", "phtml": return .php
        case "ini", "toml", "cfg", "conf": return .ini
        case "mk": return .makefile
        case "diff", "patch": return .diff
        case "lua": return .lua
        case "pl", "pm": return .perl
        case "r": return .r
        case "graphql", "gql": return .graphql
        default: break
        }
        // Explicit file extensions win. Only extensionless scripts use their shebang.
        guard url.pathExtension.isEmpty, firstLine.hasPrefix("#!") else { return .plain }
        let interpreter = firstLine.lowercased()
        if interpreter.contains("python") { return .python }
        if interpreter.contains("deno") || interpreter.contains("ts-node") { return .typescript }
        if interpreter.contains("node") || interpreter.contains("bun") { return .javascript }
        if interpreter.contains("ruby") { return .ruby }
        if interpreter.contains("perl") { return .perl }
        if ["bash", "zsh", "/sh", " sh", "fish"].contains(where: interpreter.contains) { return .shell }
        return .plain
    }

    static func forFence(_ name: String) -> CodeLanguage {
        let name = name.lowercased().split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        let aliases: [String: CodeLanguage] = ["bash": .shell, "shell": .shell, "javascript": .javascript, "typescript": .typescript, "python": .python, "ruby": .ruby, "objective-c": .objectivec, "objc": .objectivec, "c++": .cpp, "c#": .csharp, "csharp": .csharp, "docker": .dockerfile, "plaintext": .plain, "text": .plain]
        return aliases[name] ?? CodeLanguage.allCases.first { $0.grammar == name } ?? forFile(URL(fileURLWithPath: "code." + name))
    }
}

struct CodeToken: Equatable {
    enum Kind: String, Equatable { case keyword, control, string, regexp, comment, number, type, heading, function, property, tag, meta, inserted, deleted }
    let range: NSRange
    let kind: Kind
}

/// Trusted, bundled grammars parse text as data in JavaScriptCore. User code is never evaluated.
/// A serial worker owns the JS context; only the resulting UTF-16 ranges reach AppKit.
enum CodeHighlighter {
    static let maximumLength = 1_000_000
    static let maximumLineLength = 20_000
    private static let queue = DispatchQueue(label: "local.cmuxclone.highlighting", qos: .userInitiated)
    private static let engine = Engine()

    static func tokens(in text: String, language: CodeLanguage) -> [CodeToken] {
        guard language != .plain, text.utf16.count <= maximumLength else { return [] }
        return queue.sync { engine.tokens(in: text, language: language) }
    }

    @discardableResult static func tokensAsync(in text: String, language: CodeLanguage, completion: @escaping ([CodeToken]) -> Void) -> DispatchWorkItem {
        let work = DispatchWorkItem {
            let result = language != .plain && text.utf16.count <= maximumLength ? engine.tokens(in: text, language: language) : []
            DispatchQueue.main.async { completion(result) }
        }
        queue.async(execute: work)
        return work
    }

    private final class Engine {
        private let context: JSContext?
        init() {
            context = JSContext()
            let packaged = Bundle.main.resourceURL?.appendingPathComponent("CmuxClone_CmuxClone.bundle")
            let bundle = packaged.flatMap(Bundle.init(url:)) ?? Bundle.module
            for name in ["core", "dockerfile", "bridge"] {
                guard let url = bundle.url(forResource: name, withExtension: "js", subdirectory: "Highlighting"),
                      let script = try? String(contentsOf: url, encoding: .utf8) else { continue }
                context?.evaluateScript(script, withSourceURL: url)
            }
        }
        func tokens(in text: String, language: CodeLanguage) -> [CodeToken] {
            guard let context, context.exception == nil,
                  let parse = context.objectForKeyedSubscript("cmuxTokens"), !parse.isUndefined else { return [] }
            context.exception = nil
            let value = parse.call(withArguments: [text, language.grammar, CodeHighlighter.maximumLineLength])
            guard context.exception == nil, let rows = value?.toArray() as? [[Any]] else {
                context.exception = nil
                return []
            }
            let length = text.utf16.count
            var result: [CodeToken] = []
            var end = 0
            for row in rows {
                guard row.count == 3, let start = row[0] as? Int, let count = row[1] as? Int,
                      let style = row[2] as? String, let kind = CodeToken.Kind(rawValue: style),
                      start >= end, count > 0, start <= length, count <= length - start else { return [] }
                result.append(CodeToken(range: NSRange(location: start, length: count), kind: kind))
                end = start + count
            }
            return result
        }
    }
}

/// Light+/Dark+ inspired colors, mapped from syntax roles (no semantic language service).
enum CodePalette {
    static func hex(_ kind: CodeToken.Kind, dark: Bool) -> UInt32 {
        switch kind {
        case .keyword: return dark ? 0x569CD6 : 0x0000FF
        case .control: return dark ? 0xC586C0 : 0xAF00DB
        case .string: return dark ? 0xCE9178 : 0xA31515
        case .regexp: return dark ? 0xD16969 : 0x811F3F
        case .comment: return dark ? 0x6A9955 : 0x008000
        case .number: return dark ? 0xB5CEA8 : 0x098658
        case .type: return dark ? 0x4EC9B0 : 0x267F99
        case .function: return dark ? 0xDCDCAA : 0x795E26
        case .property: return dark ? 0x9CDCFE : 0x0451A5
        case .tag: return dark ? 0x569CD6 : 0x800000
        case .heading: return dark ? 0x569CD6 : 0x000080
        case .meta: return dark ? 0xC586C0 : 0xAF00DB
        case .inserted: return dark ? 0xB5CEA8 : 0x098658
        case .deleted: return dark ? 0xCE9178 : 0xA31515
        }
    }
    static func color(_ kind: CodeToken.Kind) -> NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let value = hex(kind, dark: dark)
            return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
        }
    }
}
