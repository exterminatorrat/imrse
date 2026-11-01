# EventSource 1.5.1 compatibility candidate

Upstream: https://github.com/mattt/EventSource.git
Revision: `86b5096ac59ab46e66bd1f6377c604bc1dab0bc2` (1.5.1).
License: original MIT text retained in `LICENSE.md`.

Both package manifests, all four library Swift files and all seven upstream test/helper files were copied from that exact clean revision. No upstream test change is included. imrse's macOS arm64 manifest declares this local package to override its transitive remote dependency; offline graph qualification remains pending. The original remote pin is retained until a supported resolver demonstrates whether it must change.

The sole library change replaces the private generic `processIncomingBytes<S: AsyncSequence>` signature with a private `IncomingByteStream` alias: `URLSession.AsyncBytes` on Apple platforms, `AsyncThrowingStream<UInt8, Error>` when FoundationNetworking is available. Those are the existing call-site types. The actor, loop body, cancellation and closed-state checks, parser/callback delivery, reconnection and public API remain unchanged. No unsafe annotation, warning bypass or platform-minimum change.

The installed Swift 6.4 compiler rejects the original unconstrained generic actor loop below macOS 15. A smaller `SendableMetatype` constraint was checked separately and failed with the same diagnostic; it is not included here. All four actual library files plus concrete Apple/stream loop fixtures passed a Swift 6 warnings-as-errors typecheck targeting macOS 12. That execution had an unsound shared-helper entry predicate and a late evidence closure; its exit 0 is genuine but is not a fully qualified execution or runtime result. Runtime regressions, Linux/trait compilation and integrated graph/product validation remain pending.

`ConcreteTransportTests.swift` adds focused coverage in the existing test target; the seven upstream test/helper files remain unchanged. These added tests have not yet run.

Original `Sources/EventSource/EventSource.swift` SHA256:
`0d334bd1dca4117fa2eaf21d08ff8df335ec48dca7ca9408d95a163cf5d99fbd`.
Candidate SHA256:
`1dd2aede9106e616b1ee93919702db5d19ef507784b8bf0310c83f5a04fc267d`.
