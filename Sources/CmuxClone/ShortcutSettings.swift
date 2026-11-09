import AppKit
import SwiftUI

struct ShortcutSettingsView: View {
    @ObservedObject private var languagePreferences = LanguagePreferences.shared
    @ObservedObject var shortcuts: ShortcutPreferences
    @State private var error: String?

    var body: some View {
        let _ = languagePreferences.language
        VStack(alignment: .leading, spacing: 12) {
            Text(L("点击快捷键后按下新的组合键。Esc 取消，Delete 清除。修改立即生效。"))
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(AppCommand.allCases) { command in
                        HStack(spacing: 8) {
                            Text(command.title).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                            ShortcutRecorder(command: command, binding: shortcuts.binding(for: command)) { binding in
                                let message = shortcuts.set(binding, for: command)
                                error = message
                                return message == nil
                            }
                            .frame(width: 140, height: 28)
                            IconButton(symbol: "xmark", help: L("清除快捷键")) { error = shortcuts.set(.disabled, for: command) }
                                .disabled(shortcuts.binding(for: command).isDisabled)
                            IconButton(symbol: "arrow.counterclockwise", help: L("恢复此快捷键")) { error = shortcuts.reset(command) }
                                .disabled(shortcuts.binding(for: command) == command.defaultBinding)
                        }
                        .padding(.vertical, 5)
                        Divider()
                    }
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("shortcut-error")
            }
        }
        .padding(16)
        .onChange(of: shortcuts.overrides) { _, _ in error = nil }
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    let command: AppCommand
    let binding: KeyBinding
    let onRecord: (KeyBinding) -> Bool

    func makeNSView(context: Context) -> ShortcutCaptureView {
        let view = ShortcutCaptureView()
        updateNSView(view, context: context)
        return view
    }
    func updateNSView(_ view: ShortcutCaptureView, context: Context) {
        view.binding = binding
        view.onRecord = onRecord
        view.setAccessibilityLabel(command.title)
        view.setAccessibilityIdentifier("shortcut-recorder-" + command.rawValue)
        view.refreshTitle()
    }
}

/// Records in the first responder instead of installing a global keyboard hook.
/// It consumes key equivalents as well as keyDown, so Cmd+Q can be recorded
/// without invoking the app menu while this control owns focus.
final class ShortcutCaptureView: NSButton {
    var binding = KeyBinding.disabled
    var onRecord: ((KeyBinding) -> Bool)?
    private(set) var recording = false
    override var acceptsFirstResponder: Bool { true }

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        font = .systemFont(ofSize: 12, weight: .medium)
        target = self
        action = #selector(beginRecording)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc func beginRecording() {
        guard window?.makeFirstResponder(self) == true else { return }
        recording = true
        refreshTitle()
    }
    func refreshTitle() {
        title = recording ? L("请按快捷键…") : binding.display
        setAccessibilityValue(title)
    }
    override func resignFirstResponder() -> Bool {
        recording = false
        refreshTitle()
        return super.resignFirstResponder()
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        capture(event)
        return true
    }
    override func keyDown(with event: NSEvent) {
        if recording { capture(event) } else { super.keyDown(with: event) }
    }
    func capture(_ event: NSEvent) {
        guard recording else { keyDownWhenNotRecording(event); return }
        if event.keyCode == 53 { finish(); return }
        let modifiers = event.modifierFlags.intersection(KeyBinding.supportedModifiers)
        if modifiers.isEmpty && [51, 117].contains(event.keyCode) {
            if onRecord?(.disabled) == true { binding = .disabled; finish() }
            return
        }
        guard let binding = KeyBinding(event: event) else {
            // Feed an invalid candidate through the shared validator so the
            // same error is visible for bare letters and malformed imports.
            _ = onRecord?(KeyBinding("x", []))
            return
        }
        if onRecord?(binding) == true { self.binding = binding; finish() }
    }
    private func keyDownWhenNotRecording(_ event: NSEvent) { super.keyDown(with: event) }
    private func finish() {
        recording = false
        refreshTitle()
        window?.makeFirstResponder(nil)
    }
}
