import AppKit
import SwiftUI

struct SyntaxEditor: NSViewRepresentable {
    @ObservedObject private var preferences = Preferences.shared
    @ObservedObject var document: LocalFileDocument
    let onChange: (String) -> Void
    let onSave: () -> Void
    var onSelection: (Int, Int) -> Void = { _, _ in }
    var onScroll: (Double) -> Void = { _ in }
    var scrollRequest: EditorScrollRequest?
    var isEditable = true

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = CodeEditorScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        // NSRulerView's separator can paint above this representable into the
        // SwiftUI tabs/titlebar unless the native scroll view clips its children.
        scroll.clipsToBounds = true
        scroll.autohidesScrollers = true; scroll.borderType = .noBorder; scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        let text = CodeTextView(frame: .zero)
        text.isRichText = false; text.importsGraphics = false; text.allowsUndo = true
        text.isEditable = isEditable; text.isSelectable = isEditable
        text.font = editorFont
        text.textColor = .textColor; text.backgroundColor = .textBackgroundColor
        text.isAutomaticQuoteSubstitutionEnabled = false; text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false; text.isAutomaticSpellingCorrectionEnabled = false
        text.isContinuousSpellCheckingEnabled = false; text.isGrammarCheckingEnabled = false
        text.isAutomaticLinkDetectionEnabled = false; text.isAutomaticDataDetectionEnabled = false
        text.textContainerInset = NSSize(width: 12, height: 10)
        text.isVerticallyResizable = true; text.isHorizontallyResizable = true
        text.minSize = NSSize(width: 0, height: 0); text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.autoresizingMask = [.width]
        text.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = false
        text.delegate = context.coordinator
        text.setAccessibilityIdentifier("local-code-editor")
        text.setAccessibilityLabel(L("代码编辑器"))
        text.onSave = { context.coordinator.parent.onSave() }
        scroll.documentView = text
        let ruler = CodeLineRuler(textView: text)
        scroll.verticalRulerView = ruler; scroll.hasVerticalRuler = true; scroll.rulersVisible = true
        context.coordinator.textView = text
        let find = EditorFindController(editor: text, session: document.findSession)
        context.coordinator.find = find
        text.onFind = { [weak find] in find?.open() }
        text.onFindKey = { [weak find] event in
            guard let find, find.session.visible else { return false }
            if event.keyCode == 53 { find.close(); return true }
            if event.keyCode == 99 { find.navigate(backwards: event.modifierFlags.contains(.shift)); return true }
            return false
        }
        context.coordinator.install(document.text, language: document.language)
        find.attach(to: scroll)
        context.coordinator.observeScroll(scroll)
        let handledSelection = document.handledSearchSelectionID
        if let position = document.editorPosition, document.searchSelection?.id == handledSelection {
            DispatchQueue.main.async { [weak coordinator = context.coordinator] in
                guard let coordinator, let text = coordinator.textView, let scroll = text.enclosingScrollView else { return }
                // A fresh search navigation takes precedence over the remembered reading position.
                guard coordinator.lastSelectionRequest == handledSelection else { return }
                let length = (text.string as NSString).length
                let location = min(position.selection.location, length)
                text.setSelectedRange(NSRange(location: location, length: min(position.selection.length, length - location)))
                text.layoutManager?.ensureLayout(for: text.textContainer!)
                scroll.contentView.scroll(to: position.origin)
                scroll.reflectScrolledClipView(scroll.contentView)
                coordinator.updateSelection()
                coordinator.didScroll()
            }
        }
        return scroll
    }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        guard let text = coordinator.textView else { return }
        coordinator.parent.document.editorPosition = (text.selectedRange(), scroll.contentView.bounds.origin)
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        if let text = context.coordinator.textView {
            text.isEditable = isEditable; text.isSelectable = isEditable
            if !isEditable, text.window?.firstResponder === text { text.window?.makeFirstResponder(nil) }
        }
        context.coordinator.textView?.setAccessibilityLabel(L("代码编辑器"))
        context.coordinator.applyTypography()
        if context.coordinator.textView?.string != document.text { context.coordinator.install(document.text, language: document.language) }
        else if context.coordinator.language != document.language { context.coordinator.highlight() }
        context.coordinator.reveal(scrollRequest)
        if isEditable {
            context.coordinator.select(document.searchSelection)
            context.coordinator.openFind(document.findRequest)
        }
    }
    private var editorFont: NSFont {
        let size = CGFloat(min(40, max(9, preferences.terminal.fontSize)))
        return NSFont(name: preferences.terminal.fontName, size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SyntaxEditor
        weak var textView: CodeTextView?
        var language: CodeLanguage = .plain
        var changing = false
        var find: EditorFindController?
        private var lastFindRequest: UUID?
        private var highlightWork: DispatchWorkItem?
        private var parseWork: DispatchWorkItem?
        private var highlightGeneration = UUID()
        private var scrollObserver: NSObjectProtocol?
        private var lastRequest: UUID?
        fileprivate var lastSelectionRequest: UUID?
        private var suppressScrollUntil: TimeInterval = 0
        init(_ parent: SyntaxEditor) {
            self.parent = parent
            lastSelectionRequest = parent.document.handledSearchSelectionID
        }
        func openFind(_ request: UUID?) {
            guard let request, request != lastFindRequest else { return }
            lastFindRequest = request; find?.open()
            let document = parent.document
            DispatchQueue.main.async { [weak document] in
                if document?.findRequest == request { document?.findRequest = nil }
            }
        }
        deinit { highlightWork?.cancel(); parseWork?.cancel(); if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) } }
        func observeScroll(_ scroll: NSScrollView) {
            scroll.contentView.postsBoundsChangedNotifications = true
            scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
                DispatchQueue.main.async { self?.didScroll() }
            }
        }
        func didScroll() {
            guard ProcessInfo.processInfo.systemUptime > suppressScrollUntil,
                  let view = textView, let layout = view.layoutManager, let container = view.textContainer,
                  layout.numberOfGlyphs > 0 else { return }
            let y = max(0, view.visibleRect.minY - view.textContainerInset.height)
            let glyph = min(layout.glyphIndex(for: NSPoint(x: 0, y: y), in: container), layout.numberOfGlyphs - 1)
            let character = layout.characterIndexForGlyph(at: glyph)
            let ns = view.string as NSString
            let line = ns.substring(to: min(character, ns.length)).components(separatedBy: "\n").count
            let rect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            parent.onScroll(Double(line) + min(0.99, max(0, (y - rect.minY) / max(1, rect.height))))
        }
        func reveal(_ request: EditorScrollRequest?) {
            guard let request, request.id != lastRequest, request.line.isFinite,
                  let view = textView, let layout = view.layoutManager, let scroll = view.enclosingScrollView else { return }
            lastRequest = request.id
            let ns = view.string as NSString
            var location = 0; var line = 1
            while line < max(1, Int(request.line)), location < ns.length {
                let range = ns.lineRange(for: NSRange(location: location, length: 0))
                location = NSMaxRange(range); line += 1
            }
            layout.ensureLayout(for: view.textContainer!)
            let glyph = layout.glyphIndexForCharacter(at: min(location, ns.length))
            let rect = glyph < layout.numberOfGlyphs ? layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil) : layout.extraLineFragmentRect
            let y = rect.minY + view.textContainerInset.height + CGFloat(request.line - floor(request.line)) * rect.height
            suppressScrollUntil = ProcessInfo.processInfo.systemUptime + 0.18
            let origin = scroll.contentView.bounds.origin
            scroll.contentView.scroll(to: NSPoint(x: origin.x, y: max(0, min(y, view.bounds.height - scroll.contentSize.height))))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        func install(_ value: String, language: CodeLanguage) {
            guard let view = textView else { return }
            guard !view.hasMarkedText() else { return }
            changing = true
            let selected = view.selectedRange()
            view.string = value; self.language = language
            view.setSelectedRange(NSRange(location: min(selected.location, (value as NSString).length), length: 0))
            view.undoManager?.removeAllActions()
            changing = false; highlight(); updateSelection()
            find?.textChanged()
        }
        func applyTypography() {
            guard let view = textView else { return }
            let font = parent.editorFont
            guard view.font?.isEqual(font) != true else { return }
            let range = NSRange(location: 0, length: view.textStorage?.length ?? 0)
            view.font = font
            if range.length > 0 { view.textStorage?.addAttribute(.font, value: font, range: range) }
            view.typingAttributes[.font] = font
        }
        func select(_ request: EditorSelectionRequest?) {
            guard let request, request.id != lastSelectionRequest, let view = textView,
                  NSMaxRange(request.range) <= (view.string as NSString).length else { return }
            lastSelectionRequest = request.id
            parent.document.handledSearchSelectionID = request.id
            view.setSelectedRange(request.range)
            view.scrollRangeToVisible(request.range)
            view.showFindIndicator(for: request.range)
            view.window?.makeFirstResponder(view)
            updateSelection()
        }
        func textDidChange(_ notification: Notification) {
            guard !changing, let view = textView else { return }
            parent.onChange(view.string)
            find?.textChanged()
            highlightGeneration = UUID()
            parseWork?.cancel()
            highlightWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.highlight() }
            highlightWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
            view.enclosingScrollView?.verticalRulerView?.needsDisplay = true
        }
        func textViewDidChangeSelection(_ notification: Notification) { updateSelection(); find?.selectionChanged() }
        func updateSelection() {
            guard let view = textView else { return }
            let prefix = (view.string as NSString).substring(to: min(view.selectedRange().location, (view.string as NSString).length))
            let lines = prefix.components(separatedBy: "\n")
            let line = lines.count, column = (lines.last?.count ?? 0) + 1
            DispatchQueue.main.async { [weak self] in self?.parent.onSelection(line, column) }
        }
        func highlight() {
            guard let view = textView else { return }
            highlightWork?.cancel()
            parseWork?.cancel()
            language = parent.document.language
            let source = view.string, requestedLanguage = language
            let generation = UUID(); highlightGeneration = generation
            parseWork = CodeHighlighter.tokensAsync(in: source, language: requestedLanguage) { [weak self, weak view] tokens in
                guard let self, let view, self.highlightGeneration == generation,
                      self.language == requestedLanguage, view.string == source else { return }
                self.apply(tokens, to: view)
            }
        }
        private func apply(_ tokens: [CodeToken], to view: CodeTextView) {
            guard let storage = view.textStorage else { return }
            let range = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: range)
            for token in tokens {
                storage.addAttribute(.foregroundColor, value: CodePalette.color(token.kind), range: token.range)
            }
            storage.endEditing()
            view.typingAttributes = [.foregroundColor: NSColor.textColor, .font: view.font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)]
            view.enclosingScrollView?.verticalRulerView?.needsDisplay = true
        }
    }
}

final class CodeTextView: NSTextView {
    var onSave: (() -> Void)?
    var onFind: (() -> Void)?
    var onFindKey: ((NSEvent) -> Bool)?
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if ShortcutPreferences.shared.binding(for: .findFile).matches(event) { onFind?(); return true }
        if onFindKey?(event) == true { return true }
        if ShortcutPreferences.shared.binding(for: .saveFile).matches(event) {
            onSave?(); return true
        }
        return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if ShortcutPreferences.shared.binding(for: .findFile).matches(event) { onFind?(); return }
        if onFindKey?(event) == true { return }
        super.keyDown(with: event)
    }
    override func insertTab(_ sender: Any?) { changeIndentation(outdent: false) }
    override func insertBacktab(_ sender: Any?) { changeIndentation(outdent: true) }
    private func changeIndentation(outdent: Bool) {
        guard isEditable, !hasMarkedText(),
              let edit = EditorIndentation.edit(string, selection: selectedRange(), outdent: outdent) else { return }
        applyIndentation(edit)
    }
    private func applyIndentation(_ edit: EditorIndentation.Edit) {
        guard let storage = textStorage else { return }
        let oldText = (string as NSString).substring(with: edit.range)
        let oldSelection = selectedRange()
        let undo = undoManager
        let grouping = undo != nil && undo?.isUndoing == false && undo?.isRedoing == false
        breakUndoCoalescing()
        if grouping { undo?.beginUndoGrouping() }
        // NSTextView's replacement undo collapses the selection. Own this one
        // transaction so both undo and redo restore the complete block selection.
        undo?.disableUndoRegistration()
        let allowed = shouldChangeText(in: edit.range, replacementString: edit.text)
        if allowed {
            storage.replaceCharacters(in: edit.range, with: edit.text)
            setSelectedRange(edit.selection)
            didChangeText()
        }
        undo?.enableUndoRegistration()
        if allowed {
            let inverse = EditorIndentation.Edit(range: NSRange(location: edit.range.location, length: (edit.text as NSString).length),
                                                 text: oldText, selection: oldSelection)
            undo?.registerUndo(withTarget: self) { $0.applyIndentation(inverse) }
        }
        if grouping { undo?.endUndoGrouping() }
        breakUndoCoalescing()
        scrollRangeToVisible(selectedRange())
    }
    override func insertNewline(_ sender: Any?) {
        let ns = string as NSString
        let selection = selectedRange()
        let line = ns.substring(with: ns.lineRange(for: NSRange(location: min(selection.location, ns.length), length: 0)))
        let indent = String(line.prefix { $0 == " " || $0 == "\t" })
        insertText("\n" + indent, replacementRange: selection)
    }
}

final class CodeLineRuler: NSRulerView {
    weak var editor: NSTextView?
    init(textView: NSTextView) {
        editor = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView; ruleThickness = 49
        NotificationCenter.default.addObserver(self, selector: #selector(redraw), name: NSView.boundsDidChangeNotification, object: textView.enclosingScrollView?.contentView)
        textView.enclosingScrollView?.contentView.postsBoundsChangedNotifications = true
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func redraw() { needsDisplay = true }
    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSColor.textBackgroundColor.setFill(); bounds.fill()
        guard let text = editor, let layout = text.layoutManager, let container = text.textContainer else { return }
        let visible = text.visibleRect.offsetBy(dx: -text.textContainerInset.width, dy: -text.textContainerInset.height)
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let ns = text.string as NSString
        let charStart = layout.characterIndexForGlyph(at: min(glyphs.location, max(0, layout.numberOfGlyphs - 1)))
        var line = ns.substring(to: min(charStart, ns.length)).reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.tertiaryLabelColor]
        layout.enumerateLineFragments(forGlyphRange: glyphs) { [weak self] lineRect, _, _, range, _ in
            guard let self else { return }
            let charIndex = layout.characterIndexForGlyph(at: range.location)
            if charIndex == 0 || (charIndex <= ns.length && ns.character(at: charIndex - 1) == 10) {
                let label = "\(line)" as NSString
                let y = self.convert(NSPoint(x: 0, y: lineRect.minY + text.textContainerInset.height), from: text).y
                label.draw(at: NSPoint(x: self.ruleThickness - label.size(withAttributes: attrs).width - 10, y: y), withAttributes: attrs)
                line += 1
            }
        }
        if ns.length == 0 || ns.hasSuffix("\n") {
            let fragment = layout.extraLineFragmentRect
            if fragment.height > 0 {
                let label = "\(ns.components(separatedBy: "\n").count)" as NSString
                let y = convert(NSPoint(x: 0, y: fragment.minY + text.textContainerInset.height), from: text).y
                label.draw(at: NSPoint(x: ruleThickness - label.size(withAttributes: attrs).width - 10, y: y), withAttributes: attrs)
            }
        }
    }
}
