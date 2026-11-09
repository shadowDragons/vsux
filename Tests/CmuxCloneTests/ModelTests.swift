import XCTest
@testable import CmuxClone

final class ModelTests: XCTestCase {
    func testNestedSplitsCollapseWithoutLosingOtherPanes() {
        let a = UUID(), b = UUID(), c = UUID()
        let layout = PaneLayout.leaf(a).splitting(a, new: b, axis: .horizontal).splitting(b, new: c, axis: .vertical, before: true)
        XCTAssertEqual(layout.leaves, [a, c, b])
        let remaining = layout.removing(b)!
        XCTAssertEqual(remaining.leaves, [a, c])
        XCTAssertEqual(remaining.removing(a), .leaf(c))
        XCTAssertNil(PaneLayout.leaf(a).removing(a))
        XCTAssertEqual(layout.splitting(UUID(), new: UUID(), axis: .horizontal), layout)
    }
    func testResizeClampsAndEqualizePreservesTree() {
        let id = UUID(), a = UUID(), b = UUID()
        let layout = PaneLayout.split(id: id, axis: .vertical, fraction: 0.5, first: .leaf(a), second: .leaf(b))
        if case .split(_, _, let fraction, _, _) = layout.resized(id, fraction: 9) { XCTAssertEqual(fraction, 0.85) } else { XCTFail() }
        XCTAssertEqual(layout.resized(id, fraction: -3).equalized(), layout)
    }
}
