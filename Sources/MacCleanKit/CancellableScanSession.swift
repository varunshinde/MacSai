import Foundation
import Observation

/// Owns one scan lifecycle on the UI actor while executing injected work off it.
/// Cancellation releases the UI immediately; a non-cooperative worker can keep
/// running, but only the current, uncancelled run may invoke `onCompletion`.
/// Keep all result/status publication inside that main-actor callback.
@MainActor
@Observable
public final class CancellableScanSession<Value: Sendable> {
    public private(set) var isRunning = false
    @ObservationIgnored private(set) var task: Task<Void, Never>?
    @ObservationIgnored private var runID: UUID?

    public init() {}

    @discardableResult
    public func start(
        operation: @escaping @Sendable () async -> Value,
        onCompletion: @escaping @MainActor @Sendable (Value) -> Void
    ) -> Bool {
        guard !isRunning else { return false }
        let id = UUID()
        runID = id
        isRunning = true
        task = Task.detached(priority: .userInitiated) { [weak self] in
            guard !Task.isCancelled else { return }
            let result = await operation()
            await self?.finish(result, runID: id, onCompletion: onCompletion)
        }
        return true
    }

    public func cancel() {
        // Invalidate before cancelling: a non-cooperative worker may still return.
        runID = nil
        task?.cancel()
        task = nil
        isRunning = false
    }

    private func finish(_ result: Value, runID id: UUID, onCompletion: @MainActor (Value) -> Void) {
        guard runID == id, !Task.isCancelled else { return }
        runID = nil
        task = nil
        isRunning = false
        onCompletion(result)
    }
}
