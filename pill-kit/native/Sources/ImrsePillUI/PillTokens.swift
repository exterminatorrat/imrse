import ImrsePillCore
import SwiftUI

public enum PillTokens {
    public static let width: CGFloat = 360
    public static let height: CGFloat = 52
    public static let horizontalPadding: CGFloat = 20
    public static let radius: CGFloat = 26
    public static let loaderSize: CGFloat = 24
    public static let loaderGap: CGFloat = 10
    public static let fontSize: CGFloat = 13
    public static let actionFontSize: CGFloat = 11
    public static let edgeInset: CGFloat = 20
    public static let bottomInset: CGFloat = 24
    public static let shadowPadding: CGFloat = 28

    public static func width(for phase: PillPhase) -> CGFloat {
        switch phase {
        case .hidden: return 0
        case .input: return Self.width
        case .processing: return 240
        case .applying: return 220
        case .success: return 180
        case .failure: return 300
        }
    }
}

public enum PillMotion: String, CaseIterable, Sendable {
    case instant, quick, smooth, balanced, slow
    public var duration: Double {
        switch self {
        case .instant: return 0
        case .quick: return 0.16
        case .smooth, .balanced: return 0.24
        case .slow: return 0.36
        }
    }
}
