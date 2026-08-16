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

    public init(
        model: String? = nil,
        baseURL: URL = URL(string: "http://127.0.0.1:8080")!,
        httpClient: any HTTPClient = URLSessionHTTPClient(),
        localServer: LocalLlamaServer? = nil
    ) throws {
        guard baseURL.scheme == "http",
              let host = baseURL.host,
              ["127.0.0.1", "::1", "localhost"].contains(host.lowercased()) else {
            throw InsightProviderError.invalidConfiguration(
                "The llama.cpp endpoint must use HTTP on localhost."
            )
        }
        self.model = model
        self.baseURL = baseURL
        self.httpClient = httpClient
        self.localServer = localServer
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
            localServer: localServer
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
        guard let url = URL(string: "health", relativeTo: normalizedBaseURL) else {
            return .unavailable("Invalid local endpoint")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 2
        do {
            let (_, response) = try await httpClient.data(for: request)
            return (200..<300).contains(response.statusCode)
                ? .available
                : .unavailable("llama.cpp is not ready")
        } catch {
            return .unavailable("llama.cpp is not running")
        }
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
        let urlRequest = ProviderHTTP.request(url: url, headers: [:], body: data)
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
