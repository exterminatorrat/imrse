#if canImport(SwiftUI)
import SwiftUI

struct DiagnosticsSheet: View {
    let snapshot: DiagnosticsSnapshot
    let onCopy: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Diagnostics")
                    .font(.system(size: 18, weight: .semibold))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 18)

            VStack(spacing: 0) {
                DiagnosticsRow(label: "Accessibility", value: snapshot.accessibility.rawValue)
                DiagnosticsRow(label: "Global Shortcut", value: snapshot.globalShortcut.rawValue)
                DiagnosticsRow(label: "Frontmost App", value: snapshot.frontmostApp)
                DiagnosticsRow(
                    label: "Selection",
                    value: snapshot.selectionLength.map { "Available (\($0) chars)" } ?? "Unavailable"
                )
                DiagnosticsRow(label: "Provider", value: snapshot.provider)
                DiagnosticsRow(label: "State", value: snapshot.state)
                DiagnosticsRow(label: "Last Error", value: snapshot.lastError ?? "None", showDivider: false)
            }
            .background(ImrseControlBackground())

            HStack {
                Spacer()
                ImrseSecondaryButton(title: "Copy Diagnostic Report", action: onCopy)
                ImrsePrimaryButton(title: "Done", action: onClose)
            }
            .padding(.top, 20)
        }
        .padding(24)
        .frame(width: 500)
    }
}

private struct DiagnosticsRow: View {
    let label: String
    let value: String
    var showDivider = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 20) {
                Text(label)
                    .font(.imrseCaption)
                    .frame(width: 130, alignment: .leading)
                Text(value)
                    .font(.imrseCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 38)

            if showDivider {
                ImrseDivider().padding(.leading, 12)
            }
        }
    }
}
#endif
