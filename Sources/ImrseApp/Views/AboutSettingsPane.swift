#if os(macOS)
import Foundation
import SwiftUI

struct AboutSettingsPane: View {
    @ObservedObject var model: AppModel

    private let links: [(title: String, symbol: String, url: URL)] = [
        ("GitHub", "chevron.left.forwardslash.chevron.right", URL(string: "https://github.com/exterminatorrat/imrse")!),
        ("Documentation", "book", URL(string: "https://github.com/exterminatorrat/imrse#readme")!),
        ("Report an Issue", "exclamationmark.bubble", URL(string: "https://github.com/exterminatorrat/imrse/issues")!)
    ]

    var body: some View {
        SettingsPage(
            title: "About",
            subtitle: "Version and project links for imrse.",
            symbol: "info.circle"
        ) {
            VStack(alignment: .leading, spacing: ImrseSettingsMetrics.sectionSpacing) {
                VStack(spacing: 5) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(.black)
                        ImrseMark(size: 34, color: .white)
                    }
                    .frame(width: 56, height: 56)

                    Text("imrse")
                        .font(.system(size: 20, weight: .regular, design: .default))
                        .tracking(-0.4)

                    Text("Version \(version)")
                        .font(.imrseCaption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)

                SettingsSection(title: "Project links", symbol: "link", detail: "Source, documentation and support.") {
                    VStack(spacing: 0) {
                        ForEach(Array(links.enumerated()), id: \.offset) { index, item in
                            Link(destination: item.url) {
                                HStack(spacing: 10) {
                                    Image(systemName: item.symbol)
                                        .font(.system(size: 14, weight: .regular))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 19)

                                    Text(item.title)
                                        .font(.imrseBody)

                                    Spacer()

                                    Image(systemName: "arrow.up.right")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(.tertiary)
                                }
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(model.isPreviewMode)

                            if index < links.count - 1 {
                                ImrseDivider()
                                    .padding(.leading, 29)
                            }
                        }
                    }
                }

                Text("© 2026 imrse. Open source.")
                    .font(.imrseCaption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? Bundle.main.infoDictionary?["CFBundleVersion"] as? String
            ?? "Unknown"
    }
}
#endif
