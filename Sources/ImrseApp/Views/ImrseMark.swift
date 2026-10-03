#if os(macOS)
import SwiftUI

struct ImrseMark: View {
    private let size: CGFloat
    private let color: Color

    init(size: CGFloat = 24, color: Color = .primary) {
        self.size = size
        self.color = color
    }

    var body: some View {
        ImrseMarkShape()
            .fill(color)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct ImrseMarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 100
        let sy = rect.height / 100
        var path = Path()
        path.addEllipse(in: CGRect(
            x: 22 * sx,
            y: 38 * sy,
            width: 24 * sx,
            height: 24 * sy
        ))
        path.addRoundedRect(
            in: CGRect(x: 58 * sx, y: 22 * sy, width: 18 * sx, height: 56 * sy),
            cornerSize: CGSize(width: 9 * sx, height: 9 * sy)
        )
        return path
    }
}
#endif
