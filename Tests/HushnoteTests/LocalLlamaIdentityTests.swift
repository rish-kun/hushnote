import Foundation
import Testing
@testable import Hushnote

/// The "local" provider is the one Settings promises never leaves the machine.
/// Everything here is about that promise being true even when something else
/// is already listening on the port.
@Suite("Local llama identity")
struct LocalLlamaIdentityTests {
    @Test("Only the literal loopback addresses are accepted")
    func requiresLiteralLoopback() throws {
        // "localhost" resolves through /etc/hosts and can be repointed, so a
        // name is not an address.
        for host in ["localhost", "example.com", "127.0.0.1.example.com", "0.0.0.0"] {
            #expect(throws: InsightProviderError.self) {
                _ = try LlamaCppInsightProvider(baseURL: URL(string: "http://\(host):8080")!)
            }
        }
        for host in ["127.0.0.1", "[::1]"] {
            #expect(throws: Never.self) {
                _ = try LlamaCppInsightProvider(baseURL: URL(string: "http://\(host):8080")!)
            }
        }
    }

    @Test("An occupied port is seen as occupied, and a free one as free")
    func probesPorts() throws {
        let listener = try TestListener()
        defer { listener.close() }

        #expect(!LoopbackPortProbe.isAvailable(port: listener.port))
        #expect(LoopbackPortProbe.isAvailable(port: try TestListener.freePort()))
    }

    @Test("An occupied port fails before anything is launched")
    func refusesToLaunchOntoAnOccupiedPort() async throws {
        let listener = try TestListener()
        defer { listener.close() }
        let server = LocalLlamaServer(
            configuration: try LocalLlamaServer.Configuration(
                executableURL: URL(filePath: "/bin/echo"),
                modelURL: URL(filePath: "/tmp/model.gguf"),
                port: listener.port
            ),
            httpClient: AlwaysHealthyHTTPClient()
        )

        await #expect(throws: InsightProviderError.self) {
            try await server.start()
        }
        // Port 8080 is the most commonly occupied port on a developer's Mac,
        // and most dev servers answer 200 on any path. Nothing may be sent
        // until we know the responder is ours.
        #expect(await !server.isRunning())
    }

    @Test("A responder is ours only when it reports the model we launched")
    func verifiesIdentityFromProps() {
        let model = URL(filePath: "/models/qwen3-8b.gguf")

        #expect(LocalLlamaServer.identifiesOurModel(
            Data(#"{"model_path":"/models/qwen3-8b.gguf","total_slots":1}"#.utf8),
            modelURL: model
        ))
        #expect(LocalLlamaServer.identifiesOurModel(
            Data(#"{"default_generation_settings":{"model":"/models/qwen3-8b.gguf"}}"#.utf8),
            modelURL: model
        ))
        #expect(!LocalLlamaServer.identifiesOurModel(
            Data(#"{"model_path":"/models/something-else.gguf"}"#.utf8),
            modelURL: model
        ))
        // A dev server that answers 200 on every path answers this one too.
        #expect(!LocalLlamaServer.identifiesOurModel(Data("<!DOCTYPE html>".utf8), modelURL: model))
        #expect(!LocalLlamaServer.identifiesOurModel(Data("{}".utf8), modelURL: model))
    }

    @Test("The server is launched with a per-run key, and every request carries it")
    func authenticatesEveryRequest() async throws {
        let configuration = try LocalLlamaServer.Configuration(
            executableURL: URL(filePath: "/opt/hushnote/bin/llama-server"),
            modelURL: URL(filePath: "/models/qwen3-8b.gguf"),
            port: 18_081
        )
        let server = LocalLlamaServer(configuration: configuration)
        let key = server.apiKey

        #expect(key.count >= 32)
        #expect(configuration.launchArguments(apiKey: key).contains("--api-key"))
        #expect(configuration.launchArguments(apiKey: key).contains(key))

        let http = RecordingAuthHTTPClient(plans: [
            .init(status: 200, body: "{}"),
            .init(status: 200, body: #"{"model_path":"/models/qwen3-8b.gguf"}"#),
            .init(status: 200, body: #"{"choices":[{"message":{"content":"{}"}}]}"#)
        ])
        let provider = try LlamaCppInsightProvider(
            baseURL: URL(string: "http://127.0.0.1:18081")!,
            httpClient: http,
            apiKey: key,
            expectedModelURL: configuration.modelURL
        )

        _ = try await provider.complete(localRequest())
        let requests = await http.recorded()

        #expect(requests.count == 3)
        #expect(requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer \(key)"
        })
        #expect(requests.map { $0.url?.path } == ["/health", "/props", "/v1/chat/completions"])
    }

    @Test("A listener that cannot prove it is ours gets no transcript")
    func refusesAForeignResponder() async throws {
        let http = RecordingAuthHTTPClient(plans: [
            .init(status: 200, body: "OK"),
            .init(status: 200, body: "<html>webpack dev server</html>")
        ])
        let provider = try LlamaCppInsightProvider(
            baseURL: URL(string: "http://127.0.0.1:8080")!,
            httpClient: http,
            apiKey: "run-key",
            expectedModelURL: URL(filePath: "/models/qwen3-8b.gguf")
        )

        await #expect(throws: InsightProviderError.self) {
            _ = try await provider.complete(localRequest())
        }
        let requests = await http.recorded()

        // The transcript must not be the thing that discovers who is listening.
        #expect(!requests.contains { $0.url?.path == "/v1/chat/completions" })
    }
}

private func localRequest() -> InsightProviderRequest {
    InsightProviderRequest(
        purpose: .synthesis,
        systemPrompt: "Return JSON.",
        userPrompt: "Transcript text.",
        outputSchemaName: "test_output",
        outputSchema: .object(["type": .string("object")])
    )
}

/// A real socket bound to loopback, so the port probe is tested against the
/// thing it actually has to detect.
final class TestListener {
    let port: Int
    private let descriptor: Int32

    init() throws {
        let socketDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else { throw TestListenerError.failed }
        var reuse: Int32 = 1
        setsockopt(socketDescriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(socketDescriptor, 1) == 0 else {
            Darwin.close(socketDescriptor)
            throw TestListenerError.failed
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketDescriptor, $0, &length)
            }
        }
        guard named == 0 else {
            Darwin.close(socketDescriptor)
            throw TestListenerError.failed
        }
        self.descriptor = socketDescriptor
        self.port = Int(UInt16(bigEndian: actual.sin_port))
    }

    static func freePort() throws -> Int {
        let listener = try TestListener()
        let port = listener.port
        listener.close()
        return port
    }

    func close() { Darwin.close(descriptor) }
}

enum TestListenerError: Error { case failed }

private struct AlwaysHealthyHTTPClient: HTTPClient {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        (
            Data("{}".utf8),
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }
}

private actor RecordingAuthHTTPClient: HTTPClient {
    struct Plan: Sendable {
        let status: Int
        let body: String
    }

    private var plans: [Plan]
    private var requests: [URLRequest] = []

    init(plans: [Plan]) { self.plans = plans }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !plans.isEmpty, let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: plans[0].status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
              ) else {
            throw InsightProviderError.transportFailure
        }
        return (Data(plans.removeFirst().body.utf8), response)
    }

    func recorded() -> [URLRequest] { requests }
}
