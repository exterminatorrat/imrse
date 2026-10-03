#if os(macOS)
import ImrseServices
import SwiftUI

struct CuratedModelChoicesCopy: Equatable {
    let sectionTitle: String
    let sectionDetail: String
    let emptyStateTitle: String
    let emptyStateDetail: String
    let accessibilityLabel: String
    let configuredModelDetail: String
}

enum CuratedModelChoicesPresentation: Equatable {
    case provider
    case chatGPTAccount

    func copy(isPreview: Bool, hasConfiguredModel: Bool) -> CuratedModelChoicesCopy {
        let configuredModelDetail = switch self {
        case .provider:
            "Currently configured for this provider"
        case .chatGPTAccount where isPreview:
            "Currently configured"
        case .chatGPTAccount:
            "Currently configured · not returned by the latest account model list"
        }
        return switch (self, isPreview, hasConfiguredModel) {
        case (.provider, _, _):
            CuratedModelChoicesCopy(
                sectionTitle: "Recommended models",
                sectionDetail: "Choose a model recommended for this provider.",
                emptyStateTitle: "No model recommendations",
                emptyStateDetail: "This provider has no recommended models.",
                accessibilityLabel: "Recommended models",
                configuredModelDetail: configuredModelDetail
            )
        case (.chatGPTAccount, true, _):
            CuratedModelChoicesCopy(
                sectionTitle: "Example models",
                sectionDetail: "Preview examples aren't checked against a connected account.",
                emptyStateTitle: "No example models",
                emptyStateDetail: "No example models are shown in preview.",
                accessibilityLabel: "Example models, preview only",
                configuredModelDetail: configuredModelDetail
            )
        case (.chatGPTAccount, false, true):
            CuratedModelChoicesCopy(
                sectionTitle: "Configured and account model IDs",
                sectionDetail: "The saved model is marked separately from IDs returned by the account.",
                emptyStateTitle: "No model IDs returned",
                emptyStateDetail: "Your saved model is shown above; the empty account list doesn't determine whether it works.",
                accessibilityLabel: "Configured and account model IDs",
                configuredModelDetail: configuredModelDetail
            )
        case (.chatGPTAccount, false, false):
            CuratedModelChoicesCopy(
                sectionTitle: "Account model IDs",
                sectionDetail: "Choose a model ID returned by your ChatGPT account.",
                emptyStateTitle: "No model IDs returned",
                emptyStateDetail: "The connected account returned no selectable model IDs.",
                accessibilityLabel: "Account model IDs",
                configuredModelDetail: configuredModelDetail
            )
        }
    }
}

struct CuratedModelChoicesView: View {
    let choices: [CuratedModelChoice]
    @Binding var selection: String
    var configuredModel: CuratedModelChoice? = nil
    var isPreview = false
    var presentation: CuratedModelChoicesPresentation = .provider

    private var displayedChoices: [CuratedModelChoice] {
        guard let configuredModel else { return choices }
        return [configuredModel] + choices
    }

    private var copy: CuratedModelChoicesCopy {
        presentation.copy(isPreview: isPreview, hasConfiguredModel: configuredModel != nil)
    }

    var body: some View {
        SettingsSection(
            title: copy.sectionTitle,
            symbol: "cpu",
            detail: copy.sectionDetail
        ) {
            if choices.isEmpty && configuredModel == nil {
                SettingsHint(
                    title: copy.emptyStateTitle,
                    detail: copy.emptyStateDetail,
                    symbol: "info.circle"
                )
            } else {
                Picker("Model", selection: $selection) {
                    ForEach(displayedChoices) { choice in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(choice.name)
                                .font(.imrseBody)
                            Text(choice.detail)
                                .font(.imrseCaption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(choice.id)
                    }
                }
                .pickerStyle(.radioGroup)
                .tint(.primary)
                .labelsHidden()
                .accessibilityLabel(copy.accessibilityLabel)
                if choices.isEmpty {
                    SettingsHint(
                        title: copy.emptyStateTitle,
                        detail: copy.emptyStateDetail,
                        symbol: "info.circle"
                    )
                }
            }
        }
    }
}

struct ModelProviderHeader: View {
    let title: String
    let detail: String
    let symbol: String?

    init(title: String, detail: String, symbol: String? = nil) {
        self.title = title
        self.detail = detail
        self.symbol = symbol
    }

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            if let symbol {
                SettingsIcon(symbol: symbol, size: 28)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.imrseBodyStrong)
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.imrseCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
