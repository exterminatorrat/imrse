# imrse engineering priorities

## Finish reliable original-field editing before new features

The current delivery goal is usable cross-app text editing, not only an Undo repair. Follow [the completion order](docs/text-editing-completion-order.md) for ELV-16, ELV-1 and ELV-17. The detailed architecture and historical source evidence remain in [the implementation plan](docs/text-editing-implementation-plan.md). Read the linked issue before changing its scope or status.

- Preserve the approved interaction: select text, supply an instruction or preset, generate, then direct Apply in the original field. Do not introduce Preview/Replace/Discard or revive deferred UI work.
- Continue authorized source implementation and narrow pure tests while native testing is unavailable. Do not wait for another routine “continue” or turn packaging, broad builds or tooling into the foreground task.
- Diagnose a failed premise before another attempt. Fix demonstrated causes and add the nearest regression; a mock possibility is not a live diagnosis. Do not broaden a host/editor capability without the required identity, content and inverse evidence.
- Keep implemented, statically checked, unit-tested, installed and live-accepted distinct. Passing CI, successful AX setters and safely refused common editing workflows do not complete the delivery goal.
- Update the same focused PR and the owning issues with concrete results and remaining gates. Do not mark the parent complete until the declared supported workflows work on the exact delivered artifact.

## Native execution and permissions

Shared-device native execution requires a fresh, finite handoff from its current coordinator. A queued case, another owner's completed slot or an expired clock is not a grant. Keep source-only work separate; never overlap another owner's compiler, app, model, resource-sampling or cleanup window.

Use one persistent permission-bearing identity: `org.imrse.app`, an explicitly authorized installation path and the verified existing signer. Do not rotate probe identities, request helper permissions, reset grants or change signing/Keychain state by implication. Accessibility, Input Monitoring and actual editing capability are separate facts.

Live acceptance is synthetic-only within its explicit scope. Preserve the protected original, exact rollback and configuration bytes. Do not inspect personal clipboard data or private fields. WeChat remains paused; browser/editor bridges, extensions, copy capture and new access remain separately consent-gated.

An uncertain capture, generation, Apply or Undo is one-shot: preserve the evidence and stop that case. Never replay it to repair missing observation. Independently prove whole-slot closure and restoration before releasing ownership. This file grants no installation, native execution, merge, release or destructive authority.
