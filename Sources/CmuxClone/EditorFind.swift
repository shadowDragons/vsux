import AppKit
import Combine

/// In-memory state belongs to the document, never to a terminal or Markdown preview.
@MainActor
final class EditorFindSession {
    var query = WorkspaceSearchQuery()
    var replacement = ""
    var visible = false
    var replaceVisible = false
    var history: [String] = []
    func remember() {
        guard !query.text.isEmpty else { return }
        history.removeAll { $0 == query.text }
        history.insert(query.text, at: 0)
        history = Array(history.prefix(50))
    }
}

struct EditorFindResult {
    var ranges: [NSRange] = []
    var limitHit = false
    var error: String?
}

enum EditorFindEngine {
    static let limit = 19_999
    static func search(_ source: String, query: WorkspaceSearchQuery, scope: NSRange? = nil,
                       cancelled: () -> Bool = { false }) -> EditorFindResult {
        guard !query.text.isEmpty else { return EditorFindResult() }
        let expression: NSRegularExpression
        do { expression = try query.expression() }
        catch { return EditorFindResult(error: L("正则表达式无效")) }
        let length = (source as NSString).length
        let range = scope ?? NSRange(location: 0, length: length)
        guard range.location != NSNotFound, range.location >= 0, range.length >= 0,
              range.location <= length, range.length <= length - range.location else { return EditorFindResult() }
        var output = EditorFindResult()
        let deadline = ProcessInfo.processInfo.systemUptime + 0.5
        expression.enumerateMatches(in: source, options: [.reportProgress, .withTransparentBounds, .withoutAnchoringBounds], range: range) { match, _, stop in
            if cancelled() { stop.pointee = true; return }
            if ProcessInfo.processInfo.systemUptime > deadline {
                output.error = L("查找超时，请简化表达式")
                stop.pointee = true; return
            }
            guard let match, match.range.location >= range.location, NSMaxRange(match.range) <= NSMaxRange(range) else { return }
            if output.ranges.count == limit { output.limitHit = true; stop.pointee = true; return }
            output.ranges.append(match.range)
        }
        if output.error != nil { output.ranges = [] }
        return output
    }

    /// VS Code expands a multiline selection to complete lines, excluding a final column 1.
    static func scope(_ selection: NSRange, in source: String) -> NSRange? {
        let ns = source as NSString
        guard selection.length > 0, selection.location != NSNotFound, NSMaxRange(selection) <= ns.length else { return nil }
        let selected = ns.substring(with: selection)
        guard selected.contains(where: \.isNewline) else { return selection }
        let start = ns.lineRange(for: NSRange(location: selection.location, length: 0)).location
        let last = ns.lineRange(for: NSRange(location: NSMaxRange(selection) - 1, length: 0))
        var end = NSMaxRange(last)
        while end > start, [10, 13].contains(ns.character(at: end - 1)) { end -= 1 }
        return NSRange(location: start, length: end - start)
    }

    static func seed(in source: String, selection: NSRange) -> String? {
        let ns = source as NSString
        guard selection.location != NSNotFound, NSMaxRange(selection) <= ns.length else { return nil }
        if selection.length > 0 {
            let value = ns.substring(with: selection)
            return selection.length < 524_288 && !value.contains(where: \.isNewline) ? value : nil
        }
        let words = try! NSRegularExpression(pattern: #"[\p{L}\p{N}_]+"#)
        let line = ns.lineRange(for: selection)
        return words.matches(in: source, range: line).first {
            $0.range.location <= selection.location && NSMaxRange($0.range) >= selection.location
        }.map { ns.substring(with: $0.range) }
    }

    static func track(_ scope: NSRange, from old: String, to new: String) -> NSRange {
        let a = old as NSString, b = new as NSString
        var prefix = 0, suffix = 0
        while prefix < min(a.length, b.length), a.character(at: prefix) == b.character(at: prefix) { prefix += 1 }
        while suffix < min(a.length, b.length) - prefix,
              a.character(at: a.length - suffix - 1) == b.character(at: b.length - suffix - 1) { suffix += 1 }
        let end = a.length - suffix, inserted = b.length - prefix - suffix
        let delta = b.length - a.length
        let start = scope.location < prefix ? scope.location : (scope.location > end ? scope.location + delta : prefix)
        let finish = NSMaxRange(scope) < prefix ? NSMaxRange(scope) : (NSMaxRange(scope) > end ? NSMaxRange(scope) + delta : prefix + inserted)
        return NSRange(location: min(start, b.length), length: max(0, min(finish, b.length) - start))
    }

    /// Returns one atomic native edit; all matching uses the unchanged source snapshot.
    static func replacement(in source: String, ranges: [NSRange], query: WorkspaceSearchQuery,
                            value: String) throws -> (range: NSRange, text: String)? {
        guard let first = ranges.first, let last = ranges.last else { return nil }
        let expression = try query.expression()
        let union = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        let mutable = NSMutableString(string: (source as NSString).substring(with: union))
        for range in ranges.reversed() {
            guard let match = expression.firstMatch(in: source, options: [.withTransparentBounds, .withoutAnchoringBounds], range: range), match.range == range else { return nil }
            let text = query.regex ? expression.replacementString(for: match, in: source, offset: 0, template: value) : value
            mutable.replaceCharacters(in: NSRange(location: range.location - union.location, length: range.length), with: text)
        }
        return (union, mutable as String)
    }
}

extension CodeTextView {
    @discardableResult
    func replaceForFind(range: NSRange, text: String) -> Bool {
        guard isEditable, !hasMarkedText(), NSMaxRange(range) <= (string as NSString).length else { return false }
        breakUndoCoalescing()
        undoManager?.beginUndoGrouping()
        let expected = (string as NSString).replacingCharacters(in: range, with: text)
        // NSTextView validates through its delegate and records the replacement for undo.
        insertText(text, replacementRange: range)
        let allowed = string == expected
        undoManager?.endUndoGrouping()
        breakUndoCoalescing()
        return allowed
    }
}
