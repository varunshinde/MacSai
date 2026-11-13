import Darwin
import Foundation

/// Async stdout capture for short-lived, read-only commands. No blocking pipe
/// reads or cooperative-executor threads are retained while the child runs.
public enum SubprocessCapture {
    public enum Failure: Error, Equatable, Sendable {
        case timedOut
        case launchFailed(Int32)
        case readFailed(Int32)
        case outputLimitExceeded(Int)
        case nonzeroExit(Int32)
        case signalled(Int32)
    }

    public static func standardOutput(
        of executable: URL,
        arguments: [String],
        timeout: Duration = .seconds(5),
        maximumOutputBytes: Int = 4 * 1024 * 1024
    ) async throws -> String {
        let capture = Capture()
        let deadline = ContinuousClock.now.advanced(by: timeout)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                Capture.queue.async {
                    capture.start(executable, arguments, deadline: deadline,
                                  maximumOutputBytes: maximumOutputBytes, continuation: continuation)
                }
            }
        } onCancel: {
            capture.cancel()
        }
    }

    /// State is confined to one shared queue, except `cancelled`, which is
    /// protected by cancellationLock. Each capture has a lightweight timer,
    /// not a blocked thread or a detached Swift task.
    private final class Capture: @unchecked Sendable {
        static let queue = DispatchQueue(label: "MacCleanKit.SubprocessCapture", qos: .utility)
        private var continuation: CheckedContinuation<String, any Error>?
        private var timer: DispatchSourceTimer?
        private var reader: FileHandle?
        private var pid: pid_t = 0
        private var output = Data()
        private var maximumOutputBytes = 0
        private var eof = false
        private var exited = false
        private var deadline = ContinuousClock.now
        private var failure: (any Error)?
        private let cancellationLock = NSLock()
        private var cancelled = false

        func cancel() {
            cancellationLock.withLock { cancelled = true }
            Self.queue.async {
                guard self.continuation != nil else { return }
                self.stop(CancellationError())
                self.poll()
            }
        }

        func start(
            _ executable: URL, _ arguments: [String], deadline: ContinuousClock.Instant, maximumOutputBytes: Int,
            continuation: CheckedContinuation<String, any Error>
        ) {
            self.continuation = continuation
            self.maximumOutputBytes = max(0, maximumOutputBytes)
            // Serialise the final cancellation check with spawn. If launch
            // wins that race, cancellation kills and reaps the owned child.
            cancellationLock.lock()
            guard !cancelled else {
                cancellationLock.unlock()
                finish(.failure(CancellationError()))
                return
            }
            defer { cancellationLock.unlock() }
            self.deadline = deadline
            guard ContinuousClock.now < deadline else {
                finish(.failure(Failure.timedOut))
                return
            }
            let pipe = Pipe()
            reader = pipe.fileHandleForReading
            let readFD = pipe.fileHandleForReading.fileDescriptor
            let writeFD = pipe.fileHandleForWriting.fileDescriptor
            guard fcntl(readFD, F_SETFL, O_NONBLOCK) != -1 else {
                finish(.failure(Failure.readFailed(errno)))
                return
            }

            var actions: posix_spawn_file_actions_t?
            posix_spawn_file_actions_init(&actions)
            defer { posix_spawn_file_actions_destroy(&actions) }
            posix_spawn_file_actions_adddup2(&actions, writeFD, STDOUT_FILENO)
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
            posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
            var attributes: posix_spawnattr_t?
            posix_spawnattr_init(&attributes)
            defer { posix_spawnattr_destroy(&attributes) }
            // Do not inherit the dispatch worker's blocked/ignored signals.
            var signalDefaults = sigset_t()
            sigfillset(&signalDefaults)
            sigdelset(&signalDefaults, SIGKILL)
            sigdelset(&signalDefaults, SIGSTOP)
            var signalMask = sigset_t()
            sigemptyset(&signalMask)
            posix_spawnattr_setsigdefault(&attributes, &signalDefaults)
            posix_spawnattr_setsigmask(&attributes, &signalMask)
            posix_spawnattr_setflags(&attributes, Int16(
                POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
            ))
            let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
            defer { argv.forEach { free($0) } }
            let environment = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
            defer { environment.forEach { free($0) } }
            let result = argv.withUnsafeBufferPointer { buffer in
                environment.withUnsafeBufferPointer { env in
                    posix_spawn(&pid, executable.path, &actions, &attributes,
                                UnsafeMutablePointer(mutating: buffer.baseAddress!),
                                UnsafeMutablePointer(mutating: env.baseAddress!))
                }
            }
            try? pipe.fileHandleForWriting.close()
            guard result == 0 else {
                pid = 0
                finish(.failure(Failure.launchFailed(result)))
                return
            }

            let timer = DispatchSource.makeTimerSource(queue: Self.queue)
            self.timer = timer
            timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(1))
            timer.setEventHandler { self.poll() }
            timer.resume()
        }

        private func poll() {
            if failure == nil, ContinuousClock.now >= deadline {
                stop(Failure.timedOut)
            }
            if failure == nil { drain() }
            if !exited {
                var status: Int32 = 0
                if waitpid(pid, &status, WNOHANG) == pid {
                    exited = true
                    pid = 0
                    // Darwin's wait-status macros are not imported by Swift.
                    let signal = status & 0x7f
                    let exitCode = (status >> 8) & 0xff
                    if signal != 0 { stop(Failure.signalled(signal)) }
                    else if exitCode != 0 { stop(Failure.nonzeroExit(exitCode)) }
                }
            }
            if exited, let failure {
                finish(.failure(failure))
            } else if exited && eof {
                finish(.success(String(decoding: output, as: UTF8.self)))
            }
        }

        private func drain() {
            guard let reader else { return }
            var buffer = [UInt8](repeating: 0, count: 8192)
            // A continuously writing child must not starve the deadline timer.
            for _ in 0..<64 {
                let count = read(reader.fileDescriptor, &buffer, buffer.count)
                if count > 0 {
                    guard count <= maximumOutputBytes - output.count else {
                        stop(Failure.outputLimitExceeded(maximumOutputBytes))
                        return
                    }
                    output.append(contentsOf: buffer.prefix(count))
                } else if count == 0 {
                    eof = true
                    try? reader.close()
                    self.reader = nil
                    return
                } else if errno == EAGAIN || errno == EWOULDBLOCK {
                    return
                } else if errno != EINTR {
                    stop(Failure.readFailed(errno))
                    return
                }
            }
        }

        private func stop(_ error: any Error) {
            guard failure == nil else { return }
            failure = error
            try? reader?.close()
            reader = nil
            // Only this unreaped child is signalled. Its PID cannot be reused
            // before our waitpid; never signal a process group or descendants.
            if pid > 0 { kill(pid, SIGKILL) }
        }

        private func finish(_ result: Result<String, any Error>) {
            timer?.cancel()
            timer?.setEventHandler {}
            timer = nil
            try? reader?.close()
            reader = nil
            let continuation = self.continuation
            self.continuation = nil
            continuation?.resume(with: result)
        }
    }
}
