import SwiftUI

/// VS Code Codicons git-branch, Microsoft and contributors, CC BY 4.0.
/// Original geometry retained; see Resources/Icons and Resources/Licenses.
struct GitBranchIcon: View {
    @ObservedObject private var languagePreferences = LanguagePreferences.shared
    var size: CGFloat = 16

    var body: some View {
        let _ = languagePreferences.language
        GitBranchGlyph().fill(.foreground)
            .frame(width: size, height: size).accessibilityHidden(true)
    }
}

private struct GitBranchGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 14, y: 5.5))
        path.addCurve(to: CGPoint(x: 11.5, y: 3), control1: CGPoint(x: 14, y: 4.121), control2: CGPoint(x: 12.879, y: 3))
        path.addCurve(to: CGPoint(x: 9, y: 5.5), control1: CGPoint(x: 10.121, y: 3), control2: CGPoint(x: 9, y: 4.121))
        path.addCurve(to: CGPoint(x: 10.93, y: 7.928), control1: CGPoint(x: 9, y: 6.682), control2: CGPoint(x: 9.826, y: 7.669))
        path.addCurve(to: CGPoint(x: 9.5, y: 9), control1: CGPoint(x: 10.744, y: 8.546), control2: CGPoint(x: 10.177, y: 9))
        path.addLine(to: CGPoint(x: 6.5, y: 9))
        path.addCurve(to: CGPoint(x: 5, y: 9.512), control1: CGPoint(x: 5.935, y: 9), control2: CGPoint(x: 5.419, y: 9.195))
        path.addLine(to: CGPoint(x: 5, y: 4.949))
        path.addCurve(to: CGPoint(x: 7, y: 2.5), control1: CGPoint(x: 6.14, y: 4.717), control2: CGPoint(x: 7, y: 3.707))
        path.addCurve(to: CGPoint(x: 4.5, y: 0), control1: CGPoint(x: 7, y: 1.121), control2: CGPoint(x: 5.879, y: 0))
        path.addCurve(to: CGPoint(x: 2, y: 2.5), control1: CGPoint(x: 3.121, y: 0), control2: CGPoint(x: 2, y: 1.121))
        path.addCurve(to: CGPoint(x: 4, y: 4.949), control1: CGPoint(x: 2, y: 3.708), control2: CGPoint(x: 2.86, y: 4.717))
        path.addLine(to: CGPoint(x: 4, y: 11.05))
        path.addCurve(to: CGPoint(x: 2, y: 13.499), control1: CGPoint(x: 2.86, y: 11.282), control2: CGPoint(x: 2, y: 12.292))
        path.addCurve(to: CGPoint(x: 4.5, y: 15.999), control1: CGPoint(x: 2, y: 14.878), control2: CGPoint(x: 3.121, y: 15.999))
        path.addCurve(to: CGPoint(x: 7, y: 13.499), control1: CGPoint(x: 5.879, y: 15.999), control2: CGPoint(x: 7, y: 14.878))
        path.addCurve(to: CGPoint(x: 5.07, y: 11.071), control1: CGPoint(x: 7, y: 12.317), control2: CGPoint(x: 6.174, y: 11.33))
        path.addCurve(to: CGPoint(x: 6.5, y: 9.999), control1: CGPoint(x: 5.256, y: 10.453), control2: CGPoint(x: 5.823, y: 9.999))
        path.addLine(to: CGPoint(x: 9.5, y: 9.999))
        path.addCurve(to: CGPoint(x: 11.954, y: 7.953), control1: CGPoint(x: 10.723, y: 9.999), control2: CGPoint(x: 11.74, y: 9.115))
        path.addCurve(to: CGPoint(x: 14, y: 5.5), control1: CGPoint(x: 13.116, y: 7.738), control2: CGPoint(x: 14, y: 6.723))
        path.closeSubpath()
        path.move(to: CGPoint(x: 3, y: 2.5))
        path.addCurve(to: CGPoint(x: 4.5, y: 1), control1: CGPoint(x: 3, y: 1.673), control2: CGPoint(x: 3.673, y: 1))
        path.addCurve(to: CGPoint(x: 6, y: 2.5), control1: CGPoint(x: 5.327, y: 1), control2: CGPoint(x: 6, y: 1.673))
        path.addCurve(to: CGPoint(x: 4.5, y: 4), control1: CGPoint(x: 6, y: 3.327), control2: CGPoint(x: 5.327, y: 4))
        path.addCurve(to: CGPoint(x: 3, y: 2.5), control1: CGPoint(x: 3.673, y: 4), control2: CGPoint(x: 3, y: 3.327))
        path.closeSubpath()
        path.move(to: CGPoint(x: 6, y: 13.5))
        path.addCurve(to: CGPoint(x: 4.5, y: 15), control1: CGPoint(x: 6, y: 14.327), control2: CGPoint(x: 5.327, y: 15))
        path.addCurve(to: CGPoint(x: 3, y: 13.5), control1: CGPoint(x: 3.673, y: 15), control2: CGPoint(x: 3, y: 14.327))
        path.addCurve(to: CGPoint(x: 4.5, y: 12), control1: CGPoint(x: 3, y: 12.673), control2: CGPoint(x: 3.673, y: 12))
        path.addCurve(to: CGPoint(x: 6, y: 13.5), control1: CGPoint(x: 5.327, y: 12), control2: CGPoint(x: 6, y: 12.673))
        path.closeSubpath()
        path.move(to: CGPoint(x: 11.5, y: 7))
        path.addCurve(to: CGPoint(x: 10, y: 5.5), control1: CGPoint(x: 10.673, y: 7), control2: CGPoint(x: 10, y: 6.327))
        path.addCurve(to: CGPoint(x: 11.5, y: 4), control1: CGPoint(x: 10, y: 4.673), control2: CGPoint(x: 10.673, y: 4))
        path.addCurve(to: CGPoint(x: 13, y: 5.5), control1: CGPoint(x: 12.327, y: 4), control2: CGPoint(x: 13, y: 4.673))
        path.addCurve(to: CGPoint(x: 11.5, y: 7), control1: CGPoint(x: 13, y: 6.327), control2: CGPoint(x: 12.327, y: 7))
        path.closeSubpath()
        return path.applying(CGAffineTransform(a: rect.width / 16, b: 0, c: 0,
                                              d: rect.height / 16, tx: rect.minX, ty: rect.minY))
    }
}
