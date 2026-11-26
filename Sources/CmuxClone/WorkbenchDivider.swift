import AppKit
import SwiftUI

struct WorkbenchPanels {
    enum Side { case left, right }

    let showsLeft: Bool
    let showsRight: Bool
    let dividerWidth: CGFloat
    let left: CGFloat
    let center: CGFloat
    let right: CGFloat
    private let leftMinimum: CGFloat
    private let centerMinimum: CGFloat
    private let rightMinimum: CGFloat

    init(width: CGFloat, left: CGFloat?, leftMinimum: CGFloat, right: CGFloat?) {
        showsLeft = left != nil
        showsRight = right != nil
        let dividerCount = CGFloat((showsLeft ? 1 : 0) + (showsRight ? 1 : 0))
        dividerWidth = min(5, width / (dividerCount + 1))
        let space = max(0, width - dividerCount * dividerWidth)

        let leftFloor = showsLeft ? leftMinimum : 0
        let centerFloor: CGFloat = 220
        let rightFloor: CGFloat = showsRight ? 240 : 0
        let minimum = leftFloor + centerFloor + rightFloor
        // At extreme zoom levels, all three minimums may exceed the visible canvas.
        let scale = min(1, space / minimum)
        self.leftMinimum = leftFloor * scale
        centerMinimum = centerFloor * scale
        rightMinimum = rightFloor * scale

        let leftExtra = max(0, (left ?? 0) - leftFloor)
        let rightExtra = max(0, (right ?? 0) - rightFloor)
        let budget = max(0, space - minimum)
        let requestedExtra = leftExtra + rightExtra
        let extraScale = requestedExtra > budget ? budget / requestedExtra : 1
        self.left = self.leftMinimum + leftExtra * extraScale
        self.right = rightMinimum + rightExtra * extraScale
        center = max(0, space - self.left - self.right)
    }

    func resized(_ side: Side, by distance: CGFloat) -> (left: CGFloat, right: CGFloat) {
        let centerSlack = max(0, center - centerMinimum)
        switch side {
        case .left:
            let oppositeSlack = max(0, right - rightMinimum)
            let growth = min(centerSlack + oppositeSlack, max(leftMinimum - left, distance))
            return (left + growth, right - max(0, growth - centerSlack))
        case .right:
            let oppositeSlack = max(0, left - leftMinimum)
            let growth = min(centerSlack + oppositeSlack, max(rightMinimum - right, -distance))
            return (left - max(0, growth - centerSlack), right + growth)
        }
    }
}

struct WorkbenchDivider: NSViewRepresentable {
    let startDrag: () -> (CGFloat) -> Void

    func makeNSView(context: Context) -> WorkbenchDividerView { WorkbenchDividerView() }

    func updateNSView(_ view: WorkbenchDividerView, context: Context) {
        view.startDrag = startDrag
    }
}

final class WorkbenchDividerView: NSView {
    var startDrag: (() -> (CGFloat) -> Void)?
    private var drag: (origin: CGFloat, update: (CGFloat) -> Void)?

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds.intersection(visibleRect), cursor: .resizeLeftRight)
    }

    override func draw(_ dirtyRect: NSRect) {
        let lineWidth: CGFloat = drag == nil ? 1 : 2
        let color = drag == nil ? NSColor.separatorColor.withAlphaComponent(0.5) : NSColor.controlAccentColor
        color.setFill()
        NSRect(x: bounds.midX - lineWidth / 2, y: 0, width: lineWidth, height: bounds.height).fill()
    }

    override func mouseDown(with event: NSEvent) {
        guard let startDrag else { return }
        drag = (event.locationInWindow.x, startDrag())
        NSCursor.resizeLeftRight.set()
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        NSCursor.resizeLeftRight.set()
        drag.update(event.locationInWindow.x - drag.origin)
    }

    override func mouseUp(with event: NSEvent) {
        drag = nil
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        drag = nil
        needsDisplay = true
    }
}
