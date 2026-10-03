#if canImport(SwiftUI)
import SwiftUI

/// The selected imrse 04 mark: dot + vertical rounded bar.
struct ImrseMark: View {
    var size: CGFloat = 44
    var color: Color = .primary

    var body: some View {
        Canvas { context, canvasSize in
            let scale = min(canvasSize.width, canvasSize.height) / 100
            let dot = CGRect(
                x: (34 - 12) * scale,
                y: (50 - 12) * scale,
                width: 24 * scale,
                height: 24 * scale
            )
            let bar = CGRect(
                x: 58 * scale,
                y: 22 * scale,
                width: 18 * scale,
                height: 56 * scale
            )
            context.fill(Path(ellipseIn: dot), with: .color(color))
            context.fill(
                Path(roundedRect: bar, cornerRadius: 9 * scale),
                with: .color(color)
            )
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
#endif
