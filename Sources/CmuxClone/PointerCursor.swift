import AppKit
import SwiftUI

extension View {
    /// Marks an action's bounds without intercepting clicks or focus.
    func pointingHandCursor() -> some View { modifier(PointingHandCursor()) }
}

private struct PointingHandCursor: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content.overlay {
            PointerCursorRegion(isEnabled: isEnabled)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
        .onContinuousHover { phase in
            // Sheets use SwiftUI-created windows, so they also need a direct
            // hover update instead of depending on PointerCursorWindow.
            switch phase {
            case .active: (isEnabled ? NSCursor.pointingHand : .arrow).set()
            case .ended:
                if NSCursor.current == .pointingHand { NSCursor.arrow.set() }
            }
        }
    }
}

private struct PointerCursorRegion: NSViewRepresentable {
    let isEnabled: Bool

    func makeNSView(context: Context) -> PointerCursorView {
        let view = PointerCursorView()
        view.isPointerEnabled = isEnabled
        return view
    }

    func updateNSView(_ view: PointerCursorView, context: Context) {
        view.isPointerEnabled = isEnabled
    }
}

final class PointerCursorView: NSView {
    fileprivate static let regions = NSHashTable<PointerCursorView>.weakObjects()

    var isPointerEnabled = true {
        didSet {
            if oldValue != isPointerEnabled {
                window?.invalidateCursorRects(for: self)
                (window as? PointerCursorWindow)?.updatePointerCursor()
            }
        }
    }

    fileprivate var pointerCursor: NSCursor { isPointerEnabled ? .pointingHand : .arrow }
    // SwiftUI can give a non-clipping representable a visibleRect larger than
    // its bounds. Using that rect alone makes adjacent controls overlap.
    fileprivate var pointerRect: NSRect { bounds.intersection(visibleRect) }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func resetCursorRects() {
        super.resetCursorRects()
        guard !pointerRect.isEmpty else { return }
        // An explicit arrow also overrides a clickable parent row beneath a
        // disabled child button.
        addCursorRect(pointerRect, cursor: pointerCursor)
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        Self.regions.add(self)
        window?.invalidateCursorRects(for: self)
    }
}

/// SwiftUI's hosting view can replace an overlay's cursor rect during mouse
/// dispatch. Apply the action cursor *after* that dispatch, on every movement,
/// rather than relying on which overlapping cursor rect AppKit picks first.
final class PointerCursorWindow: NSWindow {
    private var pointerLocation: NSPoint?
    private var appliedCursor: NSCursor?
    var onShortcut: ((AppCommand) -> Bool)?

    private func handleShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        if let recorder = firstResponder as? ShortcutCaptureView, recorder.recording {
            recorder.capture(event)
            return true
        }
        guard attachedSheet == nil else { return false }
        if let command = ShortcutPreferences.shared.command(for: event) {
            if command == .increaseFont { Preferences.shared.adjustInterfaceZoom(by: 1); return true }
            if command == .decreaseFont { Preferences.shared.adjustInterfaceZoom(by: -1); return true }
            if command == .resetInterfaceZoom { Preferences.shared.setInterfaceZoomLevel(0); return true }
            if onShortcut?(command) == true { return true }
        }
        // Native text views and Ghostty have their own Command-C/V/etc.
        // Stop those defaults from surviving after a user clears or rebinds them.
        return ShortcutPreferences.shared.isRetiredEditingShortcut(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleShortcut(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if handleShortcut(event) { return }
        switch event.type {
        case .mouseMoved, .cursorUpdate, .mouseEntered, .mouseExited,
             .leftMouseUp, .rightMouseUp, .otherMouseUp:
            pointerLocation = event.locationInWindow
            super.sendEvent(event)
            updatePointerCursor()
        default:
            super.sendEvent(event)
        }
    }

    func updatePointerCursor() {
        guard let pointerLocation else { return }
        // The smallest overlapping action wins: e.g. a disabled close button
        // inside a clickable tab must show an arrow rather than the tab's hand.
        let region = PointerCursorView.regions.allObjects
            .filter { view in
                view.window === self && !view.isHiddenOrHasHiddenAncestor &&
                view.pointerRect.contains(view.convert(pointerLocation, from: nil))
            }
            .min { lhs, rhs in
                lhs.pointerRect.width * lhs.pointerRect.height < rhs.pointerRect.width * rhs.pointerRect.height
            }
        if let region {
            let cursor = region.pointerCursor
            cursor.set()
            appliedCursor = cursor
        } else {
            // Preserve any I-beam/resize cursor selected by the native target.
            if let appliedCursor, NSCursor.current == appliedCursor { NSCursor.arrow.set() }
            appliedCursor = nil
        }
    }
}
