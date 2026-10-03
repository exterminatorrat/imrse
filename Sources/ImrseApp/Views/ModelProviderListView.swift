#if os(macOS)
import ImrseCore
import SwiftUI

struct ModelProviderListView: View {
    let providers: [ProviderConfiguration]
    let defaultProviderID: String?
    let onEdit: (ProviderConfiguration) -> Void
    let onAdd: () -> Void

    var body: some View {
        SettingsPage(
            title: "Models",
            subtitle: "Use local inference, your ChatGPT plan, or an API provider billed separately.",
            symbol: "cpu"
        ) {
            SettingsSection(
                title: "Providers",
                symbol: "square.stack.3d.up",
                detail: "The default provider handles presets that don't choose another one."
            ) {
                if providers.isEmpty {
                    SettingsHint(
                        title: "No providers yet",
                        detail: "Add a model on this Mac, use models available to your ChatGPT plan, or choose an API provider billed separately.",
                        symbol: "plus.circle"
                    )
                    .padding(.vertical, 8)

                    addProviderButton
                } else {
                    VStack(spacing: 0) {
                        ForEach(providers) { provider in
                            ProviderSettingsListRow(
                                provider: provider,
                                isDefault: provider.id == defaultProviderID,
                                action: { onEdit(provider) }
                            )
                            if provider.id != providers.last?.id {
                                ImrseDivider()
                                    .padding(.leading, 46)
                            }
                        }

                        addProviderButton
                    }
                }
            }
        }
    }

    private var addProviderButton: some View {
        HStack {
            Spacer()
            ImrsePrimaryButton(title: "Add provider", action: onAdd)
                .accessibilityHint("Choose a provider type")
        }
    }
}

private struct ProviderSettingsListRow: View {
    let provider: ProviderConfiguration
    let isDefault: Bool
    let action: () -> Void

    private var presentation: ProviderListPresentation { ProviderListPresentation(provider: provider) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                SettingsIcon(symbol: presentation.symbolName, size: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(presentation.title)
                        .font(.imrseBodyStrong)
                        .lineLimit(1)
                    Text(presentation.detail)
                        .font(.imrseCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(presentation.detail)
                }

                Spacer(minLength: 12)

                SettingsStatusBadge(
                    title: isDefault ? "Default" : "Saved",
                    symbol: isDefault ? "checkmark.circle.fill" : "checkmark.circle",
                    tone: isDefault ? .positive : .neutral
                )

                Image(systemName: "chevron.right")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 13)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Edit provider settings")
    }
}

struct ProviderListPresentation: Identifiable {
    let provider: ProviderConfiguration

    var id: String { provider.id }
    var title: String { provider.name }

    var detail: String {
        if let section = ModelProviderSection.forProvider(provider), section != .custom {
            return "\(section.listDescription) · \(provider.model)"
        }
        return "\(provider.endpoint.host ?? "Custom endpoint") · \(provider.model) · billing depends on service"
    }

    var symbolName: String {
        ModelProviderSection.forProvider(provider)?.symbolName ?? "server.rack"
    }
}

struct ProviderAddChoiceList: View {
    let onSelect: (ModelProviderSection) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(ModelProviderSection.allCases) { section in
                Button {
                    onSelect(section)
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(symbol: section.symbolName, size: 26)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(section.title)
                                .font(.imrseBodyStrong)
                                .foregroundStyle(.primary)

                            Text(section.listDescription)
                                .font(.imrseCaption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 12)

                        Image(systemName: "chevron.right")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 13)
                    .padding(.vertical, 11)
                    .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityHint("Add \(section.title)")
                if section != ModelProviderSection.allCases.last {
                    ImrseDivider()
                        .padding(.leading, 52)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
