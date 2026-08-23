import Foundation

public struct AgentProcessInvocation: Sendable, Equatable {
    public let executableURL: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let workingDirectory: URL
    public let standardInput: String
    public let timeout: Duration

    public init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL,
        standardInput: String,
        timeout: Duration
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.standardInput = standardInput
        self.timeout = timeout
    }
}

public struct AgentProcessResult: Sendable, Equatable {
    public let standardOutput: String
    public let standardError: String
    public let exitCode: Int32

    public init(standardOutput: String, standardError: String, exitCode: Int32) {
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.exitCode = exitCode
    }
}

public protocol AgentProcessRunner: Sendable {
    func run(_ invocation: AgentProcessInvocation) async throws -> AgentProcessResult
}

/// Runs one agent CLI to completion.
///
/// Two things here are load-bearing rather than stylistic. Stdin is written on
/// its own queue while stdout and stderr are being drained, because the macOS
/// pipe buffer is about 64 KB and a meeting transcript is several hundred: a
/// write-then-read ordering deadlocks on the first real transcript, not on the
/// test fixture. And the wall clock is Hushnote's own, because none of the
/// three CLIs has a timeout flag, so a hung agent otherwise hangs the summary
/// forever.
public struct SubprocessAgentProcessRunner: AgentProcessRunner {
    public init() {}

    public func run(_ invocation: AgentProcessInvocation) async throws -> AgentProcessResult {
        try Task.checkCancellation()
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = invocation.executableURL
        process.arguments = invocation.arguments
        process.environment = invocation.environment
        process.currentDirectoryURL = invocation.workingDirectory
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw InsightProviderError.invalidConfiguration(
                "Unable to run \(invocation.executableURL.lastPathComponent): \(error.localizedDescription)"
            )
        }
        let lifetime = AgentProcessLifetime(process: process)

        let stdin = Data(invocation.standardInput.utf8)
        let writer = DispatchQueue(label: "app.hushnote.agent-stdin")
        writer.async {
            let handle = inputPipe.fileHandleForWriting
            // A closed pipe is the child having exited early; that is reported
            // through the exit status, not as a crash here.
            try? handle.write(contentsOf: stdin)
            try? handle.close()
        }

        let drain = Task.detached {
            async let out = readToEnd(outputPipe.fileHandleForReading)
            async let err = readToEnd(errorPipe.fileHandleForReading)
            return await (out, err)
        }

        // Deliberately not a task group: waiting on `terminationHandler` cannot
        // be cancelled, and a group waits for every child before it returns, so
        // the timeout would only ever be observed after the process it was
        // supposed to cut short had already finished.
        let outcome = OneShot<Bool>()
        process.terminationHandler = { _ in Task { await outcome.send(true) } }
        let timer = Task {
            try? await Task.sleep(for: invocation.timeout)
            await outcome.send(false)
        }
        let terminated = await withTaskCancellationHandler {
            await outcome.value()
        } onCancel: {
            lifetime.stop()
            Task { await outcome.send(false) }
        }
        timer.cancel()

        // Termination and cancellation can arrive in either order. Cancellation
        // still wins even if the child's termination handler won the one-shot
        // race by a few microseconds.
        if Task.isCancelled {
            lifetime.stop()
            drain.cancel()
            throw CancellationError()
        }

        guard terminated else {
            lifetime.stop()
            drain.cancel()
            throw InsightProviderError.timedOut
        }

        let (out, err) = await drain.value
        return AgentProcessResult(
            standardOutput: out,
            standardError: err,
            exitCode: process.terminationStatus
        )
    }

}

/// A synchronous, Sendable cancellation handle around Foundation's non-Sendable
/// `Process`. Both the timeout and Swift task cancellation can race to stop the
/// same child; the lock makes termination idempotent.
private final class AgentProcessLifetime: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var didStop = false

    init(process: Process) {
        self.process = process
    }

    /// Ask, then insist. An agent that ignores SIGTERM must not keep a transcript
    /// in memory after its owning task is gone.
    func stop() {
        lock.lock()
        guard !didStop else {
            lock.unlock()
            return
        }
        didStop = true
        lock.unlock()

        guard process.isRunning else { return }
        process.terminate()
        let deadline = DispatchTime.now() + .milliseconds(500)
        DispatchQueue.global().asyncAfter(deadline: deadline) { [process] in
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
}

/// Whichever of two racing answers arrives first, delivered once.
private actor OneShot<Value: Sendable> {
    private var value: Value?
    private var waiter: CheckedContinuation<Value, Never>?

    func send(_ newValue: Value) {
        guard value == nil else { return }
        value = newValue
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: newValue)
        }
    }

    func value() async -> Value {
        if let value { return value }
        return await withCheckedContinuation { continuation in
            if let value {
                continuation.resume(returning: value)
            } else {
                waiter = continuation
            }
        }
    }
}

private func readToEnd(_ handle: FileHandle) async -> String {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            let data = (try? handle.readToEnd()) ?? Data()
            continuation.resume(returning: String(decoding: data, as: UTF8.self))
        }
    }
}
