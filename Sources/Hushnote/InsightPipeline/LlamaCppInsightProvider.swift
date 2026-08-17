import Foundation

public struct LlamaCppInsightProvider: InsightProvider {
    public let descriptor = InsightProviderDescriptor(
        id: "llama-cpp",
        displayName: "Local model",
        kind: .llamaCpp,
        sendsTranscriptOffDevice: false
    )

    private let model: String?
    private let baseURL: URL
    private let httpClient: any HTTPClient
    private let localServer: LocalLlamaServer?
    private let apiKey: String?
    private let expectedModelURL: URL?

    public init(
        model: String? = nil,
        baseURL: URL = URL(string: "http://127.0.0.1:8080")!,
        httpClient: any HTTPClient = URLSessionHTTPClient(),
        localServer: LocalLlamaServer? = nil,
        apiKey: String? = nil,
        expectedModelURL: URL? = nil
    ) throws {
        // A literal address only. "localhost" is a name resolved through
        // /etc/hosts, and a name can be pointed somewhere else; the descriptor
        // for this provider promises the transcript stays on the machine.
        guard baseURL.scheme == "http",
              let host = baseURL.host,
              ["127.0.0.1", "::1"].contains(host.lowercased()) else {
            throw InsightProviderError.invalidConfiguration(
                "The llama.cpp endpoint must use HTTP on 127.0.0.1 or ::1."
            )
        }
        self.model = model
        self.baseURL = baseURL
        self.httpClient = httpClient
        self.localServer = localServer
        self.apiKey = apiKey
        self.expectedModelURL = expectedModelURL
    }

    public init(
        model: String? = nil,
        localServer: LocalLlamaServer,
        httpClient: any HTTPClient = URLSessionHTTPClient()
    ) throws {
        try self.init(
            model: model,
            baseURL: localServer.baseURL,
            httpClient: httpClient,
            localServer: localServer,
            apiKey: localServer.apiKey,
            expectedModelURL: localServer.modelURL
        )
    }

    public func healthCheck() async -> InsightProviderHealth {
        if let localServer {
            do {
                try await localServer.start()
            } catch {
                return .unavailable("llama.cpp could not be started")
            }
        }
        guard let health = URL(string: "health", relativeTo: normalizedBaseURL),
              let props = URL(string: "props", relativeTo: normalizedBaseURL) else {
            return .unavailable("Invalid local endpoint")
        }
        do {
            let (_, response) = try await httpClient.data(for: authorized(health))
            guard (200..<300).contains(response.statusCode) else {
                return .unavailable("llama.cpp is not ready")
            }
        } catch {
            return .unavailable("llama.cpp is not running")
        }

        // A 2xx on /health is not identity. Anything can answer 200 on
        // 127.0.0.1:8080, and most dev servers do. Before a transcript moves,
        // the responder has to name the model file we expect. A user who
        // pointed Hushnote at a server they run themselves has no model file
        // for us to expect, so there is nothing to check.
        guard let expected = expectedModelURL else { return .available }
        do {
            let (data, response) = try await httpClient.data(for: authorized(props))
            guard (200..<300).contains(response.statusCode),
                  LocalLlamaServer.identifiesOurModel(data, modelURL: expected) else {
                return .unavailable(
                    "Something else is listening on that port. Hushnote will not send a transcript to it."
                )
            }
        } catch {
            return .unavailable("llama.cpp did not identify itself.")
        }
        return .available
    }

    private func authorized(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 2
        if let apiKey { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        return request
    }

    public func shutdown() async {
        await localServer?.stop()
    }

    public func complete(_ request: InsightProviderRequest) async throws -> String {
        guard case .available = await healthCheck() else {
            throw InsightProviderError.localServiceUnavailable
        }
        guard let url = URL(string: "v1/chat/completions", relativeTo: normalizedBaseURL) else {
            throw InsightProviderError.invalidConfiguration("Invalid llama.cpp endpoint")
        }
        let body = LlamaCppRequest(
            model: model,
            messages: [
                .init(role: "system", content: request.systemPrompt),
                .init(role: "user", content: request.userPrompt)
            ],
            temperature: 0,
            stream: false,
            responseFormat: .init(type: "json_schema", jsonSchema: .init(
                name: request.outputSchemaName,
                strict: true,
                schema: request.outputSchema
            ))
        )
        let data = try JSONEncoder().encode(body)
        let headers = apiKey.map { ["Authorization": "Bearer \($0)"] } ?? [:]
        let urlRequest = ProviderHTTP.request(url: url, headers: headers, body: data)
        let (responseData, response) = try await httpClient.data(for: urlRequest)
        try ProviderHTTP.requireSuccess(response)
        guard let decoded = try? JSONDecoder().decode(LlamaCppResponse.self, from: responseData),
              let content = decoded.choices.first?.message.content else {
            throw InsightProviderError.malformedResponse
        }
        return content
    }

    private var normalizedBaseURL: URL {
        baseURL.absoluteString.hasSuffix("/")
            ? baseURL
            : URL(string: baseURL.absoluteString + "/")!
    }
}

private struct LlamaCppRequest: Encodable {
    let model: String?
    let messages: [Message]
    let temperature: Double
    let stream: Bool
    let responseFormat: ResponseFormat

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature, stream
        case responseFormat = "response_format"
    }

    struct Message: Encodable {
        let role: String
        let content: String
    }

    struct ResponseFormat: Encodable {
        let type: String
        let jsonSchema: Schema

        enum CodingKeys: String, CodingKey {
            case type
            case jsonSchema = "json_schema"
        }
    }

    struct Schema: Encodable {
        let name: String
        let strict: Bool
        let schema: JSONValue
    }
}

private struct LlamaCppResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: Message
    }

    struct Message: Decodable {
        let content: String
    }
}
