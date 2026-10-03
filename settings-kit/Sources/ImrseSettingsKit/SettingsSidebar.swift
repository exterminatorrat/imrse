#if canImport(SwiftUI)
import SwiftUI

struct SettingsSidebar: View {
    @Binding var navigation: SettingsNavigation
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("imrse")
                .font(.system(size: 28, weight: .regular, design: .default))
                .tracking(-1.2)
                .padding(.top, 64)
                .padding(.horizontal, 22)
                .padding(.bottom, 28)

            VStack(spacing: 7) {
                ForEach(SettingsSection.primarySidebar) { section in
                    SettingsSidebarRow(
                        section: section,
                        isSelected: navigation.section == section
                    ) {
                        navigation.select(section)
                    }
                }
            }
            .padding(.horizontal, 12)

            Spacer(minLength: 24)

            ImrseDivider()
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

            ForEach(SettingsSection.bottomSidebar) { section in
                SettingsSidebarRow(
                    section: section,
                    isSelected: navigation.section == section
                ) {
                    navigation.select(section)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 18)
        }
        .frame(width: ImrseSettingsMetrics.sidebarWidth)
        .background(ImrseSettingsPalette.sidebar(scheme))
    }
}

private struct SettingsSidebarRow: View {
    let section: SettingsSection
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: section.symbolName)
                    .font(.system(size: 14, weight: .regular))
                    .frame(width: 19)
                Text(section.rawValue)
                    .font(.system(size: 13.5, weight: .regular))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .frame(height: 42)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? ImrseSettingsPalette.selection(scheme) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private extension SettingsSection {
    var symbolName: String {
        switch self {
        case .general: "gearshape"
        case .models: "cube"
        case .presets: "line.3.horizontal.decrease"
        case .shortcuts: "keyboard"
        case .advanced: "slider.horizontal.3"
        case .about: "info.circle"
        }
    }
}
#endif
