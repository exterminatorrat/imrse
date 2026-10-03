#if canImport(SwiftUI)
import SwiftUI

struct AboutSettingsScreen: View {
    let version: String
    let actions: ImrseSettingsActions

    private let links: [(String, String)] = [
        ("GitHub", "https://github.com/exterminatorrat/imrse"),
        ("Documentation", "https://github.com/exterminatorrat/imrse#readme"),
        ("Report an Issue", "https://github.com/exterminatorrat/imrse/issues")
    ]

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 52)

            VStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color.primary)
                    ImrseMark(size: 58, color: .white)
                        .padding(18)
                }
                .frame(width: 96, height: 96)

                Text("imrse")
                    .font(.system(size: 32, weight: .regular))
                    .tracking(-1.1)

                Text("v\(version)")
                    .font(.imrseBody)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 0) {
                ForEach(Array(links.enumerated()), id: \.offset) { index, item in
                    Button {
                        guard let url = URL(string: item.1) else { return }
                        actions.onOpenURL(url)
                    } label: {
                        HStack {
                            Text(item.0)
                                .font(.imrseBody)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if index < links.count - 1 {
                        ImrseDivider().padding(.leading, 14)
                    }
                }
            }
            .frame(maxWidth: 430)
            .background(ImrseControlBackground())
            .padding(.top, 36)

            Spacer()

            Text("© 2026 imrse. Open source.")
                .font(.imrseCaption)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 28)
        }
        .padding(.horizontal, ImrseSettingsMetrics.contentHorizontalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif
