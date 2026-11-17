# Observed Obsidian Live Preview surface

The tested Obsidian 1.13.7 Live Preview text area exposed `cm-content` and `cm-lineWrapping`, with a WebArea ancestor. Its AXSelectedText setter accepted the write but readback remained original. Additional visual highlighting was observed while AX still exposed only one range; this is not proof that a duplicate edit occurred. No multicursor mutation was attempted.

CodeMirror documents that the native selection may reflect only the main range while replacement operations can address every range: https://codemirror.net/examples/selection/ . Obsidian documents multiple cursors: https://obsidian.md/help/multiple-cursors . These corroborate model-scope uncertainty, not a live multi-write reproduction.

The guard refuses only exact bundle `md.obsidian` plus exact class token `cm-content`. It does not require wrapping, refuse every Obsidian field, classify this token globally, or enable clipboard support. Existing capture, final mutation and Undo validation remain unchanged; no retry or alternate transport is added. Unmarked/other-host CodeMirror editors are not certified safe by this limited negative filter. Ordinary fields retain their existing policy.
