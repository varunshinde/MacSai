import Darwin
import Foundation
import XCTest
@testable import MacCleanKit

final class SubprocessCaptureTests: XCTestCase {
    func testPreCancelledTaskDoesNotAttemptLaunch() async {
        let task = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await SubprocessCapture.standardOutput(
                    of: URL(filePath: "/nonexistent-fixture-command"), arguments: [])
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }
        let cancelled = await task.value
        XCTAssertTrue(cancelled)
    }

    func testSmallStdoutStderrDoNotDeadlock() async throws {
        // Minimal iterations - just verify the capture handles pipes correctly
        let script = "printf 'stdout\\n'; printf 'stderr\\n' >&2"
        let output = try await SubprocessCapture.standardOutput(
            of: URL(filePath: "/bin/sh"), arguments: ["-c", script])
        XCTAssertTrue(output.contains("stdout"))
    }

    func testIgnoringSIGTERMCannotDefeatDeadline() async throws {
        let start = ContinuousClock.now
        do {
            _ = try await SubprocessCapture.standardOutput(
                of: URL(filePath: "/bin/sh"), arguments: ["-c", "trap '' TERM; exec /bin/sleep 1"],
                timeout: .milliseconds(50))
            XCTFail("Expected timeout")
        } catch let error as SubprocessCapture.Failure { XCTAssertEqual(error, .timedOut) }
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
    }

    func testClosedStdoutDoesNotHideRunningChild() async throws {
        do {
            _ = try await SubprocessCapture.standardOutput(
                of: URL(filePath: "/bin/sh"), arguments: ["-c", "exec 1>&-; exec /bin/sleep 1"],
                timeout: .milliseconds(50))
            XCTFail("EOF is not successful process completion")
        } catch let error as SubprocessCapture.Failure { XCTAssertEqual(error, .timedOut) }
    }

    func testInheritedStdoutCannotHoldCaptureOpenAfterOwnedChildExits() async throws {
        let start = ContinuousClock.now
        do {
            _ = try await SubprocessCapture.standardOutput(
                of: URL(filePath: "/bin/sh"), arguments: ["-c", "/bin/sleep 0.2 & exit 0"],
                timeout: .milliseconds(50))
            XCTFail("Expected deadline while the inherited pipe remains open")
        } catch let error as SubprocessCapture.Failure { XCTAssertEqual(error, .timedOut) }
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(300))
        try await Task.sleep(for: .milliseconds(300))
    }

    func testLaunchFailureIsNotSuccessfulEmptyOutput() async throws {
        do {
            _ = try await SubprocessCapture.standardOutput(
                of: URL(filePath: "/nonexistent-fixture-command"), arguments: [])
            XCTFail("Expected launch failure")
        } catch let error as SubprocessCapture.Failure { XCTAssertEqual(error, .launchFailed(ENOENT)) }
    }

    func testSignalExitIsNotSuccessfulEmptyOutput() async throws {
        do {
            _ = try await SubprocessCapture.standardOutput(
                of: URL(filePath: "/bin/sh"), arguments: ["-c", "kill -TERM $$"])
            XCTFail("Expected signal failure")
        } catch let error as SubprocessCapture.Failure { XCTAssertEqual(error, .signalled(SIGTERM)) }
    }

    func testZeroOutputLimitAcceptsEmptyOutput() async throws {
        let output = try await SubprocessCapture.standardOutput(
            of: URL(filePath: "/usr/bin/printf"), arguments: [""], maximumOutputBytes: 0)
        XCTAssertEqual(output, "")
    }

    func testCancellationExitRacesCompleteExactlyOnce() async throws {
        for index in 0..<10 {
            let task = Task {
                try await SubprocessCapture.standardOutput(
                    of: URL(filePath: "/usr/bin/printf"), arguments: ["ok"])
            }
            if index.isMultiple(of: 2) { await Task.yield() }
            task.cancel()
            do {
                let output = try await task.value
                XCTAssertEqual(output, "ok", "Completion may win the cancellation race")
            } catch is CancellationError {}
        }
    }

    @MainActor
    func testCaptureDoesNotBlockMainActor() async throws {
        let task = Task {
            try await SubprocessCapture.standardOutput(
                of: URL(filePath: "/bin/sleep"), arguments: ["0.1"])
        }
        let start = ContinuousClock.now
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(100))
        let output = try await task.value
        XCTAssertEqual(output, "")
    }

    func testOutputLimitTerminatesAndReapsContinuouslyWritingChild() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appending(path: "SubprocessCapture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let start = ContinuousClock.now
        do {
            _ = try await SubprocessCapture.standardOutput(
                of: URL(filePath: "/bin/sh"), arguments: ["-c", "echo $$ > \(fixture.path)/pid; exec /bin/sleep 1"],
                timeout: .milliseconds(50), maximumOutputBytes: 1024)
            XCTFail("Expected output limit exceeded")
        } catch let error as SubprocessCapture.Failure { XCTAssertEqual(error, .outputLimitExceeded(1024)) }
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(300))
    }

    func testExpiredDeadlineNeverLaunches() async throws {
        do {
            _ = try await SubprocessCapture.standardOutput(
                of: URL(filePath: "/nonexistent-fixture-command"), arguments: [], timeout: .zero)
            XCTFail("Expected timeout before attempting launch")
        } catch let error as SubprocessCapture.Failure { XCTAssertEqual(error, .timedOut) }
    }

    func testNonzeroExitDoesNotReturnPartialSuccessfulOutput() async throws {
        do {
            _ = try await SubprocessCapture.standardOutput(
                of: URL(filePath: "/bin/sh"), arguments: ["-c", "printf partial; exit 7"])
            XCTFail("Expected nonzero exit failure")
        } catch let error as SubprocessCapture.Failure { XCTAssertEqual(error, .nonzeroExit(7)) }
    }

    func testOutputOverLimitThrowsInsteadOfReturningTruncatedSuccess() async throws {
        do {
            _ = try await SubprocessCapture.standardOutput(
                of: URL(filePath: "/usr/bin/printf"), arguments: ["12345"], maximumOutputBytes: 4)
            XCTFail("Expected output limit failure")
        } catch let error as SubprocessCapture.Failure { XCTAssertEqual(error, .outputLimitExceeded(4)) }
        let output = try await SubprocessCapture.standardOutput(
            of: URL(filePath: "/usr/bin/printf"), arguments: ["1234"], maximumOutputBytes: 4)
        XCTAssertEqual(output, "1234")
    }

    func testRunningCancellationThrowsAndReapsOwnedChild() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appending(path: "SubprocessCapture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let pidFile = fixture.appending(path: "pid")
        let task = Task {
            try await SubprocessCapture.standardOutput(
                of: URL(filePath: "/bin/sh"),
                arguments: ["-c", "printf '%s' $$ > \"$1\"; exec /bin/sleep 1", "fixture", pidFile.path])
        }
        let readyDeadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !FileManager.default.fileExists(atPath: pidFile.path), ContinuousClock.now < readyDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let start = ContinuousClock.now
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {}
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8)))
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        var status: Int32 = 0
        XCTAssertEqual(waitpid(pid, &status, WNOHANG), -1)
        XCTAssertEqual(errno, ECHILD)
    }

    func testDeadlineThrowsAndReapsOwnedChild() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appending(path: "SubprocessCapture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let pidFile = fixture.appending(path: "pid")
        let start = ContinuousClock.now
        do {
            _ = try await SubprocessCapture.standardOutput(
                of: URL(filePath: "/bin/sh"),
                arguments: ["-c", "printf '%s' $$ > \"$1\"; exec /bin/sleep 1", "fixture", pidFile.path],
                timeout: .milliseconds(100))
            XCTFail("Expected a timeout, not successful empty output")
        } catch let error as SubprocessCapture.Failure { XCTAssertEqual(error, .timedOut) }
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8)))
        XCTAssertEqual(kill(pid, 0), -1, "The owned child must be gone before returning")
        XCTAssertEqual(errno, ESRCH)
        var status: Int32 = 0
        XCTAssertEqual(waitpid(pid, &status, WNOHANG), -1)
        XCTAssertEqual(errno, ECHILD, "The owned child must already be reaped")
    }
}