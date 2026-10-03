#if os(macOS) && DEBUG
import SwiftUI

enum AppPreviewState: String, Equatable {
    case hidden
    case ready
    case generating
    case replacing
    case success
    case error
    case settings

    static func from(arguments: [String]) -> AppPreviewState? {
        argumentValue("--preview-state", in: arguments).flatMap(AppPreviewState.init(rawValue:))
    }

    static func settingsTab(
        from arguments: [String],
        previewState: AppPreviewState?,
        isPreviewMode: Bool
    ) -> SettingsTab {
        guard isPreviewMode, previewState == .settings else { return .general }
        return argumentValue("--preview-settings-pane", in: arguments)
            .flatMap(SettingsTab.init(rawValue:)) ?? .general
    }

    static func modelProviderSection(
        from arguments: [String],
        previewState: AppPreviewState?,
        isPreviewMode: Bool
    ) -> ModelProviderSection? {
        guard isPreviewMode, previewState == .settings,
              settingsTab(from: arguments, previewState: previewState, isPreviewMode: isPreviewMode) == .models
        else { return nil }
        return argumentValue("--preview-model-provider", in: arguments)
            .flatMap(ModelProviderSection.init(rawValue:))
    }

    static func colorScheme(
        from arguments: [String],
        previewState: AppPreviewState?,
        isPreviewMode: Bool
    ) -> ColorScheme? {
        guard isPreviewMode, previewState == .settings else { return nil }
        switch argumentValue("--preview-appearance", in: arguments) {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    private static func argumentValue(_ key: String, in arguments: [String]) -> String? {
        for (index, argument) in arguments.enumerated() {
            if argument == key {
                guard arguments.indices.contains(index + 1) else { return nil }
                return arguments[index + 1]
            }
            if argument.hasPrefix("\(key)=") {
                return String(argument.dropFirst(key.count + 1))
            }
        }
        return nil
    }
}
#endif
