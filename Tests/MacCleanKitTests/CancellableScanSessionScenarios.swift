import Foundation
#if !SCAN_SESSION_STANDALONE
@testable import MacCleanKit
#endif

/// Shared real-model scenarios for XCTest and the CLT-only assertion runner.
/// The gate deliberately ignores cancellation, like a blocked system scanner.
private actor ScanGate<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Never>?
    private var didStart = false

    func run() async -> Value {
        await withCheckedContinuation {
            continuation = $0
            didStart = true
        }
    }

    func started() -> Bool { didStart }

    func release(_ value: Value) {
        precondition(continuation != nil, "Wait for the scanner to enter the gate first")
        continuation?.resume(returning: value)
        continuation = nil
    }
}

struct ScanSessionAssertion: Error, CustomStringConvertible {
    let description: String
}

@MainActor
enum CancellableScanSessionScenarios {
    private static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw ScanSessionAssertion(description: message) }
    }

    private static func waitUntilStarted<Value>(_ gate: ScanGate<Value>) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await gate.started()) {
            guard ContinuousClock.now < deadline else {
                throw ScanSessionAssertion(description: "Worker did not start within two seconds")
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private static func worker<Value>(_ session: CancellableScanSession<Value>) throws -> Task<Void, Never> {
        guard let task = session.task else {
            throw ScanSessionAssertion(description: "An accepted scan must retain its worker")
        }
        return task
    }

    static func normalCompletionExactlyOnce() async throws {
        let session = CancellableScanSession<Int>()
        let gate = ScanGate<Int>()
        var published: [Int] = []
        try require(!session.isRunning, "New session must be idle")
        try require(session.start(operation: { await gate.run() }, onCompletion: { published.append($0) }),
                    "Idle session must accept a scan")
        let task = try worker(session)
        try require(session.isRunning, "Starting must synchronously show scanning")
        try await waitUntilStarted(gate)
        await gate.release(42)
        await task.value
        try require(published == [42], "Successful scan must publish exactly once")
        try require(!session.isRunning && session.task == nil, "Finished scan must release its task and return idle")
    }

    static func blockedScanCanCancelWithoutPublishingEmpty() async throws {
        let session = CancellableScanSession<[Int]>()
        let gate = ScanGate<[Int]>()
        var publications = 0
        session.start(operation: { await gate.run() }, onCompletion: { _ in publications += 1 })
        let task = try worker(session)
        try await waitUntilStarted(gate)
        session.cancel()
        try require(!session.isRunning && session.task == nil, "Cancel must restore idle without waiting for blocked work")
        try require(task.isCancelled, "Cancel must propagate to the retained worker")
        await gate.release([]) // The malware backend may return .empty when cancelled.
        await task.value
        try require(publications == 0, "Cancelled empty result must never publish a clean/protection status")
    }

    static func lateCancelledRunCannotOverwriteRescan() async throws {
        let session = CancellableScanSession<Int>()
        let oldGate = ScanGate<Int>()
        let newGate = ScanGate<Int>()
        var published: [Int] = []
        session.start(operation: { await oldGate.run() }, onCompletion: { published.append($0) })
        let oldTask = try worker(session)
        try await waitUntilStarted(oldGate)
        session.cancel()
        try require(session.start(operation: { await newGate.run() }, onCompletion: { published.append($0) }),
                    "Cancel must permit immediate rescan")
        let newTask = try worker(session)
        try await waitUntilStarted(newGate)
        await newGate.release(2)
        await newTask.value
        await oldGate.release(1)
        await oldTask.value
        try require(published == [2], "Late cancelled result must not overwrite a completed rescan")
        try require(!session.isRunning, "Late completion must not revive scanning")
    }

    static func lateCancelledRunCannotEndActiveRescan() async throws {
        let session = CancellableScanSession<Int>()
        let oldGate = ScanGate<Int>()
        let newGate = ScanGate<Int>()
        var published: [Int] = []
        session.start(operation: { await oldGate.run() }, onCompletion: { published.append($0) })
        let oldTask = try worker(session)
        try await waitUntilStarted(oldGate)
        session.cancel()
        session.start(operation: { await newGate.run() }, onCompletion: { published.append($0) })
        let newTask = try worker(session)
        try await waitUntilStarted(newGate)
        await oldGate.release(1)
        await oldTask.value
        let stillRunning = session.isRunning
        let noStaleResult = published.isEmpty
        await newGate.release(2)
        await newTask.value
        try require(stillRunning && noStaleResult, "Old completion must leave the replacement scan running and unpublished")
        try require(published == [2], "Only the active generation may publish")
    }

    static func overlappingStartIsRejected() async throws {
        let session = CancellableScanSession<Int>()
        let gate = ScanGate<Int>()
        var published: [Int] = []
        session.start(operation: { await gate.run() }, onCompletion: { published.append($0) })
        let task = try worker(session)
        try await waitUntilStarted(gate)
        let accepted = session.start(operation: { 99 }, onCompletion: { published.append($0) })
        await gate.release(1)
        await task.value
        try require(!accepted, "A second start must be rejected while a scan is active")
        try require(published == [1], "Rejected run must not replace the active completion")
    }

    static func synchronousWorkerDoesNotBlockMainActor() async throws {
        let session = CancellableScanSession<Bool>()
        let gate = SynchronousScanGate()
        var publications = 0
        // A synchronous SDK call can block even before its first await.
        // A timed wait keeps a regression from deadlocking the test suite.
        session.start(operation: { gate.run() }, onCompletion: { _ in publications += 1 })
        let task = try worker(session)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !gate.hasStarted {
            guard ContinuousClock.now < deadline else {
                throw ScanSessionAssertion(description: "Synchronous worker never entered its gate")
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        // This is a main-actor heartbeat while the actual worker is synchronously blocked.
        let remainedBlocked = !gate.hasFinished
        session.cancel()
        let recoveredImmediately = !session.isRunning
        gate.release()
        await task.value
        try require(!gate.ranOnMainThread, "Synchronous scan setup must execute off the UI thread")
        try require(remainedBlocked && recoveredImmediately, "UI actor must be able to cancel while synchronous work is blocked")
        try require(publications == 0, "A cancelled synchronous worker must never publish")
    }
}

/// All shared flags are guarded by the lock; the worker alone blocks on the semaphore.
private final class SynchronousScanGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var started = false
    private var finished = false
    private var onMain = false

    var hasStarted: Bool { lock.withLock { started } }
    var hasFinished: Bool { lock.withLock { finished } }
    var ranOnMainThread: Bool { lock.withLock { onMain } }

    func run() -> Bool {
        lock.withLock {
            started = true
            onMain = Thread.isMainThread
        }
        _ = semaphore.wait(timeout: .now() + 1)
        lock.withLock { finished = true }
        return true
    }

    func release() { semaphore.signal() }
}
