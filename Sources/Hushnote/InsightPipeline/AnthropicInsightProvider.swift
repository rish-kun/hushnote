import Foundation

public struct AnthropicInsightProvider: InsightProvider {
    public let descriptor = InsightProviderDescriptor(
        id: "anthropic",
        displayName: "Anthropic API",
        kind: .anthropic,
        sendsTranscriptOffDevice: true
    )

    private let model: String
    private let maximumOutputTokens: Int
    private let endpoint: URL
    private let credentials: any CredentialStore
    private let httpClient: any HTTPClient

    public init(
        model: String,
        maximumOutputTokens: Int = 4_096,
        endpoint: URL = URL(string: "https://api.anthropic.com/v1/messages")!,
        credentials: any CredentialStore,
        httpClient: any HTTPClient = URLSessionHTTPClient()
    ) {
        self.model = model
        self.maximumOutputTokens = maximumOutputTokens
        self.endpoint = endpoint
        self.credentials = credentials
        self.httpClient = httpClient
    }

    public func healthCheck() async -> InsightProviderHealth {
        do {
            return try await credentials.credential(for: .anthropicAPIKey) == nil
                ? .unavailable("API key not configured")
                : .available
        } catch {
            return .unavailable("Credential store unavailable")
        }
    }

    public func complete(_ request: InsightProviderRequest) async throws -> String {
        guard let apiKey = try await credentials.credential(for: .anthropicAPIKey), !apiKey.isEmpty else {
            throw InsightProviderError.missingCredential("Anthropic")
        }
        let body = AnthropicRequest(
            model: model,
            maxTokens: maximumOutputTokens,
            system: request.systemPrompt,
            messages: [.init(role: "user", content: request.userPrompt)],
            outputConfig: .init(format: .init(type: "json_schema", schema: request.outputSchema))
        )
        let data = try JSONEncoder().encode(body)
        let urlRequest = ProviderHTTP.request(
            url: endpoint,
            headers: [
                "x-api-key": apiKey,
                "anthropic-version": "2023-06-01"
            ],
            body: data
        )
        let (responseData, response) = try await httpClient.data(for: urlRequest)
        try ProviderHTTP.requireSuccess(response)
        guard let decoded = try? JSONDecoder().decode(AnthropicResponse.self, from: responseData),
              let text = decoded.content.first(where: { $0.type == "text" })?.text else {
            throw InsightProviderError.malformedResponse
        }
        return text
    }
}

private struct AnthropicRequest: Encodable {
    let model: String
    let maxTokens: Int
    let system: String
    let messages: [Message]
    let outputConfig: OutputConfiguration

    enum CodingKeys: String, CodingKey {
        case model, system, messages
        case maxTokens = "max_tokens"
        case outputConfig = "output_config"
    }

    struct Message: Encodable {
        let role: String
        let content: String
    }

    struct OutputConfiguration: Encodable {
        let format: Format
    }

    struct Format: Encodable {
        let type: String
        let schema: JSONValue
    }
}

private struct AnthropicResponse: Decodable {
    let content: [Content]

    struct Content: Decodable {
        let type: String
        let text: String?
    }
}

