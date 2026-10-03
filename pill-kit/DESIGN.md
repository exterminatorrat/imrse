# imrse pill — implementation contract

The visual target is `reference/imrse-corrected-reference.png`. Earlier generated
boards with bullseye loaders or sparkle icons are NOT implementation references.

## Geometry and appearance

The user's 2026-09-30 clarification narrows the pill horizontally while retaining
the original height 52, radius 26 and horizontal padding 20. Phase widths are
input 360, processing 240, applying 220, success 180 and error 300 logical
pixels/points. The archived reference/manifest remain provenance. Browser width
may shrink on a narrow viewport; the same native panel resizes by phase while
remaining centered on the captured screen's visible frame.
The loader's canvas is exactly 24 × 24; the gap to text is 10. Text is system sans,
13 regular. Actions are 11 regular. There are no bundled font files.

Light: white surface, near-black content, secondary text #737373.
Dark: #181818 surface, white content, secondary text #a1a1a1.
A subtle edge and shadow define the surface. No rainbow, glow, sparkle, bullet
logo, ornamental symbol, persistent bump, resting orb, or launcher capsule.
The return glyph is a functional submit button, not branding.

## Visibility

Construction is hidden. A valid invocation captures the source target FIRST and
then calls present. Cancel removes the surface. Confirmed replacement shows
`Updated` briefly, then hides completely. Error feedback stays until dismissed.
A second invocation while editing preserves the draft. A second invocation during
processing must not start another job.

## Processing

Use the upstream React `SpiralLoader` and exact original animation assets. Never
replace them with a circle, SF Symbol, CSS rotation or generated approximation.
The original 24% layer opacity is intentional and preserved. The native wrapper
changes only the stroke to black on light surfaces / white on dark surfaces.
The original phase rhythm is four fast loops, then two slow loops, indefinitely.
The phase transition crossfade is 75 ms.

The status word changes every 2.5 seconds. It is activity copy, NOT a report of
model reasoning stages. There is only one set of three animated dots. Changing a
word does not reset the loader, change the processing width, or move the trailing action.
The animated words are not repeatedly announced by assistive technology.
Reduced Motion uses a static frame of the original artwork and static text/dots.

## Input and presets

Blank input is passed as nil/null for the HOST to resolve default.md. Command-1
through Command-9 only fill existing presets while the pill has input focus. They
are not registered globally by this kit. Enter submits; Escape dismisses.
IME composition must not trigger submission. No decorative leading input icon.

## State ownership

Only the host may report `generated` and `applied`. `generated` means the provider
finished, NOT that any text was written. `applied` is accepted only after the
applying state. Stale request IDs are rejected. Undo belongs to the host, which
must revalidate its destination and keep Undo available outside a brief toast.

## Native fidelity

The CSS and SwiftUI geometry share the same explicit constants. This is not a
claim of pixel-identical macOS rendering: native fonts, antialiasing, focus,
Lottie rendering and panel behavior must be checked on a real Mac.
