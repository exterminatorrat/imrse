import AppKit
import SwiftUI
import ImrsePillCore

public struct ImrsePillView: View {
    @ObservedObject private var model: PillModel
    private let width: CGFloat
    private let hostHandlesEscape: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var inputFocused: Bool
    public init(model: PillModel, width: CGFloat = PillTokens.width, hostHandlesEscape: Bool = false) {
        self.model = model
        self.width = width
        self.hostHandlesEscape = hostHandlesEscape
    }
    private var isDark: Bool { colorScheme == .dark }
    private var isProposal: Bool {
        if case .proposal = model.phase { return true }
        return false
    }
    private var foreground: Color { isDark ? Color(white: 0.96) : Color(white: 0.09) }
    private var secondary: Color { isDark ? Color(white: 0.64) : Color(white: 0.45) }

    public var body: some View {
        Group {
            if model.phase.isVisible {
                HStack(spacing: 12) { contents }
                    .padding(.horizontal, PillTokens.horizontalPadding)
                    .frame(width: min(width, PillTokens.width(for: model.phase)), height: PillTokens.height(for: model.phase))
                    .font(.system(size: PillTokens.fontSize, weight: .regular))
                    .foregroundStyle(foreground)
                    .background {
                        if isProposal {
                            RoundedRectangle(cornerRadius: PillTokens.radius).fill(isDark ? Color(white: 0.094) : .white)
                        } else {
                            Capsule().fill(isDark ? Color(white: 0.094) : .white)
                        }
                    }
                    .overlay {
                        if isProposal {
                            RoundedRectangle(cornerRadius: PillTokens.radius).strokeBorder(isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.045), lineWidth: 1)
                        } else {
                            Capsule().strokeBorder(isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.045), lineWidth: 1)
                        }
                    }
                    .shadow(color: .black.opacity(isDark ? 0.22 : 0.12), radius: 11, x: 0, y: 6)
                    .onExitCommand {
                        if !hostHandlesEscape { model.dismiss() }
                    }
                    .onAppear {
                        DispatchQueue.main.async {
                            inputFocused = model.phase == .input
                            model.setInputFocused(inputFocused)
                        }
                    }
                    .onChange(of: model.phase) { phase in
                        inputFocused = phase == .input
                        model.setInputFocused(inputFocused)
                    }
                    .onChange(of: inputFocused) { model.setInputFocused($0) }
                    .accessibilityIdentifier("imrse.pill")
            }
        }
        .animation(reduceMotion || model.motion == .instant ? nil : .easeOut(duration: model.motion.duration), value: model.phase.isVisible)
    }

    @ViewBuilder private var contents: some View {
        switch model.phase {
        case .hidden:
            EmptyView()
        case .input:
            TextField("What should I change?", text: $model.instruction)
                .textFieldStyle(.plain).focused($inputFocused)
                .onHover { hovering in
                    (hovering ? NSCursor.iBeam : NSCursor.arrow).set()
                }
                .onSubmit { model.submit() }
                .accessibilityLabel("What should I change?")
            Button(action: model.submit) { Text("↵").font(.system(size: 19)).offset(y: 1) }
                .buttonStyle(.plain).help("Blank uses default.md")
                .accessibilityLabel("Apply transformation")
        case .proposal(let requestID):
            proposalPreview(for: requestID)
        case .processing(let requestID):
            HStack(spacing: PillTokens.loaderGap) {
                SpiralLoaderView().frame(width: PillTokens.loaderSize, height: PillTokens.loaderSize)
                    .accessibilityHidden(true)
                ProcessingLabel(startedAt: model.startedAt)
            }
            Spacer(minLength: 0)
            action("Stop", accessibility: "Stop generation") { model.stopGeneration(requestID) }
                .help("Stop generating a proposal.")
        case .applying:
            Text("Updating selection…").lineLimit(1)
            Spacer(minLength: 0)
        case .success:
            Text("Updated")
            Spacer(minLength: 0)
            if model.canUndo { action("Undo", accessibility: "Undo last transformation", model.undo) }
            else { action("Close", accessibility: "Dismiss confirmation", model.dismiss) }
        case .failure(_, let message):
            Text(model.failureKind == .cancelled ? "Request cancelled" : message)
                .lineLimit(1).truncationMode(.tail).help(message)
            Spacer(minLength: 0)
            action("esc", accessibility: model.failureKind == .cancelled ? "Dismiss cancellation" : "Dismiss error", model.dismiss)
        }
    }

    @ViewBuilder
    private func proposalPreview(for requestID: UUID) -> some View {
        if let proposal = model.proposal, proposal.requestID == requestID {
            VStack(spacing: 0) {
                ScrollView(.vertical) {
                    Text(model.previewText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(12)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button("Discard") { model.discardProposal() }
                        .buttonStyle(.plain)
                        .font(.system(size: PillTokens.actionFontSize))
                        .foregroundStyle(secondary)
                        .frame(minWidth: 28, minHeight: 28)
                        .help("Discard this proposal without replacing the selected text.")
                        .accessibilityHint("Discards the proposal without changing the selection.")
                    Button("Replace") { model.replaceProposal() }
                        .buttonStyle(.plain)
                        .font(.system(size: PillTokens.fontSize, weight: .semibold))
                        .foregroundStyle(isDark ? Color(white: 0.094) : .white)
                        .padding(.horizontal, 9)
                        .frame(minHeight: 28)
                        .background(foreground, in: Capsule())
                        .help("Replace the selected text with this proposal.")
                        .accessibilityHint("Applies the proposed replacement to the original selection.")
                }
                .frame(height: PillTokens.height)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text("Preparing preview…")
                .accessibilityLabel("Preparing preview")
        }
    }

    private func action(_ title: String, accessibility: String, _ callback: @escaping () -> Void) -> some View {
        Button(title, action: callback)
            .buttonStyle(.plain)
            .font(.system(size: PillTokens.actionFontSize))
            .foregroundStyle(secondary)
            .accessibilityLabel(accessibility)
    }
}
