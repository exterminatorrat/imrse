#if canImport(SwiftUI)
import SwiftUI

public enum ImrseSettingsMetrics {
    public static let windowWidth: CGFloat = 900
    public static let windowHeight: CGFloat = 570
    public static let sidebarWidth: CGFloat = 182
    public static let sidebarHorizontalPadding: CGFloat = 16
    public static let contentHorizontalPadding: CGFloat = 36
    public static let contentTopPadding: CGFloat = 62
    public static let rowHeight: CGFloat = 52
    public static let controlHeight: CGFloat = 34
    public static let controlCornerRadius: CGFloat = 8
    public static let selectionCornerRadius: CGFloat = 9
    public static let sheetCornerRadius: CGFloat = 12
    public static let dividerOpacity: Double = 0.11
}

public enum ImrseSettingsPalette {
    public static func window(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.075, green: 0.075, blue: 0.075) : Color(red: 0.985, green: 0.985, blue: 0.985)
    }

    public static func sidebar(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.06, green: 0.06, blue: 0.06) : Color(red: 0.965, green: 0.965, blue: 0.965)
    }

    public static func selection(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.09) : Color.black.opacity(0.055)
    }

    public static func control(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.045) : Color.white.opacity(0.62)
    }

    public static func border(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.115)
    }

    public static func secondary(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.56) : Color.black.opacity(0.54)
    }
}

public extension Font {
    static let imrseTitle = Font.system(size: 24, weight: .semibold, design: .default)
    static let imrseSidebarBrand = Font.system(size: 18, weight: .regular, design: .default)
    static let imrseSidebarItem = Font.system(size: 12.5, weight: .regular, design: .default)
    static let imrseBody = Font.system(size: 13.5, weight: .regular, design: .default)
    static let imrseBodyStrong = Font.system(size: 13.5, weight: .medium, design: .default)
    static let imrseCaption = Font.system(size: 12.5, weight: .regular, design: .default)
}
#endif
