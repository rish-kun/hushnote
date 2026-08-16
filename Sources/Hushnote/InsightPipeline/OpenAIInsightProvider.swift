import Foundation

public struct OpenAIInsightProvider: InsightProvider {
    public let descriptor = InsightProviderDescriptor(
        id: "openai",
        displayName: "OpenAI API",
        kind: .openAI,
        sendsTranscriptOffDevice: true
    )

    private let model: String
    private let endpoint: URL
    private let credentials: any CredentialStore
    private let httpClient: any HTTPClient

    public init(
        model: String,
        endpoint: URL = URL(string: "https://api.openai.com/v1/responses")!,
        credentials: any CredentialStore,
        httpClient: any HTTPClient = URLSessionHTTPClient()
    ) {
        self.model = model
        self.endpoint = endpoint
        self.credentials = credentials
        self.httpClient = httpClient
    }

    public func healthCheck() async -> InsightProviderHealth {
        do {
            return try await credentials.credential(for: .openAIAPIKey) == nil
                ? .unavailable("API key not configured")
                : .available
        } catch {
            return .unavailable("Credential store unavailable")
        }
    }

    public func complete(_ request: InsightProviderRequest) async throws -> String {
        guard let apiKey = try await credentials.credential(for: .openAIAPIKey), !apiKey.isEmpty else {
            throw InsightProviderError.missingCredential("OpenAI")
        }
        let body = OpenAIRequest(
            model: model,
            instructions: request.systemPrompt,
            input: request.userPrompt,
            store: false,
            text: .init(format: .init(
                type: "json_schema",
                name: request.outputSchemaName,
                strict: true,
                schema: request.outputSchema
            ))
        )
        let data = try JSONEncoder().encode(body)
        let urlRequest = ProviderHTTP.request(
            url: endpoint,
            headers: ["Authorization": "Bearer \(apiKey)"],
            body: data
        )
        let (responseData, response) = try await httpClient.data(for: urlRequest)
        try ProviderHTTP.requireSuccess(response)
        guard let decoded = try? JSONDecoder().decode(OpenAIResponse.self, from: responseData) else {
            throw InsightProviderError.malformedResponse
        }
        let contentText = decoded.output?
            .flatMap { $0.content ?? [] }
            .compactMap { $0.text }
            .first
        guard let text = decoded.outputText ?? contentText else {
            throw InsightProviderError.malformedResponse
        }
        return text
    }
}

private struct OpenAIRequest: Encodable {
    let model: String
    let instructions: String
    let input: String
    let store: Bool
    let text: TextConfiguration

    struct TextConfiguration: Encodable {
        let format: Format
    }

    struct Format: Encodable {
        let type: String
        let name: String
        let strict: Bool
        let schema: JSONValue
    }
}

private struct OpenAIResponse: Decodable {
    let outputText: String?
    let output: [Output]?

    enum CodingKeys: String, CodingKey {
        case outputText = "output_text"
        case output
    }

    struct Output: Decodable {
        let content: [Content]?
    }

    struct Content: Decodable {
        let text: String?
    }
}
