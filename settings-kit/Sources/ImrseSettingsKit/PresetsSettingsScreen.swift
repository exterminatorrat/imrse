#if canImport(SwiftUI)
import SwiftUI

struct PresetsSettingsScreen: View {
    let presets: [TransformPreset]
    let onSelect: (UUID) -> Void
    let onCreate: () -> Void

    var body: some View {
        SettingsPage(title: "Presets") {
            VStack(spacing: 14) {
                VStack(spacing: 0) {
                    ForEach(Array(presets.enumerated()), id: \.element.id) { index, preset in
                        Button {
                            onSelect(preset.id)
                        } label: {
                            PresetRow(preset: preset, index: index)
                        }
                        .buttonStyle(.plain)

                        if index < presets.count - 1 {
                            ImrseDivider().padding(.leading, 38)
                        }
                    }
                }
                .background(ImrseControlBackground())

                Button(action: onCreate) {
                    HStack(spacing: 10) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .medium))
                        Text("New Preset")
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
    }
}

private struct PresetRow: View {
    let preset: TransformPreset
    let index: Int

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: presetSymbol)
                .font(.system(size: 11.5, weight: .medium))
                .frame(width: 20)

            Text(preset.name)
                .font(.imrseBody)

            Spacer()

            if !preset.shortcut.isEmpty {
                ImrseShortcutBadge(value: preset.shortcut)
            }
        }
        .padding(.horizontal, 13)
        .frame(height: 48)
        .contentShape(Rectangle())
    }

    private var presetSymbol: String {
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
