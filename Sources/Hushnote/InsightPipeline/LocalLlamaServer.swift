import Foundation
import Security

/// Whether anything is already listening on a loopback port.
///
/// Port 8080 is the most commonly occupied port on a developer's Mac, and most
/// dev servers answer 200 on any path they do not recognise. Discovering that
/// by sending it a meeting transcript is not an option.
public enum LoopbackPortProbe {
    public static func isAvailable(port: Int) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = UInt16(port).bigEndian
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bound == 0
    }
}

/// Owns one local llama-server process. The server is always bound to the IPv4
/// loopback interface and is launched directly, without a shell.
///
/// Being on loopback is not by itself proof that the thing answering is ours.
/// Three things establish that: the port was free before launch, the process we
/// started is still alive, and the responder both accepts this run's API key
/// and reports back the model file we handed it.
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

        /// The key is minted per run and passed on the command line so that a
        /// listener we did not start cannot be mistaken for one we did.
        public func launchArguments(apiKey: String) -> [String] {
            [
                "--host", "127.0.0.1",
                "--port", String(port),
                "--api-key", apiKey,
                "-m", modelURL.path
            ]
        }
    }

    public nonisolated let baseURL: URL

    /// This run's shared secret. Anything that cannot present it is not the
    /// process we launched.
    public nonisolated let apiKey: String

    /// The model file this server was launched with, so a caller can check that
    /// the responder names it back.
    public nonisolated let modelURL: URL

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
        self.apiKey = Self.makeAPIKey()
        self.modelURL = configuration.modelURL
    }

    deinit {
        if let process, process.isRunning {
            process.terminate()
        }
    }

    public func start() async throws {
        if let process, process.isRunning {
            if await isOurs() { return }
            stop()
        }

        guard LoopbackPortProbe.isAvailable(port: configuration.port) else {
            throw InsightProviderError.invalidConfiguration(
                """
                Port \(configuration.port) is already in use by another program. \
                Hushnote will not send a transcript to a server it did not start. \
                Quit whatever is using the port, or choose another one in Settings.
                """
            )
        }

        let process = Process()
        process.executableURL = configuration.executableURL
        process.arguments = configuration.launchArguments(apiKey: apiKey)
        process.environment = AgentProcessEnvironment.minimal()
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
                // Liveness is checked before the answer is believed. A health
                // response from a dead process is somebody else's health.
                guard process.isRunning else {
                    let status = process.terminationStatus
                    self.process = nil
                    throw InsightProviderError.processExited(status)
                }
                if await isOurs() { return }
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

    /// Whether the responder identifies the model file we handed it.
    ///
    /// llama.cpp reports this at `/props`. Both the current `model_path` and
    /// the older `default_generation_settings.model` are accepted, because the
    /// key moved between releases and a stricter reading would reject working
    /// servers.
    public nonisolated static func identifiesOurModel(_ data: Data, modelURL: URL) -> Bool {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { return false }
        let reported = json["model_path"]?.stringValue
            ?? json["default_generation_settings"]?["model"]?.stringValue
            ?? json["model"]?.stringValue
        guard let reported, !reported.isEmpty else { return false }
        if reported.contains("/") {
            return URL(filePath: reported).standardizedFileURL.path
                == modelURL.standardizedFileURL.path
        }
        return reported == modelURL.lastPathComponent
    }

    private func isOurs() async -> Bool {
        guard process?.isRunning == true else { return false }
        guard await respondsWith2xx(path: "health") else { return false }
        guard let data = await body(path: "props") else { return false }
        return Self.identifiesOurModel(data, modelURL: configuration.modelURL)
    }

    private func respondsWith2xx(path: String) async -> Bool {
        guard let (_, response) = await send(path: path) else { return false }
        return (200..<300).contains(response.statusCode)
    }

    private func body(path: String) async -> Data? {
        guard let (data, response) = await send(path: path),
              (200..<300).contains(response.statusCode) else { return nil }
        return data
    }

    private func send(path: String) async -> (Data, HTTPURLResponse)? {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "GET"
        request.timeoutInterval = 2
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return try? await httpClient.data(for: request)
    }

    private static func makeAPIKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
