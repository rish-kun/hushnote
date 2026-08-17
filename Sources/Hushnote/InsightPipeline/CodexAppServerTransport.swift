import Foundation

public protocol CodexAppServerTransport: Sendable {
    func start() async throws
    func send(_ message: JSONValue) async throws
    func messages() async -> AsyncThrowingStream<JSONValue, Error>
    func stop() async
}

public actor ProcessCodexAppServerTransport: CodexAppServerTransport {
    private let explicitExecutableURL: URL?
    private let resolver: AgentExecutableResolver
    private let arguments: [String]
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?

    public init(
        executableURL: URL? = nil,
        arguments: [String] = ["app-server", "--listen", "stdio://"],
        resolver: AgentExecutableResolver = AgentExecutableResolver()
    ) {
        self.explicitExecutableURL = executableURL
        self.arguments = arguments
        self.resolver = resolver
    }

    /// Where `codex` actually is. Resolved on every start rather than at init,
    /// so a tool installed after launch is picked up and a missing one is
    /// reported as a missing tool instead of a spawn failure.
    public func executable() throws -> URL {
        if let explicitExecutableURL { return explicitExecutableURL }
        return try resolver.resolve("codex")
    }

    public func launchArguments() -> [String] { arguments }

    public func start() throws {
        guard process == nil else { return }
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.executableURL = try executable()
        process.arguments = arguments
        process.environment = AgentProcessEnvironment.minimal()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
        self.input = inputPipe.fileHandleForWriting
        self.output = outputPipe.fileHandleForReading
    }

    public func send(_ message: JSONValue) throws {
        guard let input else { throw InsightProviderError.transportFailure }
        var data = try JSONEncoder().encode(message)
        data.append(0x0A)
        try input.write(contentsOf: data)
    }

    public func messages() -> AsyncThrowingStream<JSONValue, Error> {
        guard let output else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: InsightProviderError.transportFailure)
            }
        }
        return AsyncThrowingStream { continuation in
            let task = Task.detached {
                var buffer = Data()
                do {
                    for try await byte in output.bytes {
                        if byte == 0x0A {
                            if !buffer.isEmpty {
                                continuation.yield(try JSONDecoder().decode(JSONValue.self, from: buffer))
                                buffer.removeAll(keepingCapacity: true)
                            }
                        } else {
                            buffer.append(byte)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func stop() {
        try? input?.close()
        try? output?.close()
        if let process, process.isRunning { process.terminate() }
        process = nil
        input = nil
        output = nil
    }
}

