import Foundation

public struct InsightProviderDescriptor: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case openAI
        case anthropic
        case llamaCpp
        case codexAppServer
    }

    public let id: String
    public let displayName: String
    public let kind: Kind
    public let sendsTranscriptOffDevice: Bool

    public init(id: String, displayName: String, kind: Kind, sendsTranscriptOffDevice: Bool) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.sendsTranscriptOffDevice = sendsTranscriptOffDevice
    }
}

public enum InsightProviderHealth: Equatable, Sendable {
    case available
    case unavailable(String)
}

public enum InsightRequestPurpose: String, Codable, Sendable {
    case chunkExtraction
    case synthesis
    case questionAnswer
}

/// A deliberately text-only provider request. Audio data has no representation in this API.
public struct InsightProviderRequest: Equatable, Sendable {
    public let purpose: InsightRequestPurpose
    public let systemPrompt: String
    public let userPrompt: String
    public let outputSchemaName: String
    public let outputSchema: JSONValue

    public init(
        purpose: InsightRequestPurpose,
        systemPrompt: String,
        userPrompt: String,
        outputSchemaName: String,
        outputSchema: JSONValue
    ) {
        self.purpose = purpose
        self.systemPrompt = systemPrompt
        self.userPrompt = userPrompt
        self.outputSchemaName = outputSchemaName
        self.outputSchema = outputSchema
    }
}

public protocol InsightProvider: Sendable {
    var descriptor: InsightProviderDescriptor { get }
    func healthCheck() async -> InsightProviderHealth
    func complete(_ request: InsightProviderRequest) async throws -> String
}

public enum InsightProviderError: Error, Equatable, LocalizedError, Sendable {
    case missingCredential(String)
    case invalidConfiguration(String)
    case transportFailure
    case rejected(statusCode: Int)
    case malformedResponse
    case localServiceUnavailable
    case rpcError(code: Int, message: String)
    case processExited(Int32)

    public var errorDescription: String? {
        switch self {
        case .missingCredential(let name): "Missing credential for \(name)."
        case .invalidConfiguration(let reason): "Invalid provider configuration: \(reason)"
        case .transportFailure: "The provider request could not be completed."
        case .rejected(let statusCode): "The provider rejected the request (HTTP \(statusCode))."
        case .malformedResponse: "The provider returned a malformed response."
        case .localServiceUnavailable: "The selected local model service is unavailable."
        case .rpcError(_, let message): "Codex App Server error: \(message)"
        case .processExited(let status): "Codex App Server exited with status \(status)."
        }
    }
}

