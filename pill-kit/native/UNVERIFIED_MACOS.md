# Native checks still required

Linux executed the portable Core tests only. Every item below is unverified:

1. SwiftUI/AppKit/Lottie target compilation with the target Xcode/SDK and resolved
   Lottie version. Run `swift build` inside native/ on macOS.
2. The panel accepts typing without invalidating the previously captured AX target.
   Capture in TextEdit, invoke, type a custom instruction, return to the source.
3. Correct key-window behavior for a nonactivating NSPanel across Spaces/fullscreen.
   Repeat on two displays and an auto-hiding Dock. Verify no frame clips the shadow.
4. Exact Lottie path rendering, stroke tint (black/white), original 24% opacity,
   24-point scaling, 75ms phase transition and four-fast/two-slow rhythm.
5. Dismissal actually stops both animations; watch CPU and reopen 20 times.
6. Reduced Motion and dynamic light/dark changes. Ensure no unintentional restarts
   from the status TimelineView and no continuing hidden animation.
7. Cmd-1 only selects configured presets while input owns focus. Unmapped keys
   must be forwarded. Test Command-C/V/A, Escape, and native IME composition.
8. Repeated invocation preserves draft text. Rapid Enter does not dispatch twice.
9. Real provider cancellation, revalidation, atomic replacement, failure recovery
   and Undo. These operations are supplied by the HOST, not implemented by this kit.
10. VoiceOver and increased contrast. Consider setting successDismissDelay=nil for
    persistent accessible confirmation. Check keyboard focus-visible affordances.

The React harness is not evidence for any item above. A macOS compile alone is
also not evidence of cross-app text replacement compatibility.
