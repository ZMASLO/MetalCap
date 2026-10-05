import Foundation

/// Runs `log stream --style ndjson` for one predicate and hands over each line.
///
/// The stream runs under a small shell that ends it as soon as this process is gone, so a crash,
/// `kill -9` or `exit()` never leaves it behind. If the stream stops on its own (for example when
/// `logd` restarts), it is started again after a growing pause.
public final class LogStream: @unchecked Sendable {
    /// Called on a background queue with each line `log stream` prints.
    public var onLine: ((String) -> Void)?

    private let predicate: String
    private let queue = DispatchQueue(label: "MetalCap.LogStream")
    private var process: Process?
    private var running = false
    private var attempt = 0
    private var startedAt = Date.distantPast

    /// A run this long counts as healthy and resets the pause before the next restart.
    private static let healthyRun: TimeInterval = 60

    /// Watches the parent and the stream: whichever ends first ends the other.
    /// Arguments: the parent's PID, then the command to run.
    private static let watchdog = """
        parent=$1; shift
        "$@" & child=$!
        trap 'kill $child 2>/dev/null; exit 0' TERM INT
        while kill -0 "$parent" 2>/dev/null && kill -0 "$child" 2>/dev/null; do sleep 2; done
        kill "$child" 2>/dev/null
        wait "$child"
        """

    public init(predicate: String) {
        self.predicate = predicate
    }

    /// Pause before restart number `attempt` (counted from 0): 1, 2, 4, 8, 16, 30, 30… seconds.
    static func restartDelay(attempt: Int) -> TimeInterval {
        min(pow(2, Double(min(attempt, 10))), 30)
    }

    /// PID of the watchdog shell, for tests.
    var processIdentifier: Int32? {
        queue.sync { process?.processIdentifier }
    }

    public func start() throws {
        try queue.sync {
            guard !running else { return }
            running = true
            attempt = 0
            try launch()
        }
    }

    public func stop() {
        queue.sync {
            running = false
            process?.terminate()
            process = nil
        }
    }

    /// Must be called on `queue`.
    private func launch() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", Self.watchdog, "metalcap-log-stream",
                             String(ProcessInfo.processInfo.processIdentifier),
                             "/usr/bin/log", "stream", "--style", "ndjson", "--predicate", predicate]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        var buffer = LineBuffer()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            for line in buffer.append(data) { self?.onLine?(line) }
        }
        process.terminationHandler = { [weak self] ended in
            self?.queue.async { self?.restart(after: ended) }
        }
        try process.run()
        self.process = process
        startedAt = Date()
    }

    /// Must be called on `queue`.
    private func restart(after ended: Process) {
        guard running, ended === process else { return }
        process = nil
        if Date().timeIntervalSince(startedAt) > Self.healthyRun { attempt = 0 }
        let delay = Self.restartDelay(attempt: attempt)
        attempt += 1
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.running, self.process == nil else { return }
            try? self.launch()
        }
    }
}
