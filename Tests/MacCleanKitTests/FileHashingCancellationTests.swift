import XCTest
import Foundation
@testable import MacCleanKit
import MacCleanTestSupport

final class FileHashingCancellationTests: XCTestCase {
    func testCancelledTaskDoesNotHashAFile() async throws {
        try await TestFixtures.withTempDir { root in
            let file = try TestFixtures.writeFile(
                at: root.appending(path: "harmless-fixture"),
                contents: Data("harmless cancellation regression fixture".utf8))
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return FileHashing.digests(of: file, algorithms: [.sha1, .sha256])
            }
            let digests = await task.value
            XCTAssertTrue(digests.isEmpty, "Cancellation must stop work before opening a file")
        }
    }

    func testUncancelledTaskStillComputesBothDigests() async throws {
        try await TestFixtures.withTempDir { root in
            let file = try TestFixtures.writeFile(
                at: root.appending(path: "empty-fixture"), contents: Data())
            let task = Task {
                FileHashing.digests(of: file, algorithms: [.sha1, .sha256])
            }
            let digests = await task.value
            XCTAssertEqual(digests[.sha1], "da39a3ee5e6b4b0d3255bfef95601890afd80709")
            XCTAssertEqual(digests[.sha256], "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        }
    }
}
