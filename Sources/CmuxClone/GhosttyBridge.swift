import AppKit
import SwiftUI
import CGhostty

@MainActor
final class GhosttyEngine {
    static let shared = GhosttyEngine()
    private(set) var app: ghostty_app_t?
    private var config: ghostty_config_t?
    private var appliedSettings: TerminalSettings?
    nonisolated let actionBridge = GhosttyActionBridge()

    private init() {
        _ = ghostty_init(0, nil)
        config = Self.makeConfig(Preferences.shared.effectiveTerminalSettings)
        appliedSettings = Preferences.shared.effectiveTerminalSettings
        var runtime = ghostty_runtime_config_s()
        runtime.userdata = Unmanaged.passUnretained(self).toOpaque()
        runtime.supports_selection_clipboard = false
        runtime.wakeup_cb = { _ in
            DispatchQueue.main.async { if let app = GhosttyEngine.shared.app { ghostty_app_tick(app) } }
        }
        runtime.action_cb = Self.actionCallback
        runtime.read_clipboard_cb = { userdata, _, request in
            guard let userdata else { return false }
            return MainActor.assumeIsolated {
                let view = Unmanaged<GhosttyTerminalView>.fromOpaque(userdata).takeUnretainedValue()
                guard let surface = view.surface else { return false }
                let text = NSPasteboard.general.string(forType: .string) ?? ""
                ghostty_surface_complete_clipboard_request(surface, text, request, false)
                return true
            }
        }
        runtime.confirm_read_clipboard_cb = { userdata, text, request, _ in
            guard let userdata, let text else { return }
            MainActor.assumeIsolated {
                let view = Unmanaged<GhosttyTerminalView>.fromOpaque(userdata).takeUnretainedValue()
                let value = String(cString: text)
                if confirm(title: L("允许终端读取剪贴板？"), detail: L("当前终端程序请求读取系统剪贴板。"), action: L("允许")) {
                    ghostty_surface_complete_clipboard_request(view.surface, value, request, true)
                } else {
                    ghostty_surface_complete_clipboard_request(view.surface, "", request, true)
                }
            }
        }
        runtime.write_clipboard_cb = { _, _, contents, count, needsConfirm in
            guard let contents else { return }
            MainActor.assumeIsolated {
                if needsConfirm && !confirm(title: L("允许写入剪贴板？"), detail: L("当前终端程序请求更新系统剪贴板。"), action: L("允许")) { return }
                for i in 0..<count where contents[i].mime == nil || String(cString: contents[i].mime) == "text/plain" {
                    if let data = contents[i].data {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(String(cString: data), forType: .string)
                        break
                    }
                }
            }
        }
        runtime.close_surface_cb = { userdata, _ in
            guard let userdata else { return }
            MainActor.assumeIsolated {
                let view = Unmanaged<GhosttyTerminalView>.fromOpaque(userdata).takeUnretainedValue()
                let id = view.paneID
                DispatchQueue.main.async { [weak model = view.model] in model?.processExited(id) }
            }
        }
        app = ghostty_app_new(&runtime, config)
        if let app { ghostty_app_set_color_scheme(app, Preferences.shared.effectiveTerminalSettings.theme == "dark" ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT) }
    }

    nonisolated static let actionCallback: ghostty_runtime_action_cb = { app, target, action in
        guard let app, let userdata = ghostty_app_userdata(app) else { return false }
        // Resolve userdata rather than re-entering shared during initialization.
        // The bridge accepts calls from both the renderer and the main thread.
        return Unmanaged<GhosttyEngine>.fromOpaque(userdata).takeUnretainedValue().actionBridge.receive(target: target, action: action)
    }

    private static func makeConfig(_ settings: TerminalSettings) -> ghostty_config_t? {
        guard let config = ghostty_config_new() else { return nil }
        let source = settings.ghosttyConfig
        ghostty_config_load_string(config, source, UInt(source.utf8.count), "cmux-local")
        ghostty_config_finalize(config)
        for i in 0..<ghostty_config_diagnostics_count(config) {
            let diagnostic = ghostty_config_get_diagnostic(config, i)
            if let message = diagnostic.message { NSLog("Ghostty config: %@", String(cString: message)) }
        }
        return config
    }
    func apply(_ settings: TerminalSettings) {
        guard settings != appliedSettings else { return }
        guard let app, let next = Self.makeConfig(settings) else { return }
        let fontChanged = settings.fontSize != appliedSettings?.fontSize
        let scheme = settings.theme == "dark" ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
        ghostty_app_set_color_scheme(app, scheme)
        // The embedder updates each surface below. Propagating here as well
        // reloads every surface twice, rebuilding fonts and resizing the PTY.
        ghostty_app_update_config_without_surface_propagation(app, next)
        if let config { ghostty_config_free(config) }
        config = next
        appliedSettings = settings
        for controller in AppDelegate.shared.windows {
            controller.window?.isOpaque = settings.opacity >= 1
            controller.window?.backgroundColor = settings.opacity >= 1 ? .windowBackgroundColor : .clear
            for terminal in controller.model.terminals.values {
                if let surface = terminal.surface {
                    ghostty_surface_set_color_scheme(surface, scheme)
                    ghostty_surface_update_config(surface, next)
                    // Native Cmd+/- zoom owns a surface-local size which config
                    // reload deliberately preserves. An explicit setting change
                    // must replace that size using the new configured default.
                    if fontChanged, abs(ghostty_surface_font_size(surface) - Float(settings.fontSize)) > 0.01 {
                        terminal.action("reset_font_size")
                    }
                }
                if let host = terminal.superview as? NSVisualEffectView { host.state = settings.blur ? .active : .inactive }
            }
        }
    }
}

@MainActor
final class GhosttyTerminalView: NSView, @preconcurrency NSTextInputClient {
    let paneID: UUID
    var directory: String {
        didSet { model?.updateDirectory(terminalID: paneID, directory: directory) }
    }
    let command: String?
    weak var model: WindowModel?
    private(set) var surface: ghostty_surface_t?
    private var marked = NSMutableAttributedString(string: "")
    private var keyText: String?
    private var interpreting = false
    private var isShutdown = false
    private var pendingText = ""
    private var tracking: NSTrackingArea?
    var needsConfirmation: Bool { surface.map { ghostty_surface_needs_confirm_quit($0) } ?? false }

    init(paneID: UUID, directory: String, command: String? = nil) {
        self.paneID = paneID; self.directory = directory; self.command = command
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        setAccessibilityLabel(L("终端"))
        setAccessibilityIdentifier("terminal-\(paneID)")
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    private func createSurface() {
        guard !isShutdown, surface == nil, let app = GhosttyEngine.shared.app else { return }
        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform.macos.nsview = Unmanaged.passUnretained(self).toOpaque()
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        config.scale_factor = Double(window?.backingScaleFactor ?? 2)
        config.font_size = Float(Preferences.shared.terminal.fontSize)
        let cwd = strdup(directory)
        config.working_directory = UnsafePointer(cwd)
        let commandPointer = command.flatMap { strdup($0) }
        config.command = UnsafePointer(commandPointer)
        config.context = GHOSTTY_SURFACE_CONTEXT_TAB
        config.io_mode = GHOSTTY_SURFACE_IO_EXEC
        surface = ghostty_surface_new(app, &config)
        if let surface { GhosttyEngine.shared.actionBridge.register(surface: surface, view: self) }
        if let surface { ghostty_surface_set_color_scheme(surface, Preferences.shared.effectiveTerminalSettings.theme == "dark" ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT) }
        free(cwd); free(commandPointer)
        layout()
        if surface != nil, !pendingText.isEmpty {
            let text = pendingText; pendingText = ""
            pasteText(text)
        }
        if surface == nil { model?.error = L("无法创建 Ghostty 终端。") }
    }
    override func becomeFirstResponder() -> Bool {
        guard !isShutdown, let surface else { return false }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isShutdown, self.window?.firstResponder === self else { return }
            self.model?.focus(self.paneID)
        }
        ghostty_surface_set_focus(surface, true); return true
    }
    override func resignFirstResponder() -> Bool { if let surface { ghostty_surface_set_focus(surface, false) }; return true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !isShutdown else { return }
        if window != nil {
            createSurface()
            if let surface { ghostty_surface_set_occlusion(surface, true) }
            if model?.selectedTab.map({ model?.activeTerminalID($0.focusedPane) == paneID }) == true { window?.makeFirstResponder(self) }
        } else if let surface { ghostty_surface_set_occlusion(surface, false) }
    }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); layout() }
    override func layout() {
        super.layout(); guard let surface else { return }
        let scale = window?.backingScaleFactor ?? 2
        ghostty_surface_set_content_scale(surface, scale, scale)
        ghostty_surface_set_size(surface, UInt32(max(1, bounds.width * scale)), UInt32(max(1, bounds.height * scale)))
    }
    func mods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var value: UInt32 = 0
        if flags.contains(.shift) { value |= 1 }
        if flags.contains(.control) { value |= 2 }
        if flags.contains(.option) { value |= 4 }
        if flags.contains(.command) { value |= 8 }
        if flags.contains(.capsLock) { value |= 16 }
        return ghostty_input_mods_e(rawValue: value)
    }
    private func sendKey(_ event: NSEvent, action: ghostty_input_action_e, text: String?) {
        guard let surface else { return }
        var key = ghostty_input_key_s()
        key.action = action; key.keycode = UInt32(event.keyCode); key.mods = mods(event.modifierFlags)
        key.unshifted_codepoint = event.charactersIgnoringModifiers?.unicodeScalars.first?.value ?? 0
        key.composing = hasMarkedText()
        if let text, !text.isEmpty {
            key.consumed_mods = mods(event.modifierFlags.intersection([.shift, .option]))
            text.withCString { key.text = $0; _ = ghostty_surface_key(surface, key) }
        } else { _ = ghostty_surface_key(surface, key) }
    }
    override func keyDown(with event: NSEvent) {
        keyText = nil
        let flags = event.modifierFlags
        let bypass = flags.contains(.control) || flags.contains(.command) || (flags.contains(.option) && Preferences.shared.terminal.optionAsAlt)
        if !bypass { interpreting = true; interpretKeyEvents([event]); interpreting = false }
        if !hasMarkedText() || bypass { sendKey(event, action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS, text: keyText) }
    }
    override func keyUp(with event: NSEvent) { sendKey(event, action: GHOSTTY_ACTION_RELEASE, text: nil) }
    override func flagsChanged(with event: NSEvent) {
        // Modifier state is included with every key/mouse event.
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.modifierFlags.contains(.command) else { return false }
        let key = event.charactersIgnoringModifiers ?? ""
        if ["c", "v", "a", "=", "+", "-", "0", "k"].contains(key) { keyDown(with: event); return true }
        return false
    }
    func insertText(_ string: Any, replacementRange: NSRange) {
        let value = (string as? NSAttributedString)?.string ?? (string as? String ?? "")
        guard let surface else { return }
        unmarkText()
        if interpreting { keyText = (keyText ?? "") + value }
        else { ghostty_surface_text_input(surface, value, UInt(value.utf8.count)) }
    }
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let value = (string as? NSAttributedString)?.string ?? (string as? String ?? "")
        marked = NSMutableAttributedString(string: value)
        guard let surface else { return }
        ghostty_surface_preedit(surface, value, UInt(value.utf8.count))
    }
    func unmarkText() { marked = NSMutableAttributedString(string: ""); if let surface { ghostty_surface_preedit(surface, nil, 0) } }
    func hasMarkedText() -> Bool { marked.length > 0 }
    func markedRange() -> NSRange { hasMarkedText() ? NSRange(location: 0, length: marked.length) : NSRange(location: NSNotFound, length: 0) }
    func selectedRange() -> NSRange { NSRange(location: 0, length: 0) }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func characterIndex(for point: NSPoint) -> Int { 0 }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        var x = 0.0, y = 0.0, w = 0.0, h = 0.0
        if let surface { ghostty_surface_ime_point(surface, &x, &y, &w, &h) }
        let rect = convert(NSRect(x: x, y: y, width: w, height: h), to: nil)
        return window?.convertToScreen(rect) ?? .zero
    }
    override func doCommand(by selector: Selector) {}
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited], owner: self)
        addTrackingArea(tracking!)
    }
    private func mouse(_ event: NSEvent, state: ghostty_input_mouse_state_e?, button: ghostty_input_mouse_button_e = GHOSTTY_MOUSE_LEFT) {
        guard let surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, point.y, mods(event.modifierFlags))
        if let state { _ = ghostty_surface_mouse_button(surface, state, button, mods(event.modifierFlags)) }
    }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); mouse(event, state: GHOSTTY_MOUSE_PRESS) }
    override func mouseUp(with event: NSEvent) { mouse(event, state: GHOSTTY_MOUSE_RELEASE) }
    override func mouseDragged(with event: NSEvent) { mouse(event, state: nil) }
    override func mouseMoved(with event: NSEvent) { mouse(event, state: nil) }
    override func otherMouseDown(with event: NSEvent) { mouse(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_MIDDLE) }
    override func otherMouseUp(with event: NSEvent) { mouse(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_MIDDLE) }
    override func rightMouseDown(with event: NSEvent) {
        if let surface, ghostty_surface_mouse_captured(surface) { mouse(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_RIGHT); return }
        let menu = NSMenu()
        for (title, selector) in [(L("复制"), #selector(copy(_:))), (L("粘贴"), #selector(paste(_:))), (L("全选"), #selector(selectAll(_:))), (L("清屏"), #selector(clear(_:)))] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    override func rightMouseUp(with event: NSEvent) { mouse(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_RIGHT) }
    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        let factor = event.hasPreciseScrollingDeltas ? 1.0 : 3.0
        let momentum: Int32 = event.momentumPhase == .began ? 1 : event.momentumPhase == .changed ? 3 : event.momentumPhase == .ended ? 4 : 0
        let flags: Int32 = (event.hasPreciseScrollingDeltas ? 1 : 0) | (momentum << 1)
        ghostty_surface_mouse_scroll(surface, event.scrollingDeltaX * factor, event.scrollingDeltaY * factor, flags)
    }
    @objc func copy(_ sender: Any?) { action("copy_to_clipboard") }
    @objc func paste(_ sender: Any?) { action("paste_from_clipboard") }
    @objc override func selectAll(_ sender: Any?) { action("select_all") }
    @objc func clear(_ sender: Any?) { action("clear_screen") }
    func pasteText(_ value: String) {
        guard !isShutdown else { return }
        if let surface { ghostty_surface_text(surface, value, UInt(value.utf8.count)) }
        else { pendingText += value }
    }
    @discardableResult func action(_ value: String) -> Bool { guard let surface else { return false }; return ghostty_surface_binding_action(surface, value, UInt(value.utf8.count)) }
    func shutdown() {
        isShutdown = true
        pendingText = ""
        guard let surface else { return }
        self.surface = nil
        GhosttyEngine.shared.actionBridge.unregister(surface: surface)
        ghostty_surface_request_process_termination(surface); ghostty_surface_free(surface)
    }
}

struct GhosttyView: NSViewRepresentable {
    let terminal: GhosttyTerminalView
    func makeNSView(context: Context) -> NSView {
        let host = NSVisualEffectView()
        host.blendingMode = .behindWindow; host.material = .underWindowBackground
        host.state = Preferences.shared.terminal.blur ? .active : .inactive
        attach(to: host); return host
    }
    func updateNSView(_ view: NSView, context: Context) {
        terminal.setAccessibilityLabel(L("终端"))
        attach(to: view)
    }
    private func attach(to host: NSView) {
        guard terminal.superview !== host else { return }
        for view in host.subviews where view is GhosttyTerminalView && view !== terminal { view.removeFromSuperview() }
        terminal.removeFromSuperview(); terminal.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(terminal)
        NSLayoutConstraint.activate([terminal.leadingAnchor.constraint(equalTo: host.leadingAnchor), terminal.trailingAnchor.constraint(equalTo: host.trailingAnchor), terminal.topAnchor.constraint(equalTo: host.topAnchor), terminal.bottomAnchor.constraint(equalTo: host.bottomAnchor)])
    }
}
