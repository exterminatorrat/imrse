import AppKit
import SwiftUI
import ImrsePillCore

public struct ImrsePillView: View {
    @ObservedObject private var model: PillModel
    private let width: CGFloat
    private let hostHandlesEscape: Bool
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var inputFocused: Bool
    @State private var showingFailureDetails = false
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
    private var backgroundColor: Color { isDark ? Color(white: 0.094) : .white }
    private var outlineColor: Color { isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.045) }
    private var failureHeading: String {
        switch model.failureKind {
        case .some(.generation): return "Generation failed"
        case .some(.targetLost): return "Selection unavailable"
        case .some(.replacement): return "Replacement failed"
        case .some(.clipboardPending): return "Clipboard status uncertain"
        case .some(.cancelled): return "Request cancelled"
        case nil: return "Request failed"
        }
    }
    private var failureGuidance: String? {
        switch model.failureKind {
        case .some(.targetLost): return "Reselect the intended text before starting a new request."
        case .some(.clipboardPending): return "Check the original text before continuing."
        case .some(.generation), .some(.replacement), .some(.cancelled), nil: return nil
        }
    }

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
                            RoundedRectangle(cornerRadius: PillTokens.radius).fill(backgroundColor)
                        } else {
                            Capsule().fill(backgroundColor)
                        }
                    }
                    .overlay {
                        if isProposal {
                            RoundedRectangle(cornerRadius: PillTokens.radius).strokeBorder(outlineColor, lineWidth: 1)
                        } else {
                            Capsule().strokeBorder(outlineColor, lineWidth: 1)
                        }
                    }
                    .shadow(color: .black.opacity(isDark ? 0.22 : 0.12), radius: 11, x: 0, y: 6)
                    .onExitCommand {
                        if showingFailureDetails { showingFailureDetails = false }
                        else if !hostHandlesEscape {
                            if isProposal { model.discardProposal() }
                            else { model.dismiss() }
                        }
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
                        showingFailureDetails = false
                    }
                    .onChange(of: inputFocused) { model.setInputFocused($0) }
                    .accessibilityIdentifier("imrse.pill")
            }
        }
    }

    @ViewBuilder private var contents: some View {
        switch model.phase {
        case .hidden:
            EmptyView()
        case .input:
            TextField("Describe edits", text: $model.instruction)
                .textFieldStyle(.plain).focused($inputFocused)
                .frame(minHeight: 28)
                .onHover { hovering in
                    (hovering ? NSCursor.iBeam : NSCursor.arrow).set()
                }
                .onSubmit { model.submit() }
                .accessibilityLabel("Describe edits")
                .accessibilityHint("Enter an instruction, or leave blank to use default.md.")
            Menu {
                ForEach(model.presets) { preset in
                    presetMenuItem(preset)
                }
            } label: {
                Text("More")
                    .foregroundStyle(secondary)
                    .frame(minWidth: 28, minHeight: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .disabled(model.presets.isEmpty)
            .help(
                model.presets.isEmpty
                    ? "No presets are configured."
                    : "Choose a preset to fill the instruction, then submit it yourself."
            )
            .accessibilityLabel("More")
            .accessibilityHint(
                model.presets.isEmpty
                    ? "No presets are configured."
                    : "Shows configured presets. Choosing one fills the instruction; submit it yourself."
            )
            Button(action: model.submit) {
                HStack(spacing: 4) {
                    Text("Improve")
                    Text("↵")
                        .accessibilityHidden(true)
                }
                .font(.system(size: PillTokens.fontSize, weight: .semibold))
                .foregroundStyle(isDark ? Color(white: 0.094) : .white)
                .padding(.horizontal, 9)
                .frame(minHeight: 28)
                .background(foreground, in: Capsule())
            }
            .buttonStyle(.plain)
            .help("Submit the instruction, or use default.md when blank.")
            .accessibilityLabel("Improve")
            .accessibilityHint("Submits the instruction. A blank field uses default.md.")
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
            if model.canUndo {
                action("Undo", accessibility: "Undo last transformation", model.undo)
                    .help("Undo the last transformation.")
            }
            else { action("Close", accessibility: "Dismiss confirmation", model.dismiss) }
        case .failure(_, let message):
            Text(failureHeading)
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help("\(failureHeading). \(message)")
                .accessibilityLabel("\(failureHeading). \(message)")
            Button("Details") { showingFailureDetails = true }
                .buttonStyle(.plain)
                .frame(minWidth: 28, minHeight: 28)
                .help("Read the full failure message.")
                .accessibilityHint("Opens the full failure message.")
                .popover(isPresented: $showingFailureDetails) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(failureHeading).font(.headline)
                        if let failureGuidance {
                            Text(failureGuidance).foregroundStyle(secondary)
                        }
                        Text(message).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding()
                    .frame(maxWidth: 320, alignment: .leading)
                }
            action("Dismiss", accessibility: model.failureKind == .cancelled ? "Dismiss cancellation" : "Dismiss error", model.dismiss)
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

    @ViewBuilder
    private func presetMenuItem(_ preset: PillPreset) -> some View {
        Button(preset.name) {
            guard let index = model.presets.firstIndex(where: { $0.id == preset.id }) else { return }
            model.applyPreset(at: index)
            inputFocused = true
            model.setInputFocused(true)
        }
            .help("Fill the instruction with \(preset.name), then submit it yourself.")
            .accessibilityHint("Fills the instruction without submitting it.")
    }

    private func action(_ title: String, accessibility: String, _ callback: @escaping () -> Void) -> some View {
        Button(title, action: callback)
            .buttonStyle(.plain)
            .font(.system(size: PillTokens.actionFontSize))
            .foregroundStyle(secondary)
            .frame(minWidth: 28, minHeight: 28)
            .accessibilityLabel(accessibility)
    }
}
