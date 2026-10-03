#if canImport(SwiftUI)
import SwiftUI

struct ImrseDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(ImrseSettingsMetrics.dividerOpacity))
            .frame(height: 1)
    }
}

struct ImrseSectionHeader: View {
    let title: String
    let subtitle: String?

    init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.imrseTitle)
            if let subtitle {
                Text(subtitle)
                    .font(.imrseBody)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct ImrseLabeledRow<Content: View>: View {
    let title: String
    let subtitle: String?
    let content: Content

    init(_ title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        HStack(alignment: subtitle == nil ? .center : .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.imrseBody)
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

struct ImrseControlShell<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    var width: CGFloat? = 160
    let content: Content

    init(width: CGFloat? = 160, @ViewBuilder content: () -> Content) {
        self.width = width
        self.content = content()
    }

    var body: some View {
        content
            .font(.imrseBody)
            .padding(.horizontal, 11)
            .frame(width: width, height: ImrseSettingsMetrics.controlHeight, alignment: .leading)
            .background(ImrseSettingsPalette.control(scheme))
            .overlay(
                RoundedRectangle(cornerRadius: ImrseSettingsMetrics.controlCornerRadius, style: .continuous)
                    .stroke(ImrseSettingsPalette.border(scheme), lineWidth: 0.75)
            )
            .clipShape(RoundedRectangle(cornerRadius: ImrseSettingsMetrics.controlCornerRadius, style: .continuous))
    }
}

struct ImrseMenuControl<Option: Hashable & RawRepresentable>: View where Option.RawValue == String {
    @Binding var selection: Option
    let options: [Option]
    var width: CGFloat = 160

    var body: some View {
        Menu {
            Picker("", selection: $selection) {
                ForEach(options, id: \.self) { option in
                    Text(option.rawValue).tag(option)
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(selection.rawValue)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .frame(width: width, height: ImrseSettingsMetrics.controlHeight)
        .background(ImrseControlBackground())
    }
}

struct ImrseControlBackground: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        RoundedRectangle(cornerRadius: ImrseSettingsMetrics.controlCornerRadius, style: .continuous)
            .fill(ImrseSettingsPalette.control(scheme))
            .overlay(
                RoundedRectangle(cornerRadius: ImrseSettingsMetrics.controlCornerRadius, style: .continuous)
                    .stroke(ImrseSettingsPalette.border(scheme), lineWidth: 0.75)
            )
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

struct ImrseSecureField: View {
    let placeholder: String
    @Binding var text: String
    var width: CGFloat? = nil

    var body: some View {
        SecureField(placeholder, text: $text)
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
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.imrseBodyStrong)
                .foregroundStyle(ImrseSettingsPalette.window(scheme))
                .padding(.horizontal, 15)
                .frame(height: 30)
                .background(Color.primary)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

struct ImrseSecondaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.imrseBody)
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(ImrseControlBackground())
        }
        .buttonStyle(.plain)
    }
}

struct ImrseDestructiveButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.imrseBody)
            .foregroundStyle(.red)
    }
}

struct ImrseShortcutBadge: View {
    let value: String

    var body: some View {
        Text(value)
            .font(.system(size: 10.5, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .frame(height: 21)
            .background(Color.primary.opacity(0.055))
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

struct ImrseProviderGlyph: View {
    let type: ProviderType

    var body: some View {
        Group {
            switch type {
            case .openAI: Text("◎")
            case .openRouter: Text("↪")
            case .anthropic: Text("A")
            case .google: Text("G")
            case .openAICompatible: Image(systemName: "terminal")
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .frame(width: 18, height: 18)
    }
}
#endif
