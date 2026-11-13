import XCTest
@testable import MacCleanKit

final class CancellableScanSessionTests: XCTestCase {
    @MainActor
    func testNormalCompletionExactlyOnce() async throws {
        try await CancellableScanSessionScenarios.normalCompletionExactlyOnce()
    }

    @MainActor
    func testBlockedScanCanCancelWithoutPublishingEmpty() async throws {
        try await CancellableScanSessionScenarios.blockedScanCanCancelWithoutPublishingEmpty()
    }

    @MainActor
    func testLateCancelledRunCannotOverwriteRescan() async throws {
        try await CancellableScanSessionScenarios.lateCancelledRunCannotOverwriteRescan()
    }

    @MainActor
    func testLateCancelledRunCannotEndActiveRescan() async throws {
        try await CancellableScanSessionScenarios.lateCancelledRunCannotEndActiveRescan()
    }

    @MainActor
    func testOverlappingStartIsRejected() async throws {
        try await CancellableScanSessionScenarios.overlappingStartIsRejected()
    }

    @MainActor
    func testSynchronousWorkerDoesNotBlockMainActor() async throws {
        try await CancellableScanSessionScenarios.synchronousWorkerDoesNotBlockMainActor()
    }
}
