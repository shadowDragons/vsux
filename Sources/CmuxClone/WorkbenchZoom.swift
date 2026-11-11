import AppKit
import Combine
import SwiftUI

/// VS Code's workbench scale: one level is a 20% multiplication.
enum WorkbenchZoom {
    static let levels = -8...8
    static func clamped(_ level: Int) -> Int { min(levels.upperBound, max(levels.lowerBound, level)) }
    static func factor(for level: Int) -> CGFloat { pow(1.2, Double(clamped(level))) }
}

/// Keep visual transforms inside SwiftUI's graph so its gesture hit testing
/// uses the same coordinates as drawing. Preserve the host and content state.
final class WorkbenchHostingView<Content: View>: NSView {
    let host: NSHostingView<WorkbenchScaledContent<Content>>
    private let preferences: Preferences
    private var observation: AnyCancellable?
    private(set) var zoomFactor: CGFloat

    init(rootView: Content, preferences: Preferences? = nil) {
        let preferences = preferences ?? .shared
        self.preferences = preferences
        zoomFactor = preferences.zoomFactor
        host = NSHostingView(rootView: WorkbenchScaledContent(content: rootView, preferences: preferences))
        host.sizingOptions = []
        super.init(frame: .zero)
        addSubview(host)
        observation = preferences.$interfaceZoomLevel.sink { [weak self] level in
            guard let self else { return }
            zoomFactor = WorkbenchZoom.factor(for: level)
            needsLayout = true
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }
    override func layout() {
        super.layout()
        host.frame = bounds
        host.layoutSubtreeIfNeeded()
        // Metal-backed terminals must redraw at the transformed pixel density.
        updateTerminals(in: host)
    }
    private func updateTerminals(in view: NSView) {
        if let terminal = view as? GhosttyTerminalView { terminal.needsLayout = true }
        view.subviews.forEach { updateTerminals(in: $0) }
    }
}

struct WorkbenchScaledContent<Content: View>: View {
    let content: Content
    @ObservedObject var preferences: Preferences
    var body: some View {
        GeometryReader { geometry in
            let factor = preferences.zoomFactor
            content
                .frame(width: geometry.size.width / factor, height: geometry.size.height / factor)
                .scaleEffect(factor, anchor: .topLeading)
        }
    }
}

/// Sheets have their own hosting window. Scale their fixed canvas too, and keep
/// every control reachable by scrolling when the canvas exceeds the display.
struct ZoomedSheetContent: ViewModifier {
    @ObservedObject var preferences: Preferences
    @State private var canvasSize = CGSize(width: 610, height: 700)
    func body(content: Content) -> some View {
        let factor = preferences.zoomFactor
        let screen = NSApp.keyWindow?.screen?.visibleFrame.size ?? NSScreen.main?.visibleFrame.size ?? NSSize(width: 1280, height: 900)
        ScrollView([.horizontal, .vertical]) {
            content.fixedSize()
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: SheetCanvasSize.self, value: geometry.size)
                })
                .scaleEffect(factor, anchor: .topLeading)
                .frame(width: canvasSize.width * factor, height: canvasSize.height * factor, alignment: .topLeading)
        }
        .onPreferenceChange(SheetCanvasSize.self) { canvasSize = $0 }
        .frame(width: min(canvasSize.width * factor, screen.width - 80), height: min(canvasSize.height * factor, screen.height - 100))
    }
}

private struct SheetCanvasSize: PreferenceKey {
    static var defaultValue = CGSize(width: 610, height: 700)
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

extension View {
    func workbenchSheetZoom() -> some View { modifier(ZoomedSheetContent(preferences: .shared)) }
}
