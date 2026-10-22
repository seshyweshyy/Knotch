import SwiftUI

/// Exercises the actual shell shapes at compact, expanded, and overshoot sizes.
/// Run with script/test_animation_geometry.sh.
@main
struct AnimationGeometryTests {
    static func main() {
        let dimensions: [CGFloat] = [0, 1, 8, 16, 32, 64, 150, 300, 640]
        let radii: [CGFloat] = [-20, 0, 6, 14, 28, 100, 1_000]
        var checks = 0
        for width in dimensions {
            for height in dimensions {
                let rect = CGRect(x: 7, y: 11, width: width, height: height)
                for radius in radii {
                    check(BottomRoundedRectangle(radius: radius).path(in: rect), inside: rect)
                    checks += 1
                    for bottomRadius in radii {
                        check(NotchShape(topCornerRadius: radius, bottomCornerRadius: bottomRadius).path(in: rect), inside: rect)
                        checks += 1
                    }
                }
            }
        }
        print("Passed \(checks) shell geometry checks")
    }

    private static func check(_ path: Path, inside rect: CGRect) {
        guard !path.isEmpty else { return }
        let bounds = path.boundingRect
        precondition(bounds.minX.isFinite && bounds.minY.isFinite && bounds.maxX.isFinite && bounds.maxY.isFinite,
                     "Non-finite path for \(rect)")
        let tolerance: CGFloat = 0.001
        precondition(bounds.minX >= rect.minX - tolerance && bounds.maxX <= rect.maxX + tolerance &&
                     bounds.minY >= rect.minY - tolerance && bounds.maxY <= rect.maxY + tolerance,
                     "Path escaped shell bounds: \(bounds) outside \(rect)")
    }
}
