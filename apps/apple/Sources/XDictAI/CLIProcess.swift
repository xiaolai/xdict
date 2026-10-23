import Darwin
import Foundation
import Synchronization

/// **One child process, in a process group of its own, with bounded pipes and a deadline** (ADR-0021 d.9, d.10).
///
/// The group is what makes cancellation real: `claude` and `codex` start children of their own, and a signal to the
/// launcher alone leaves them running. Arguments are an array — no shell ever parses them — the environment is exactly
/// what the caller built, the working directory is the app's own, and both output streams are capped: a chatty or
/// hostile child cannot grow the app's memory, and stderr is kept only for classification, never logged.
struct CLIProcess {
    /// How much of each stream is kept. Lines past the cap are read and dropped, so the child never blocks on a full
    /// pipe.
    static let stdoutCap = 1 << 20
    static let stderrCap = 1 << 16
    /// The grace between `SIGTERM` and `SIGKILL`, and the longest wait for the readers after the child is reaped.
    static let killGrace: Duration = .seconds(2)
    static let readerJoin: Duration = .seconds(1)
    /// How often the child is polled while it runs.
    static let pollInterval: Duration = .milliseconds(10)

    struct Run: Sendable, Equatable {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    enum Failure: Error, Equatable, Sendable {
        /// The executable is not there, not a regular file, or not executable by this process.
        case notInstalled
        case spawn(Int32)
        case timeout
        case cancelled
    }

    /// Runs `executable` to exit, feeding `input` on stdin, within `deadline`.
    ///
    /// `onLine` is called for each complete stdout line as it arrives (login instructions are useful while the child is
    /// still running); it is called from a reader thread and must be cheap and thread-safe.
    static func run(
        executable: URL, arguments: [String], environment: [String: String], workingDirectory: URL,
        input: String? = nil, deadline: Duration, onLine: (@Sendable (String) -> Void)? = nil
    ) async throws(Failure) -> Run {
        guard isExecutable(executable) else { throw .notInstalled }

        var outPipe = [Int32](repeating: -1, count: 2)
        var errPipe = [Int32](repeating: -1, count: 2)
        var inPipe = [Int32](repeating: -1, count: 2)
        guard pipe(&outPipe) == 0, pipe(&errPipe) == 0, pipe(&inPipe) == 0 else {
            closeAll(outPipe, errPipe, inPipe)
            throw .spawn(errno)
        }
        // Every end the parent created is close-on-exec: the child gets only the three descriptors `dup2` gives it, and
        // in particular it does not inherit the write end of its own stdin — with that open, EOF never arrives and a
        // child that reads stdin to the end hangs until the deadline.
        for fd in outPipe + errPipe + inPipe {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, inPipe[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], STDERR_FILENO)
        let directory = workingDirectory.path
        directory.withCString { path in
            _ = posix_spawn_file_actions_addchdir(&actions, path)
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        // A process group of its own, named by the child's pid: signals reach everything it starts.
        posix_spawnattr_setpgroup(&attributes, 0)

        var argv: [UnsafeMutablePointer<CChar>?] = ([executable.path] + arguments).map { strdup($0) }
        argv.append(nil)
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)
        defer {
            for pointer in argv where pointer != nil { free(pointer) }
            for pointer in envp where pointer != nil { free(pointer) }
        }

        var pid: pid_t = 0
        let spawned = executable.path.withCString { path in
            posix_spawn(&pid, path, &actions, &attributes, &argv, &envp)
        }
        if spawned != 0 {
            closeAll(outPipe, errPipe, inPipe)
            throw .spawn(spawned)
        }
        // The parent keeps only the three ends it uses: stdout and stderr for reading, stdin for writing.
        close(inPipe[0])
        close(outPipe[1])
        close(errPipe[1])

        // Only the ends the parent uses, as immutable values: the reader and writer threads below capture these, and a
        // captured `var` array is not sendable.
        let stdoutFD = outPipe[0]
        let stderrFD = errPipe[0]
        let stdinFD = inPipe[1]
        // **A child may exit before reading its prompt.** Without this, the writer thread's `write` raises SIGPIPE and
        // terminates XDict; with it, the write returns EPIPE and the loop below stops. (Audit finding, 2026-10-20.)
        _ = fcntl(stdinFD, F_SETNOSIGPIPE, 1)
        // **One dedicated thread reads both pipes without blocking the shared pool** (2026-10-23): the readers used to
        // be blocking work on `DispatchQueue.global()`, and a starved pool made the reader join time out and leave two
        // descriptors open per timeout — under 32 concurrent runs, until `posix_spawn` itself failed with EMFILE
        // (`spawn(24)`), which turned the CLI provider tests red under a loaded suite. The thread polls non-blocking, so
        // it always ends by itself or on `stop`, and it owns its descriptors to the end.
        let stdoutText = Mutex("")
        let stderrText = Mutex("")
        let stopping = Mutex(false)
        let reader = Thread {
            Self.pump(stdout: stdoutFD, stderr: stderrFD, onLine: onLine, stop: stopping,
                      out: stdoutText, err: stderrText)
        }
        reader.start()
        if let input {
            DispatchQueue.global().async {
                let bytes = Array(input.utf8)
                var offset = 0
                while offset < bytes.count {
                    let written = bytes.withUnsafeBytes { raw -> Int in
                        guard let base = raw.baseAddress else { return 0 }
                        return write(stdinFD, base.advanced(by: offset), bytes.count - offset)
                    }
                    if written <= 0 { break }
                    offset += written
                }
                close(stdinFD)
            }
        } else {
            close(stdinFD)
        }

        let deadlineAt = ContinuousClock().now + deadline
        let status: Int32
        // Cancelling the task wakes `waitFor`'s sleep at once, which throws `.cancelled`; the process group is ended
        // below, before the rethrow. (A `withTaskCancellationHandler` wrapper would work too, but it is `rethrows` and
        // so erases this function's typed failure.)
        do {
            status = try await waitFor(pid: pid, until: deadlineAt)
        } catch {
            signalGroup(pid, SIGTERM)
            await reap(pid)
            await finish(reader, stop: stopping)
            throw error
        }
        // **One owner per descriptor**: the reader closes both when it reaches EOF, and nothing here closes them too —
        // a second close can hit a descriptor number the system has already reused. (Audit finding, 2026-10-20.)
        await finish(reader, stop: stopping)
        return Run(status: status, stdout: stdoutText.withLock { $0 }, stderr: stderrText.withLock { $0 })
    }

    // MARK: - Waiting

    private static func waitFor(pid: pid_t, until deadline: ContinuousClock.Instant) async throws(Failure) -> Int32 {
        while true {
            var raw: Int32 = 0
            let answer = waitpid(pid, &raw, WNOHANG)
            if answer == pid { return exitCode(raw) }
            if answer < 0 { throw .spawn(errno) }
            if ContinuousClock().now >= deadline { throw .timeout }
            do { try await Task.sleep(for: pollInterval) } catch { throw .cancelled }
        }
    }

    private static func reap(_ pid: pid_t) async {
        signalGroup(pid, SIGTERM)
        let graceAt = ContinuousClock().now + killGrace
        while ContinuousClock().now < graceAt {
            var raw: Int32 = 0
            if waitpid(pid, &raw, WNOHANG) == pid {
                // **The launcher is gone; its group may not be.** A descendant that ignored SIGTERM is killed now; if
                // the group is empty this is an harmless ESRCH. (Audit finding, 2026-10-20.)
                kill(-pid, SIGKILL)
                return
            }
            try? await Task.sleep(for: pollInterval)
        }
        signalGroup(pid, SIGKILL)
        var raw: Int32 = 0
        while true {
            let answer = waitpid(pid, &raw, WNOHANG)
            if answer == pid || (answer < 0 && errno != EINTR) { return }
            usleep(5_000)
        }
    }

    /// The reader's end, waited for without blocking the cooperative pool: EOF ends it by itself, and a pipe a
    /// descendant left the process group holding is asked to stop, bounded by the poll interval. The stop is set, never
    /// a second close — the thread owns its descriptors.
    private static func finish(_ reader: Thread, stop: borrowing Mutex<Bool>) async {
        let until = ContinuousClock().now + readerJoin
        while ContinuousClock().now < until {
            if reader.isFinished { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        stop.withLock { $0 = true }
        let last = ContinuousClock().now + .milliseconds(500)
        while ContinuousClock().now < last {
            if reader.isFinished { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private static func signalGroup(_ pid: pid_t, _ signal: Int32) {
        guard pid > 0 else { return }
        kill(-pid, signal)
        kill(pid, signal)
    }

    static func exitCode(_ raw: Int32) -> Int32 {
        let term = raw & 0x7f
        if term == 0 { return (raw >> 8) & 0xff }
        return 128 + term
    }

    // MARK: - Reading

    /// One pipe the pump reads.
    private struct Stream {
        let fd: Int32
        let cap: Int
        var kept = Data()
        var open = true

        init(_ fd: Int32, _ cap: Int) {
            self.fd = fd
            self.cap = cap
        }
    }

    /// **Both pipes, read to EOF on this one thread.** Non-blocking, so a `poll` that said there is something to read is
    /// always followed by a read that returns at once, and no other thread ever touches these descriptors: the stop
    /// flag ends the loop, and the thread closes what it still holds. Each stream keeps up to `cap` bytes and reads the
    /// rest and drops it, so the child can never block on a full pipe.
    private static func pump(stdout outFD: Int32, stderr errFD: Int32, onLine: (@Sendable (String) -> Void)?,
                             stop: borrowing Mutex<Bool>, out: borrowing Mutex<String>, err: borrowing Mutex<String>) {
        var streams = [Stream(outFD, stdoutCap), Stream(errFD, stderrCap)]
        for stream in streams {
            _ = fcntl(stream.fd, F_SETFL, O_NONBLOCK)
        }
        var pending = ""
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while !stop.withLock({ $0 }), streams.contains(where: \.open) {
            var fds = streams.filter(\.open).map { pollfd(fd: $0.fd, events: Int16(POLLIN), revents: 0) }
            let ready = fds.withUnsafeMutableBufferPointer { poll($0.baseAddress, nfds_t($0.count), 100) }
            if ready < 0, errno != EINTR { break }
            var answer = 0
            for index in streams.indices where streams[index].open {
                defer { answer += 1 }
                guard ready > 0, fds[answer].revents != 0 else { continue }
                let count = buffer.withUnsafeMutableBytes { read(streams[index].fd, $0.baseAddress, $0.count) }
                if count > 0 {
                    if streams[index].kept.count < streams[index].cap {
                        let room = streams[index].cap - streams[index].kept.count
                        streams[index].kept.append(contentsOf: buffer[0..<min(count, room)])
                    }
                    if index == 0, let onLine {
                        pending += String(decoding: buffer[0..<count], as: UTF8.self)
                        // A newline-free stream must not grow the pending buffer without bound (`stdoutCap` bounds only
                        // what is kept). A partial line past the cap is dropped. (Audit finding, 2026-10-20.)
                        if pending.utf8.count > 256 << 10 { pending = "" }
                        while let newline = pending.firstIndex(of: "\n") {
                            let line = String(pending[..<newline]).trimmingCharacters(in: .whitespacesAndNewlines)
                            pending.removeSubrange(...newline)
                            if !line.isEmpty { onLine(line) }
                        }
                    }
                    continue
                }
                if count < 0, errno == EINTR || errno == EAGAIN { continue }
                close(streams[index].fd)
                streams[index].open = false
            }
        }
        for index in streams.indices where streams[index].open {
            close(streams[index].fd)
            streams[index].open = false
        }
        if let onLine, !pending.isEmpty {
            let line = pending.trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { onLine(line) }
        }
        out.withLock { $0 = String(decoding: streams[0].kept, as: UTF8.self) }
        err.withLock { $0 = String(decoding: streams[1].kept, as: UTF8.self) }
    }

    // MARK: - Files

    static func isExecutable(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return false
        }
        return access(url.path, X_OK) == 0
    }

    private static func closeAll(_ a: [Int32], _ b: [Int32], _ c: [Int32]) {
        for fd in a + b + c where fd >= 0 { close(fd) }
    }
}

/// Version strings as the CLIs print them (`2.1.304`, `codex-cli 0.163.0`): numeric components compared as integers, a
/// non-numeric component as 0, a missing component as 0.
enum CLIVersion {
    static func atLeast(_ version: String, _ minimum: String) -> Bool {
        let a = version.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        let b = minimum.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let left = index < a.count ? a[index] : 0
            let right = index < b.count ? b[index] : 0
            if left != right { return left > right }
        }
        return true
    }
}
