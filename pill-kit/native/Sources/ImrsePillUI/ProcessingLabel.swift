import SwiftUI
import ImrsePillCore

struct ProcessingLabel: View {
    let startedAt: Date
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Group {
            if reduceMotion { Text("Thinking…") }
            else {
                // Only this text subtree updates. The adjacent native loader keeps its identity.
                TimelineView(.periodic(from: startedAt, by: 0.25)) { context in
                    let elapsed = max(0, context.date.timeIntervalSince(startedAt))
                    let word = ActivityWords.word(at: elapsed)
                    HStack(spacing: 0) {
                        Text(word).id(word).transition(.opacity)
                        HStack(spacing: 0) {
                            ForEach(0..<3) { index in
                                Text(".").frame(width: 3)
                                    .opacity(Int(elapsed * 3) % 3 == index ? 1 : 0.35)
                            }
                        }.frame(width: 12, alignment: .leading)
                    }
                    .animation(.easeOut(duration: 0.15), value: word)
                }
            }
        }
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Working on your text")
    }
}
