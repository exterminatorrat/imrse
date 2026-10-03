#if canImport(SwiftUI)
import SwiftUI

struct ShortcutsSettingsScreen: View {
    let state: ImrseSettingsState
    let actions: ImrseSettingsActions

    var body: some View {
        SettingsPage(title: "Shortcuts") {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Global Invocation")
                        .font(.imrseBodyStrong)

                    HStack(spacing: 12) {
                        ImrseControlShell(width: 260) {
                            Text(state.general.invocation.displayName)
                        }
                        ImrseSecondaryButton(title: "Change…") {
                            actions.onChangeGlobalShortcut()
                        }
                        Spacer()
                    }
                }

                ImrseDivider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Preset Shortcuts")
                        .font(.imrseBodyStrong)

                    VStack(spacing: 0) {
                        ForEach(Array(state.presets.enumerated()), id: \.element.id) { index, preset in
                            HStack(spacing: 12) {
                                Image(systemName: shortcutSymbol(index))
                                    .font(.system(size: 11.5, weight: .medium))
                                    .frame(width: 20)
                                Text(preset.name)
                                    .font(.imrseBody)
                                Spacer()
                                Button {
                                    actions.onChangePresetShortcut(preset.id)
                                } label: {
                                    ImrseShortcutBadge(value: preset.shortcut.isEmpty ? "None" : preset.shortcut)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 13)
                            .frame(height: 46)

                            if index < state.presets.count - 1 {
                                ImrseDivider().padding(.leading, 38)
                            }
                        }
                    }
                    .background(ImrseControlBackground())
                }
            }
        }
    }

    private func shortcutSymbol(_ index: Int) -> String {
        switch index % 5 {
        case 0: "arrow.left.and.right"
        case 1: "line.3.horizontal.decrease"
        case 2: "text.alignleft"
        case 3: "textformat"
        default: "pencil"
        }
    }
}
#endif
