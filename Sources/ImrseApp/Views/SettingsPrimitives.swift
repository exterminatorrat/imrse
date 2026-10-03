#if os(macOS)
import AppKit
import ImrseCore
import SwiftUI

enum ImrseSettingsMetrics {
    static let windowWidth: CGFloat = 900
    static let windowHeight: CGFloat = 570
    static let sidebarWidth: CGFloat = 176
    static let sidebarHorizontalPadding: CGFloat = 16
    static let contentHorizontalPadding: CGFloat = 28
    static let contentTopPadding: CGFloat = 36
    static let sectionSpacing: CGFloat = 20
    static let rowHeight: CGFloat = 46
    static let controlWidth: CGFloat = 160
    static let generalControlInset: CGFloat = 88
    static let controlHeight: CGFloat = 34
    static let controlCornerRadius: CGFloat = 8
    static let groupCornerRadius: CGFloat = 10
    static let selectionCornerRadius: CGFloat = 9
    static let sheetCornerRadius: CGFloat = 12
    static let dividerOpacity: Double = 0.11
}

enum ImrseSettingsPalette {
    static func window(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.075, green: 0.075, blue: 0.075) : Color(red: 0.985, green: 0.985, blue: 0.985)
    }

    static func sidebar(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.06, green: 0.06, blue: 0.06) : Color(red: 0.965, green: 0.965, blue: 0.965)
    }

    static func selection(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.09) : Color.black.opacity(0.055)
    }

    static func control(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.045) : Color.white.opacity(0.62)
    }

    static func border(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.115)
    }

    static func secondary(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.56) : Color.black.opacity(0.54)
    }
}

private struct SettingsScrollOffsetPreferenceKey: PreferenceKey {
    static let defaultValue = CGFloat.zero

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = min(value, nextValue())
    }
}

extension Font {
    static let imrseTitle = Font.system(size: 24, weight: .semibold, design: .default)
    static let imrseSidebarBrand = Font.system(size: 18, weight: .regular, design: .default)
    static let imrseSidebarItem = Font.system(size: 12.5, weight: .regular, design: .default)
    static let imrseBody = Font.system(size: 13, weight: .regular, design: .default)
    static let imrseBodyStrong = Font.system(size: 13, weight: .medium, design: .default)
    static let imrseCaption = Font.system(size: 11, weight: .regular, design: .default)
}

extension MotionPreference {
    var settingsTitle: String {
        switch self {
        case .instant: "Instant"
        case .quick: "Quick"
        case .smooth: "Smooth"
        case .balanced: "Balanced"
        case .slow: "Slow"
        }
    }
}

extension AppearancePreference {
    var settingsTitle: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var settingsColorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var settingsNSAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

struct SettingsPage<Content: View>: View {
    let title: String
    let subtitle: String?
    let symbol: String?
    let content: Content

    init(title: String, subtitle: String? = nil, symbol: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        SettingsScrollView {
            VStack(alignment: .leading, spacing: ImrseSettingsMetrics.sectionSpacing) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 10) {
                        if let symbol {
                            SettingsIcon(symbol: symbol, size: 26)
                        }

                        Text(title)
                            .font(.imrseTitle)
                            .tracking(-0.35)
                    }

                    if let subtitle {
                        Text(subtitle)
                            .font(.imrseCaption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                content
            }
            .padding(.top, ImrseSettingsMetrics.contentTopPadding)
            .padding(.horizontal, ImrseSettingsMetrics.contentHorizontalPadding)
            .padding(.bottom, 36)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct SettingsScrollView<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var scheme
    @Namespace private var scrollSpace
    @State private var scrollOffset: CGFloat = 0
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                content
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: SettingsScrollOffsetPreferenceKey.self,
                            value: geometry.frame(in: .named(scrollSpace)).minY
                        )
                    }
                }
            }
            .scrollIndicators(.hidden)
            .coordinateSpace(name: scrollSpace)

            if scrollOffset < -1 {
                scrollEdgeCue
            }
        }
        .onPreferenceChange(SettingsScrollOffsetPreferenceKey.self) { scrollOffset = $0 }
    }

    @ViewBuilder
    private var scrollEdgeCue: some View {
        Group {
            if reduceTransparency {
                ImrseSettingsPalette.window(scheme)
            } else {
                Rectangle()
                    .fill(.ultraThinMaterial)
            }
        }
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black.opacity(0.7), location: 0.45),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .frame(maxWidth: .infinity)
        .frame(height: 24)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct SettingsSection<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    let title: String
    let symbol: String?
    let detail: String?
    let content: Content

    init(title: String, symbol: String? = nil, detail: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.detail = detail
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    if let symbol {
                        SettingsIcon(symbol: symbol, size: 18)
                    }

                    Text(title)
                        .font(.imrseBodyStrong)
                }

                if let detail {
                    Text(detail)
                        .font(.imrseCaption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)

            content
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: ImrseSettingsMetrics.groupCornerRadius, style: .continuous)
                .fill(ImrseSettingsPalette.control(scheme))
        }
        .overlay {
            RoundedRectangle(cornerRadius: ImrseSettingsMetrics.groupCornerRadius, style: .continuous)
                .stroke(ImrseSettingsPalette.border(scheme), lineWidth: 0.75)
        }
    }
}

struct SettingsHint: View {
    let title: String
    let detail: String
    let symbol: String

    init(title: String, detail: String, symbol: String = "lightbulb") {
        self.title = title
        self.detail = detail
        self.symbol = symbol
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            SettingsIcon(symbol: symbol, size: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.imrseBodyStrong)

                Text(detail)
                    .font(.imrseCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum SettingsStatusTone {
    case neutral
    case positive
    case warning
}

struct SettingsStatusBadge: View {
    @Environment(\.colorScheme) private var scheme
    let title: String
    let symbol: String
    let tone: SettingsStatusTone

    init(title: String, symbol: String, tone: SettingsStatusTone = .neutral) {
        self.title = title
        self.symbol = symbol
        self.tone = tone
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))

            Text(title)
                .font(.system(size: 11, weight: .medium, design: .default))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(color.opacity(0.1))
        }
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch tone {
        case .neutral: .secondary
        case .positive:
            scheme == .dark
                ? Color(red: 0.40, green: 0.78, blue: 0.52)
                : Color(red: 0.13, green: 0.43, blue: 0.24)
        case .warning:
            scheme == .dark
                ? Color(red: 0.92, green: 0.69, blue: 0.30)
                : Color(red: 0.50, green: 0.32, blue: 0.08)
        }
    }
}

struct SettingsIcon: View {
    let symbol: String
    var size: CGFloat = 32

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.48, weight: .medium, design: .default))
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
            .background {
                RoundedRectangle(cornerRadius: min(8, size * 0.24), style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            }
            .accessibilityHidden(true)
    }
}

struct SettingsKeycap: View {
    @Environment(\.colorScheme) private var scheme
    let value: String

    var body: some View {
        Text(value)
            .font(.system(size: 11, weight: .medium, design: .default))
            .foregroundStyle(.primary)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(ImrseSettingsPalette.border(scheme), lineWidth: 0.5)
            }
            .fixedSize()
    }
}

struct ImrseLabeledRow<Content: View>: View {
    let title: String
    let subtitle: String?
    let alignment: VerticalAlignment
    let content: Content

    init(_ title: String, subtitle: String? = nil, alignment: VerticalAlignment? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.alignment = alignment ?? (subtitle == nil ? .center : .top)
        self.content = content()
    }

    var body: some View {
        HStack(alignment: alignment, spacing: 24) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.imrseBody)

                if let subtitle {
                    Text(subtitle)
                        .font(.imrseCaption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            content
        }
        .frame(minHeight: ImrseSettingsMetrics.rowHeight)
    }
}

struct ImrseDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(ImrseSettingsMetrics.dividerOpacity))
            .frame(height: 1)
    }
}

struct ImrseControlBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        RoundedRectangle(cornerRadius: ImrseSettingsMetrics.controlCornerRadius, style: .continuous)
            .fill(ImrseSettingsPalette.control(scheme))
            .overlay {
                RoundedRectangle(cornerRadius: ImrseSettingsMetrics.controlCornerRadius, style: .continuous)
                    .stroke(ImrseSettingsPalette.border(scheme), lineWidth: 0.75)
            }
    }
}

struct ImrseMenuLabel: View {
    let title: String
    var width: CGFloat = ImrseSettingsMetrics.controlWidth

    init(_ title: String, width: CGFloat = ImrseSettingsMetrics.controlWidth) {
        self.title = title
        self.width = width
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .font(.imrseBody)
        .padding(.horizontal, 12)
        .frame(width: width, height: ImrseSettingsMetrics.controlHeight)
        .contentShape(Rectangle())
    }
}

struct ImrseNativeMenuItem {
    let title: String
    let state: NSControl.StateValue
    let isEnabled: Bool
    let action: () -> Void
}

@MainActor
private final class ImrseMenuPopupCell: NSPopUpButtonCell {
    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        var insetFrame = cellFrame
        insetFrame.origin.x += 6
        insetFrame.size.width = max(0, insetFrame.width - 6)
        super.drawInterior(withFrame: insetFrame, in: controlView)
    }
}

@MainActor
struct ImrseNativeMenuButton: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    let title: String
    let accessibilityLabel: String
    let items: [ImrseNativeMenuItem]

    @MainActor
    final class Coordinator: NSObject {
        var items: [ImrseNativeMenuItem] = []

        @objc func activate(_ sender: NSMenuItem) {
            guard items.indices.contains(sender.tag), items[sender.tag].isEnabled else { return }
            items[sender.tag].action()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        let cell = ImrseMenuPopupCell(textCell: "", pullsDown: true)
        cell.arrowPosition = .arrowAtCenter
        button.cell = cell
        button.isBordered = false
        button.focusRingType = .exterior
        button.controlSize = .regular
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        guard let cell = button.cell as? ImrseMenuPopupCell else { return }
        cell.usesItemFromMenu = true
        cell.altersStateOfSelectedItem = false
        cell.autoenablesItems = false
        cell.alignment = .left
        cell.lineBreakMode = .byTruncatingMiddle
        cell.font = .systemFont(ofSize: 13)
        button.pullsDown = true
        button.autoenablesItems = false
        button.menu = Self.makeMenu(title: title, items: items, coordinator: context.coordinator)
        button.isEnabled = isEnabled && items.contains { $0.isEnabled }
        button.setAccessibilityLabel(accessibilityLabel)
        button.setAccessibilityValue(title)
        button.setAccessibilityHelp("Choose \(accessibilityLabel)")
    }

    static func makeMenu(title: String, items: [ImrseNativeMenuItem], coordinator: Coordinator) -> NSMenu {
        coordinator.items = items
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))

        for (index, item) in items.enumerated() {
            let menuItem = NSMenuItem(title: item.title, action: #selector(Coordinator.activate(_:)), keyEquivalent: "")
            menuItem.target = coordinator
            menuItem.tag = index
            menuItem.state = item.state
            menuItem.isEnabled = item.isEnabled
            menu.addItem(menuItem)
        }

        return menu
    }
}

struct ImrseMenuControl<Option: Hashable>: View {
    @Environment(\.isEnabled) private var isEnabled
    @Binding var selection: Option
    let options: [Option]
    let title: (Option) -> String
    var width = ImrseSettingsMetrics.controlWidth
    var accessibilityLabel: String?

    init(
        selection: Binding<Option>,
        options: [Option],
        title: @escaping (Option) -> String,
        width: CGFloat = ImrseSettingsMetrics.controlWidth,
        accessibilityLabel: String? = nil
    ) {
        _selection = selection
        self.options = options
        self.title = title
        self.width = width
        self.accessibilityLabel = accessibilityLabel
    }

    var body: some View {
        ImrseNativeMenuButton(
            title: title(selection),
            accessibilityLabel: accessibilityLabel ?? title(selection),
            items: menuItems(isEnabled: isEnabled)
        )
        .frame(width: width, height: ImrseSettingsMetrics.controlHeight)
        .background(ImrseControlBackground())
        .contentShape(Rectangle())
    }

    func menuItems(isEnabled: Bool) -> [ImrseNativeMenuItem] {
        options.map { option in
            ImrseNativeMenuItem(
                title: title(option),
                state: selection == option ? .on : .off,
                isEnabled: isEnabled
            ) {
                selection = option
            }
        }
    }
}

struct ImrseTextField: View {
    let placeholder: String
    @Binding var text: String
    var width: CGFloat? = nil

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.imrseBody)
            .padding(.horizontal, 10)
            .frame(width: width, height: ImrseSettingsMetrics.controlHeight)
            .background(ImrseControlBackground())
    }
}

struct ImrseTextEditor: View {
    @Binding var text: String

    var body: some View {
        TextEditor(text: $text)
            .font(.imrseBody)
            .scrollContentBackground(.hidden)
            .padding(7)
            .frame(minHeight: 92)
            .background(ImrseControlBackground())
    }
}

struct ImrsePrimaryButton: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.imrseBodyStrong)
                .foregroundStyle(isEnabled ? ImrseSettingsPalette.window(scheme) : Color.secondary)
                .padding(.horizontal, 15)
                .frame(height: 30)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isEnabled ? Color.primary : .clear)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(isEnabled ? .clear : ImrseSettingsPalette.border(scheme), lineWidth: 0.75)
                }
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

struct ImrseSecondaryButton: View {
    @Environment(\.isEnabled) private var isEnabled
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.imrseBody)
                .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(ImrseControlBackground())
                .contentShape(
                    RoundedRectangle(cornerRadius: ImrseSettingsMetrics.controlCornerRadius, style: .continuous)
                )
        }
        .buttonStyle(.plain)
    }
}

struct ImrseDestructiveButton: View {
    @Environment(\.isEnabled) private var isEnabled
    let title: String
    let action: () -> Void

    var body: some View {
        Button(role: .destructive, action: action) {
            Text(title)
                .font(.imrseBody)
                .foregroundStyle(isEnabled ? Color.red : Color.secondary)
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(ImrseControlBackground())
                .contentShape(
                    RoundedRectangle(cornerRadius: ImrseSettingsMetrics.controlCornerRadius, style: .continuous)
                )
        }
        .buttonStyle(.plain)
    }
}

struct ImrseShortcutBadge: View {
    let value: String

    var body: some View {
        Text(value)
            .font(.system(size: 10.5, weight: .medium, design: .default))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .frame(height: 21)
            .background(Color.primary.opacity(0.055))
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}
#endif
