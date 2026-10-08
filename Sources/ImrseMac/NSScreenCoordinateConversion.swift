#if os(macOS)
import CoreGraphics

enum NSScreenCoordinateConversion {
    static func cocoaRect(from quartzRect: CGRect, displayBounds: CGRect, screenFrame: CGRect) -> CGRect? {
        guard quartzRect.origin.x.isFinite,
              quartzRect.origin.y.isFinite,
              quartzRect.width.isFinite,
              quartzRect.height.isFinite,
              displayBounds.width.isFinite,
              displayBounds.height.isFinite,
              screenFrame.origin.x.isFinite,
              screenFrame.origin.y.isFinite,
              screenFrame.width.isFinite,
              screenFrame.height.isFinite,
              quartzRect.width > 0,
              quartzRect.height > 0,
              displayBounds.width > 0,
              displayBounds.height > 0,
              screenFrame.width > 0,
              screenFrame.height > 0
        else {
            return nil
        }
        let scaleX = screenFrame.width / displayBounds.width
        let scaleY = screenFrame.height / displayBounds.height
        let rect = CGRect(
            x: screenFrame.minX + (quartzRect.minX - displayBounds.minX) * scaleX,
            y: screenFrame.maxY - (quartzRect.maxY - displayBounds.minY) * scaleY,
            width: quartzRect.width * scaleX,
            height: quartzRect.height * scaleY
        )
        guard rect.origin.x.isFinite,
              rect.origin.y.isFinite,
              rect.width.isFinite,
              rect.height.isFinite,
              rect.maxX.isFinite,
              rect.maxY.isFinite
        else {
            return nil
        }
        return rect
    }
}
#endif
