import AppKit

/// NSScrollView tiles its own children; position the accessory after each tile/layout.
final class CodeEditorScrollView: NSScrollView {
    weak var findPanel: NSView?
    override func tile() { super.tile(); positionFindPanel() }
    override func layout() { super.layout(); positionFindPanel() }
    func positionFindPanel() {
        guard let findPanel else { return }
        let width = max(0, min(600, bounds.width - 26))
        let findPanelHeight = (findPanel as? EditorFindPanel)?.heightForWidth?(width) ?? 41
        findPanel.frame = NSRect(x: max(8, bounds.width - width - 18), y: isFlipped ? 8 : bounds.height - findPanelHeight - 8, width: width, height: findPanelHeight)
    }
}

final class EditorFindPanel: NSView {
    var heightForWidth: ((CGFloat) -> CGFloat)?
    var layoutContents: (() -> Void)?
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func layout() { super.layout(); layoutContents?() }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); needsDisplay = true
    }
}

/// Owns the find UI and cancellable scans for one mounted code editor.
@MainActor
final class EditorFindController: NSObject, NSTextFieldDelegate {
    weak var editor: CodeTextView?
    let session: EditorFindSession
    let panel = EditorFindPanel()
    let input = NSTextField(string: "")
    let replacementInput = NSTextField(string: "")
    private let count = NSTextField(labelWithString: "")
    private let errorLabel = NSTextField(labelWithString: "")
    private var caseButton: NSButton!
    private var wordButton: NSButton!
    private var regexButton: NSButton!
    private var scopeButton: NSButton!
    private var expandButton: NSButton!
    private var previousButton: NSButton!
    private var nextButton: NSButton!
    private var replaceButton: NSButton!
    private var replaceAllButton: NSButton!
    private var closeButton: NSButton!
    private(set) var result = EditorFindResult()
    private(set) var currentIndex: Int?
    private(set) var scope: NSRange?
    private var source = ""
    private var work: DispatchWorkItem?
    private var cancellation = Progress(totalUnitCount: 1)
    private var generation = UUID()
    private var applyingSelection = false
    private var historyIndex: Int?
    private var historyDraft = ""
    private var languageObserver: NSObjectProtocol?

    init(editor: CodeTextView, session: EditorFindSession) {
        self.editor = editor; self.session = session
        super.init()
        build()
        languageObserver = NotificationCenter.default.addObserver(forName: .appLanguageDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.localize() }
        }
    }
    deinit { work?.cancel(); cancellation.cancel(); if let languageObserver { NotificationCenter.default.removeObserver(languageObserver) } }

    func attach(to scroll: CodeEditorScrollView) {
        scroll.addSubview(panel)
        scroll.findPanel = panel; updateHeight()
        panel.isHidden = !session.visible
        if session.visible { refresh(move: false) }
    }
    func open() {
        guard let editor else { return }
        if let seed = EditorFindEngine.seed(in: editor.string, selection: editor.selectedRange()) {
            session.query.text = session.query.regex ? NSRegularExpression.escapedPattern(for: seed) : seed
        }
        session.visible = true; panel.isHidden = false
        input.stringValue = session.query.text
        refresh(move: false)
        editor.window?.makeFirstResponder(input)
        input.selectText(nil)
    }
    @objc func close() {
        session.remember(); session.visible = false
        panel.isHidden = true; work?.cancel(); cancellation.cancel(); work = nil; generation = UUID()
        scope = nil; scopeButton.state = .off
        clearHighlights()
        editor?.window?.makeFirstResponder(editor)
    }
    func textChanged() {
        guard session.visible else { return }
        if !applyingSelection, let scope, let editor {
            self.scope = EditorFindEngine.track(scope, from: source, to: editor.string)
        }
        refresh(move: false)
    }
    func selectionChanged() {
        guard !applyingSelection else { return }
        scopeButton.isEnabled = scope != nil || (editor?.selectedRange().length ?? 0) > 0
        if let editor, let index = result.ranges.firstIndex(of: editor.selectedRange()) {
            currentIndex = index; updateStatus(); paintHighlights()
        }
    }
    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSTextField === input {
            session.query.text = input.stringValue; historyIndex = nil
            refresh(move: true)
        } else { session.replacement = replacementInput.stringValue }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)): close(); return true
        case #selector(NSResponder.insertNewline(_:)):
            session.remember()
            if control === replacementInput { replaceOne() }
            else { navigate(backwards: NSApp.currentEvent?.modifierFlags.contains(.shift) == true) }
            return true
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            navigate(backwards: true); return true
        case #selector(NSResponder.moveUp(_:)) where control === input:
            history(backwards: true); return true
        case #selector(NSResponder.moveDown(_:)) where control === input:
            history(backwards: false); return true
        default: return false
        }
    }
    private func history(backwards: Bool) {
        guard !session.history.isEmpty else { return }
        if historyIndex == nil { historyDraft = input.stringValue }
        let next = (historyIndex ?? -1) + (backwards ? 1 : -1)
        historyIndex = next < 0 ? nil : min(next, session.history.count - 1)
        input.stringValue = historyIndex.map { session.history[$0] } ?? historyDraft
        session.query.text = input.stringValue; refresh(move: true)
        input.selectText(nil)
    }
    @objc func toggleOption(_ sender: NSButton) {
        session.query.matchCase = caseButton.state == .on
        session.query.wholeWord = wordButton.state == .on
        session.query.regex = regexButton.state == .on
        refresh(move: true)
    }
    @objc func toggleScope() {
        if scope != nil { scope = nil }
        else if let editor { scope = EditorFindEngine.scope(editor.selectedRange(), in: editor.string) }
        scopeButton.state = scope == nil ? .off : .on
        refresh(move: true)
    }
    @objc func toggleReplace() {
        session.replaceVisible.toggle()
        expandButton.title = session.replaceVisible ? "⌄" : "›"
        updateHeight()
    }
    @objc func previous() { navigate(backwards: true) }
    @objc func next() { navigate(backwards: false) }
    func navigate(backwards: Bool) {
        session.remember()
        guard let editor, source == editor.string, !result.ranges.isEmpty, work == nil else { return }
        let selection = editor.selectedRange()
        let exact = result.ranges.firstIndex(of: selection)
        let index: Int
        if let exact { index = (exact + (backwards ? result.ranges.count - 1 : 1)) % result.ranges.count }
        else if backwards { index = result.ranges.lastIndex { NSMaxRange($0) <= selection.location } ?? result.ranges.count - 1 }
        else { index = result.ranges.firstIndex { $0.location >= NSMaxRange(selection) } ?? 0 }
        select(index)
    }
    private func select(_ index: Int) {
        guard let editor, result.ranges.indices.contains(index) else { return }
        currentIndex = index; applyingSelection = true
        let range = result.ranges[index]
        editor.setSelectedRange(range); editor.scrollRangeToVisible(range)
        applyingSelection = false
        updateStatus(); paintHighlights()
    }
    func refresh(move: Bool) {
        guard session.visible, let editor else { return }
        work?.cancel(); cancellation.cancel(); cancellation = Progress(totalUnitCount: 1); generation = UUID()
        let ticket = generation, text = editor.string, query = session.query, scope = scope
        let selection = editor.selectedRange()
        source = text; result = EditorFindResult(); currentIndex = nil
        clearHighlights(); count.stringValue = L("正在查找…")
        previousButton.isEnabled = false; nextButton.isEnabled = false
        replaceButton.isEnabled = false; replaceAllButton.isEnabled = false
        errorLabel.isHidden = true
        // A work item checks cancellation both during regex progress and before publishing.
        let cancellation = cancellation
        let item = DispatchWorkItem { [weak self] in
            let found = EditorFindEngine.search(text, query: query, scope: scope, cancelled: { cancellation.isCancelled })
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == ticket, self.session.visible, self.editor?.string == text else { return }
                self.work = nil; self.result = found
                if move, let index = found.ranges.firstIndex(where: { $0.location >= selection.location }) ?? (found.ranges.isEmpty ? nil : 0) {
                    self.select(index)
                } else {
                    self.currentIndex = found.ranges.firstIndex(of: selection)
                    self.updateStatus(); self.paintHighlights()
                }
            }
        }
        work = item
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.04, execute: item)
    }
    @objc func replaceOne() {
        guard work == nil, let editor, source == editor.string, !result.ranges.isEmpty else { return }
        // First click locates a hit when the editor selection is elsewhere.
        guard let index = result.ranges.firstIndex(of: editor.selectedRange()) else {
            let index = result.ranges.firstIndex { $0.location >= editor.selectedRange().location } ?? 0
            select(index); return
        }
        replace(ranges: [result.ranges[index]], move: true)
    }
    @objc func replaceAll() {
        guard work == nil, !result.limitHit, result.error == nil else { return }
        replace(ranges: result.ranges, move: false)
    }
    private func replace(ranges: [NSRange], move: Bool) {
        guard let editor, source == editor.string,
              let edit = try? EditorFindEngine.replacement(in: source, ranges: ranges, query: session.query, value: session.replacement) else { return }
        session.remember()
        applyingSelection = true
        let oldScope = scope
        let allowed = editor.replaceForFind(range: edit.range, text: edit.text)
        if allowed, let oldScope {
            scope = NSRange(location: oldScope.location, length: oldScope.length + (edit.text as NSString).length - edit.range.length)
        }
        applyingSelection = false
        guard allowed else { return }
        if move {
            var location = edit.range.location + (edit.text as NSString).length
            if edit.range.length == 0, edit.text.isEmpty {
                let text = editor.string as NSString
                location = location < text.length ? NSMaxRange(text.rangeOfComposedCharacterSequence(at: location)) : 0
            }
            editor.setSelectedRange(NSRange(location: location, length: 0))
        }
        refresh(move: move)
    }
    private func clearHighlights() {
        guard let editor, let layout = editor.layoutManager else { return }
        layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: (editor.string as NSString).length))
        layout.removeTemporaryAttribute(.underlineStyle, forCharacterRange: NSRange(location: 0, length: (editor.string as NSString).length))
    }
    private func paintHighlights() {
        clearHighlights()
        guard session.visible, let editor, source == editor.string, let layout = editor.layoutManager else { return }
        for (index, range) in result.ranges.enumerated() where range.length > 0 {
            layout.addTemporaryAttribute(.backgroundColor, value: index == currentIndex ? NSColor.controlAccentColor.withAlphaComponent(0.45) : NSColor.systemYellow.withAlphaComponent(0.25), forCharacterRange: range)
        }
    }
    private func updateStatus() {
        let valid = result.error == nil && !result.ranges.isEmpty
        count.stringValue = result.ranges.isEmpty ? L("无结果") : L("第 \(currentIndex.map { String($0 + 1) } ?? "?") / \(result.ranges.count) 项") + (result.limitHit ? "+" : "")
        count.textColor = !session.query.text.isEmpty && !valid ? .systemRed : .secondaryLabelColor
        errorLabel.stringValue = result.error ?? (result.limitHit ? L("结果过多，请缩小范围后全部替换") : "")
        errorLabel.isHidden = errorLabel.stringValue.isEmpty
        updateHeight()
        previousButton.isEnabled = valid; nextButton.isEnabled = valid
        replaceButton.isEnabled = valid && editor?.isEditable == true
        replaceAllButton.isEnabled = valid && !result.limitHit && editor?.isEditable == true
        scopeButton.isEnabled = scope != nil || (editor?.selectedRange().length ?? 0) > 0
    }
    private func build() {
        panel.wantsLayer = true; panel.layer?.cornerRadius = 7; panel.layer?.borderWidth = 1
        panel.setAccessibilityIdentifier("editor-find-bar")
        panel.heightForWidth = { [weak self] width in
            guard let self else { return 41 }
            return (width < 520 ? 93 : 41) + (self.session.replaceVisible ? 32 : 0) + (self.errorLabel.isHidden ? 0 : 20)
        }
        panel.layoutContents = { [weak self] in self?.layoutControls() }
        func button(_ title: String, _ action: Selector, toggle: Bool = false) -> NSButton {
            let button = NSButton(title: title, target: self, action: action)
            button.bezelStyle = .inline; button.isBordered = false
            button.font = .systemFont(ofSize: 13)
            button.setButtonType(toggle ? .toggle : .momentaryPushIn)
            panel.addSubview(button)
            return button
        }
        expandButton = button(session.replaceVisible ? "⌄" : "›", #selector(toggleReplace))
        caseButton = button("Aa", #selector(toggleOption(_:)), toggle: true)
        wordButton = button("ab", #selector(toggleOption(_:)), toggle: true)
        regexButton = button(".*", #selector(toggleOption(_:)), toggle: true)
        previousButton = button("↑", #selector(previous)); nextButton = button("↓", #selector(next))
        scopeButton = button("☰", #selector(toggleScope), toggle: true)
        closeButton = button("×", #selector(close))
        replaceButton = button("⇥", #selector(replaceOne)); replaceAllButton = button("⇥⇥", #selector(replaceAll))
        caseButton.state = session.query.matchCase ? .on : .off
        wordButton.state = session.query.wholeWord ? .on : .off
        regexButton.state = session.query.regex ? .on : .off
        input.stringValue = session.query.text; replacementInput.stringValue = session.replacement
        for field in [input, replacementInput] {
            field.delegate = self; field.font = .systemFont(ofSize: 13)
            field.focusRingType = .exterior; field.lineBreakMode = .byClipping
            panel.addSubview(field)
        }
        input.setAccessibilityIdentifier("editor-find-input")
        replacementInput.setAccessibilityIdentifier("editor-replace-input")
        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        errorLabel.font = .systemFont(ofSize: 11); errorLabel.textColor = .systemRed; errorLabel.isHidden = true
        panel.addSubview(count); panel.addSubview(errorLabel)
        localize()
    }
    private func layoutControls() {
        let width = panel.bounds.width
        let compact = width < 520
        let countWidth = min(140, max(70, count.intrinsicContentSize.width))
        let inputWidth = max(20, width - 14 - (compact ? 56 : 252 + countWidth))
        expandButton.frame = NSRect(x: 7, y: 7, width: 25, height: 27)
        input.frame = NSRect(x: 35, y: 7, width: inputWidth, height: 27)
        let options = [caseButton!, wordButton!, regexButton!]
        var x: CGFloat = compact ? 7 : 38 + inputWidth
        let y: CGFloat = compact ? 39 : 7
        for button in options { button.frame = NSRect(x: x, y: y, width: 25, height: 26); x += 28 }
        if compact {
            count.frame = NSRect(x: 7, y: 68, width: max(0, width - 14), height: 18)
        } else {
            count.frame = NSRect(x: x, y: 12, width: countWidth, height: 18); x += countWidth + 3
        }
        for button in [previousButton!, nextButton!, scopeButton!] {
            button.frame = NSRect(x: x, y: y, width: 25, height: 26); x += 28
        }
        closeButton.frame = NSRect(x: width - 32, y: 7, width: 25, height: 26)
        var bottom: CGFloat = compact ? 93 : 41
        for view in [replacementInput, replaceButton!, replaceAllButton!] { view.isHidden = !session.replaceVisible }
        if session.replaceVisible {
            replacementInput.frame = NSRect(x: 35, y: bottom, width: max(20, width - 98), height: 27)
            replaceButton.frame = NSRect(x: width - 60, y: bottom, width: 25, height: 26)
            replaceAllButton.frame = NSRect(x: width - 32, y: bottom, width: 25, height: 26)
            bottom += 32
        }
        errorLabel.frame = NSRect(x: 7, y: bottom - 3, width: max(0, width - 14), height: 18)
    }
    private func updateHeight() {
        guard let scroll = panel.superview as? CodeEditorScrollView else { return }
        scroll.positionFindPanel(); panel.needsLayout = true
    }
    private func localize() {
        input.placeholderString = L("查找（↑↓ 历史记录）")
        input.setAccessibilityLabel(L("查找当前文件"))
        replacementInput.placeholderString = L("替换")
        replacementInput.setAccessibilityLabel(L("替换"))
        let labels: [(NSButton?, String)] = [(caseButton, L("区分大小写")), (wordButton, L("全词匹配")), (regexButton, L("使用正则表达式")), (scopeButton, L("在选区中查找")), (expandButton, L("切换替换")), (previousButton, L("上一个（Shift+Enter）")), (nextButton, L("下一个（Enter）")), (replaceButton, L("替换当前匹配")), (replaceAllButton, L("全部替换")), (closeButton, L("关闭查找（Esc）"))]
        for (button, label) in labels { button?.toolTip = label; button?.setAccessibilityLabel(label) }
        if session.visible, work == nil { updateStatus() }
    }
}
