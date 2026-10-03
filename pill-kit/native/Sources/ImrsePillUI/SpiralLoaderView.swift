import AppKit
import SwiftUI
import Lottie
import ImrsePillCore
import os

/// Native renderer of the SAME bundled animation assets; never an SF Symbol substitute.
public struct SpiralLoaderView: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public init() {}
    public func makeNSView(context: Context) -> SpiralNSView {
        let view = SpiralNSView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        view.configure(isDark: colorScheme == .dark, reducedMotion: reduceMotion)
        return view
    }
    public func updateNSView(_ view: SpiralNSView, context: Context) {
        // Label updates do not reset either animation or its repeat counter.
        view.configure(isDark: colorScheme == .dark, reducedMotion: reduceMotion)
    }
    public static func dismantleNSView(_ view: SpiralNSView, coordinator: ()) { view.stop() }
}

@MainActor
public final class SpiralNSView: NSView {
    private let fast: LottieAnimationView
    private let slow: LottieAnimationView
    private var cycle = SpiralCycle()
    private var running = false
    private var dark: Bool?
    private var reduced = false
    private var generation = 0
    private let resourcesAvailable: Bool

    public override init(frame: NSRect) {
        let assetBundle: Bundle? = Bundle.main.bundleURL.pathExtension.lowercased() == "app"
            ? Bundle.main.url(forResource: "ImrsePillKit_ImrsePillUI", withExtension: "bundle").flatMap { Bundle(url: $0) }
            : .module
        let fastAsset = assetBundle.flatMap { LottieAnimation.named("spiral-fast", bundle: $0) }
        let slowAsset = assetBundle.flatMap { LottieAnimation.named("spiral-slow", bundle: $0) }
        resourcesAvailable = fastAsset != nil && slowAsset != nil
        // Trim paths are rendered by Lottie's main-thread engine for predictable fidelity.
        fast = LottieAnimationView(animation: fastAsset, configuration: LottieConfiguration(renderingEngine: .mainThread))
        slow = LottieAnimationView(animation: slowAsset, configuration: LottieConfiguration(renderingEngine: .mainThread))
        super.init(frame: frame)
        setAccessibilityElement(false)
        for view in [fast, slow] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.backgroundBehavior = .pauseAndRestore
            addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor), view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.topAnchor.constraint(equalTo: topAnchor), view.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }
        slow.alphaValue = 0
        if !resourcesAvailable {
            Logger(subsystem: "imrse.pill", category: "assets").error("Bundled spiral animation resources could not be loaded")
        }
    }
    required init?(coder: NSCoder) { return nil }

    public func configure(isDark: Bool, reducedMotion: Bool) {
        if dark != isDark {
            dark = isDark
            let channel: Double = isDark ? 1 : 0
            let provider = ColorValueProvider(LottieColor(r: channel, g: channel, b: channel, a: 1))
            let keypath = AnimationKeypath(keypath: "**.Stroke 1.Color")
            fast.setValueProvider(provider, keypath: keypath)
            slow.setValueProvider(provider, keypath: keypath)
            // The upstream layer opacity is intentionally left at 24%, not silently boosted.
        }
        if reduced != reducedMotion {
            reduced = reducedMotion
            stop()
        }
        guard resourcesAvailable else { return }
        if reducedMotion {
            fast.currentFrame = 14
            fast.alphaValue = 1; slow.alphaValue = 0
        } else if !running, window != nil {
            running = true; cycle = SpiralCycle(); generation += 1
            playNext(generation: generation)
        }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stop() }
        else { configure(isDark: dark ?? false, reducedMotion: reduced) }
    }

    private func playNext(generation expected: Int) {
        guard running, !reduced, generation == expected else { return }
        let isFast = cycle.phase == .fast
        let active = isFast ? fast : slow
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.075
            fast.animator().alphaValue = isFast ? 1 : 0
            slow.animator().alphaValue = isFast ? 0 : 1
        }
        active.play(fromProgress: 0, toProgress: 1, loopMode: .playOnce) { [weak self] completed in
            Task { @MainActor [weak self] in
                guard let self, completed, self.running, self.generation == expected else { return }
                self.cycle.complete()
                self.playNext(generation: expected)
            }
        }
    }

    public func stop() {
        running = false
        generation += 1 // Invalidates completion closures already enqueued on the main actor.
        fast.stop(); slow.stop()
    }
}
