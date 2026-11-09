import Foundation

/// TextKit uses UTF-16 offsets. Keep edits and selection mapping in that coordinate space.
enum EditorIndentation {
    struct Edit {
        let range: NSRange
        let text: String
        let selection: NSRange
    }

    static let width = 4

    static func edit(_ text: String, selection: NSRange, outdent: Bool) -> Edit? {
        let source = text as NSString
        guard selection.location != NSNotFound, NSMaxRange(selection) <= source.length else { return nil }
        let first = source.lineRange(for: NSRange(location: selection.location, length: 0)).location
        var contentsEnd = 0
        source.getLineStart(nil, end: nil, contentsEnd: &contentsEnd,
                            for: NSRange(location: selection.location, length: 0))
        let endLine = source.lineRange(for: NSRange(location: NSMaxRange(selection), length: 0)).location
        let wholeLines = selection.length > 0 && (first != endLine ||
            (selection.location == first && NSMaxRange(selection) == contentsEnd))
        if !outdent && !wholeLines {
            let prefix = source.substring(with: NSRange(location: first, length: selection.location - first))
            let spaces = width - visibleWidth(prefix) % width
            return Edit(range: selection, text: String(repeating: " ", count: spaces),
                        selection: NSRange(location: selection.location + spaces, length: 0))
        }

        // A selection ending at column one does not include that final line.
        let lastPosition = selection.length > 0 ? NSMaxRange(selection) - 1 : selection.location
        let last = source.lineRange(for: NSRange(location: lastPosition, length: 0)).location
        var changes: [(range: NSRange, text: String)] = []
        var line = first
        var blockEnd = first
        var firstIndentEnd = first
        while line <= last {
            var end = 0, contentEnd = 0
            source.getLineStart(nil, end: &end, contentsEnd: &contentEnd, for: NSRange(location: line, length: 0))
            var indentEnd = line
            while indentEnd < contentEnd && (source.character(at: indentEnd) == 32 || source.character(at: indentEnd) == 9) {
                indentEnd += 1
            }
            if line == first { firstIndentEnd = indentEnd }
            let oldIndent = source.substring(with: NSRange(location: line, length: indentEnd - line))
            let columns = visibleWidth(oldIndent)
            // Like ShiftCommand, leave truly empty lines alone within a multiline block.
            if !(outdent && columns == 0) && !(first != last && !outdent && contentEnd == line) {
                let target = outdent ? max(0, ((columns - 1) / width) * width) : columns + width - columns % width
                let replacement = String(repeating: " ", count: target)
                if oldIndent != replacement {
                    changes.append((NSRange(location: line, length: indentEnd - line), replacement))
                }
            }
            blockEnd = contentEnd
            if line == last || end <= line { break }
            line = end
        }
        guard !changes.isEmpty else { return nil }
        let range = NSRange(location: first, length: blockEnd - first)
        let replacement = NSMutableString(string: source.substring(with: range))
        for change in changes.reversed() {
            replacement.replaceCharacters(in: NSRange(location: change.range.location - first, length: change.range.length), with: change.text)
        }
        func mapped(_ position: Int) -> Int {
            var delta = 0
            for change in changes {
                if position < change.range.location { break }
                let length = (change.text as NSString).length
                if position <= NSMaxRange(change.range) { return change.range.location + delta + length }
                delta += length - change.range.length
            }
            return position + delta
        }
        var start = mapped(selection.location)
        if selection.length > 0 && selection.location <= firstIndentEnd {
            start = min(start, selection.location)
        }
        let end = mapped(NSMaxRange(selection))
        return Edit(range: range, text: replacement as String, selection: NSRange(location: start, length: max(0, end - start)))
    }

    private static func visibleWidth(_ text: String) -> Int {
        text.reduce(0) { column, character in
            if character == "\t" { return column + width - column % width }
            // Match the editor's tab stops for wide CJK/emoji graphemes as well as ASCII.
            let wide = character.unicodeScalars.contains { scalar in
                let value = scalar.value
                return (0x1100...0x115F).contains(value) || (0x2E80...0xA4CF).contains(value) ||
                    (0xAC00...0xD7A3).contains(value) || (0xF900...0xFAFF).contains(value) ||
                    (0xFE10...0xFE6F).contains(value) || (0xFF01...0xFF60).contains(value) ||
                    (0xFFE0...0xFFE6).contains(value) || (0x1F300...0x1FAFF).contains(value) ||
                    (0x20000...0x3FFFD).contains(value)
            }
            return column + (wide ? 2 : 1)
        }
    }
}
