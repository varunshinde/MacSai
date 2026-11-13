// Compile this runner with the production session and shared test scenarios.
// No XCTest replacement or package modifications are involved.
import Foundation

@main
struct VerifyCancellableScanSession {
    @MainActor
    static func main() async throws {
        let scenarios: [(String, @MainActor () async throws -> Void)] = [
            ("normal completion exactly once", CancellableScanSessionScenarios.normalCompletionExactlyOnce),
            ("blocked cancel rejects empty result", CancellableScanSessionScenarios.blockedScanCanCancelWithoutPublishingEmpty),
            ("late result cannot overwrite rescan", CancellableScanSessionScenarios.lateCancelledRunCannotOverwriteRescan),
            ("late result cannot end active rescan", CancellableScanSessionScenarios.lateCancelledRunCannotEndActiveRescan),
            ("overlapping start rejected", CancellableScanSessionScenarios.overlappingStartIsRejected),
            ("synchronous worker off main actor", CancellableScanSessionScenarios.synchronousWorkerDoesNotBlockMainActor),
        ]
        for (name, scenario) in scenarios {
            guard CommandLine.arguments.count == 1 || CommandLine.arguments.dropFirst().contains(name) else { continue }
            do {
                try await scenario()
                print("PASS: \(name)")
            } catch {
                print("FAIL: \(name): \(error)")
                exit(1)
            }
        }
    }
}
