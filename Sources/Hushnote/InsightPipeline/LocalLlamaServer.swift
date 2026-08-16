import Foundation

/// Owns one local llama-server process. The server is always bound to the IPv4
/// loopback interface and is launched directly, without a shell.
public actor LocalLlamaServer {
    public struct Configuration: Equatable, Sendable {
        public let executableURL: URL
        public let modelURL: URL
        public let port: Int
        public let startupTimeout: Duration
        public let healthPollInterval: Duration

        public init(
            executableURL: URL,
            modelURL: URL,
            port: Int = 8080,
            startupTimeout: Duration = .seconds(30),
            healthPollInterval: Duration = .milliseconds(250)
        ) throws {
            guard executableURL.isFileURL, modelURL.isFileURL else {
                throw InsightProviderError.invalidConfiguration(
                    "llama-server executable and model must be local file URLs."
                )
            }
            guard (1...65_535).contains(port) else {
                throw InsightProviderError.invalidConfiguration("Invalid llama-server port.")
            }
            self.executableURL = executableURL
            self.modelURL = modelURL
            self.port = port
            self.startupTimeout = startupTimeout
            self.healthPollInterval = healthPollInterval
        }

        var launchArguments: [String] {
            [
                "--host", "127.0.0.1",
                "--port", String(port),
                "-m", modelURL.path
            ]
        }
    }

    public nonisolated let baseURL: URL

    private let configuration: Configuration
    private let httpClient: any HTTPClient
    private var process: Process?

    public init(
        configuration: Configuration,
        httpClient: any HTTPClient = URLSessionHTTPClient()
    ) {
        self.configuration = configuration
        self.httpClient = httpClient
        self.baseURL = URL(string: "http://127.0.0.1:\(configuration.port)")!
    }

    deinit {
        if let process, process.isRunning {
            process.terminate()
        }
    }

    public func start() async throws {
        if let process, process.isRunning {
            if await isHealthy() { return }
            stop()
        }

        let process = Process()
        process.executableURL = configuration.executableURL
        process.arguments = configuration.launchArguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw InsightProviderError.invalidConfiguration(
                "Unable to launch llama-server: \(error.localizedDescription)"
            )
        }
        self.process = process

        do {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: configuration.startupTimeout)
            while clock.now < deadline {
                try Task.checkCancellation()
                if await isHealthy() { return }
                guard process.isRunning else {
                    let status = process.terminationStatus
                    self.process = nil
                    throw InsightProviderError.processExited(status)
                }
                try await Task.sleep(for: configuration.healthPollInterval)
            }
        } catch {
            stop()
            throw error
        }

        stop()
        throw InsightProviderError.localServiceUnavailable
    }

    public func stop() {
        guard let process else { return }
        if process.isRunning { process.terminate() }
        self.process = nil
    }

    public func isRunning() -> Bool {
        process?.isRunning == true
    }

    private func isHealthy() async -> Bool {
        let url = baseURL.appending(path: "health")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 2
        do {
            let (_, response) = try await httpClient.data(for: request)
            return (200..<300).contains(response.statusCode)
        } catch {
            return false
        }
    }
}
