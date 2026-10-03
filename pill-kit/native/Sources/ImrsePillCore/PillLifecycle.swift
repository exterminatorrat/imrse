import Foundation

public enum PillPhase: Equatable, Sendable {
    case hidden, input, processing(UUID), applying(UUID), success(UUID), failure(UUID, String)
    public var isVisible: Bool { self != .hidden }
    public var activeRequestID: UUID? {
        switch self {
        case .processing(let id), .applying(let id): return id
        default: return nil
        }
    }
}

public enum PillEvent: Sendable {
    case invoke, submit(UUID), generated(UUID), applied(UUID), failed(UUID, String), captureFailed(String), dismiss
}

/// Presentation state, not a text replacement engine. Only the host can confirm a write.
public struct PillLifecycle: Sendable {
    public private(set) var phase: PillPhase = .hidden
    public init() {}

    public mutating func send(_ event: PillEvent) {
        switch event {
        case .dismiss:
            phase = .hidden
        case .invoke:
            switch phase {
            case .hidden, .success, .failure: phase = .input
            default: break // Never open a second request over a running operation.
            }
        case .submit(let id):
            if phase == .input { phase = .processing(id) }
        case .generated(let id):
            if phase == .processing(id) { phase = .applying(id) }
        case .applied(let id):
            if phase == .applying(id) { phase = .success(id) }
        case .failed(let id, let message):
            if phase.activeRequestID == id { phase = .failure(id, message) }
        case .captureFailed(let message):
            if phase.activeRequestID == nil { phase = .failure(UUID(), message) }
        }
    }
}
