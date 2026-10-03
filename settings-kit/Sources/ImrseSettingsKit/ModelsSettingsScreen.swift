#if canImport(SwiftUI)
import SwiftUI

struct ModelsSettingsScreen: View {
    @Binding var state: ImrseSettingsState
    let actions: ImrseSettingsActions

    @State private var sheet: ProviderSheet?

    var body: some View {
        SettingsPage(title: "Models") {
            VStack(alignment: .leading, spacing: 14) {
                Text("Providers")
                    .font(.imrseBodyStrong)

                VStack(spacing: 0) {
                    ForEach(Array(state.providers.enumerated()), id: \.element.id) { index, provider in
                        Button {
                            sheet = .edit(provider)
                        } label: {
                            ProviderRow(provider: provider)
                        }
                        .buttonStyle(.plain)

                        if index < state.providers.count - 1 {
                            ImrseDivider().padding(.leading, 38)
                        }
                    }
                }
                .background(ImrseControlBackground())

                Button {
                    sheet = .add
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .medium))
                        Text("Add Provider")
                        Spacer()
                    }
                    .font(.imrseBody)
                    .padding(.horizontal, 13)
                    .frame(height: 38)
                    .background(ImrseControlBackground())
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(item: $sheet) { item in
            ProviderEditorSheet(
                mode: item,
                actions: actions,
                onSave: { provider in
                    switch item {
                    case .add:
                        state.addProvider(provider)
                    case .edit:
                        state.updateProvider(provider)
                    }
                    sheet = nil
                },
                onDelete: { id in
                    state.deleteProvider(id: id)
                    sheet = nil
                },
                onCancel: { sheet = nil }
            )
        }
    }
}

private struct ProviderRow: View {
    let provider: ProviderConfiguration

    var body: some View {
        HStack(spacing: 12) {
            ImrseProviderGlyph(type: provider.type)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(provider.name)
                    .font(.imrseBodyStrong)
                Text(provider.defaultModel.isEmpty ? provider.baseURL : provider.defaultModel)
                    .font(.imrseCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 13)
        .frame(height: 54)
        .contentShape(Rectangle())
    }
}

enum ProviderSheet: Identifiable {
    case add
    case edit(ProviderConfiguration)

    var id: String {
        switch self {
        case .add: "add"
        case .edit(let provider): "edit-\(provider.id.uuidString)"
        }
    }
}
#endif
