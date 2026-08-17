import Foundation
import Testing
@testable import Hushnote

@Suite("Insight pipeline")
struct InsightPipelineTests {
    @Test("Chunking is deterministic and overlaps whole segments")
    func chunksTranscriptWithOverlap() {
        let transcript = [
            segment("s1", text: "one"),
            segment("s2", text: "two"),
            segment("s3", text: "three")
        ]
        let chunks = TranscriptChunker(maximumCharacters: 200, overlapSegments: 1)
            .chunks(for: transcript)

        #expect(chunks.map { $0.segments.map(\.id) } == [["s1", "s2"], ["s2", "s3"]])
    }

    @Test("Citation validation rejects fabricated evidence and keeps the segment's own timestamps")
    func validatesCitationsLocally() throws {
        let transcript = [segment("s1", start: 1_000, end: 2_000, text: "Ship the beta on Friday.")]
        let validCitation = EvidenceCitation(
            segmentID: "s1",
            startMilliseconds: 1_000,
            endMilliseconds: 2_000,
            quote: "beta on Friday"
        )
        let invalidCitation = EvidenceCitation(
            segmentID: "s1",
            startMilliseconds: 1_000,
            endMilliseconds: 2_000,
            quote: "release on Monday"
        )
        let draft = MeetingInsights(
            overview: CitedInsight(id: "overview", text: "The beta ships on Friday.", citations: [validCitation]),
            keyPoints: [CitedInsight(id: "made-up", text: "Monday release", citations: [invalidCitation])]
        )

        let result = try #require(CitationValidator().validate(draft, against: transcript))

        #expect(result.insights.overview.citations[0].startMilliseconds == 1_000)
        #expect(result.insights.overview.citations[0].endMilliseconds == 2_000)
        #expect(result.insights.keyPoints.isEmpty)
        #expect(result.validation.rejectedClaims == 1)
        #expect(result.validation.rejectedCitations == 1)
    }

    @Test("Pipeline validates before synthesis and validates synthesized output again")
    func performsTwoCitationPasses() async throws {
        let transcript = [segment("s1", text: "Priya will ship the beta on Friday.")]
        let citation = EvidenceCitation(
            segmentID: "s1",
            startMilliseconds: 0,
            endMilliseconds: 1_000,
            quote: "ship the beta on Friday"
        )
        let fabricated = EvidenceCitation(
            segmentID: "s1",
            startMilliseconds: 0,
            endMilliseconds: 1_000,
            quote: "budget was approved"
        )
        let extraction = MeetingInsights(
            overview: CitedInsight(id: "overview", text: "The beta was scheduled.", citations: [citation]),
            keyPoints: [CitedInsight(id: "fabricated", text: "Unsupported extraction claim", citations: [fabricated])]
        )
        let synthesis = MeetingInsights(
            overview: CitedInsight(id: "overview", text: "The beta was scheduled.", citations: [citation]),
            actionItems: [ActionItemInsight(id: "action", text: "Priya will ship the beta.", owner: "Priya", dueDate: "Friday", citations: [citation])],
            risks: [CitedInsight(id: "fabricated-final", text: "An unsupported final claim", citations: [fabricated])]
        )
        let provider = ScriptedInsightProvider(responses: [try json(extraction), try json(synthesis)])
        let pipeline = InsightPipeline(
            provider: provider,
            chunker: TranscriptChunker(maximumCharacters: 1_000, overlapSegments: 0)
        )

        let result = try await pipeline.generateInsights(transcript: transcript)
        let requests = await provider.recordedRequests()

        #expect(requests.map(\.purpose) == [.chunkExtraction, .synthesis])
        #expect(!requests[1].userPrompt.contains("Unsupported extraction claim"))
        #expect(result.insights.actionItems.map(\.owner) == ["Priya"])
        #expect(result.insights.risks.isEmpty)
        #expect(result.validation.rejectedClaims == 1)
        #expect(result.validation.rejectedCitations == 1)
    }

    @Test("Provider errors propagate without selecting another provider")
    func doesNotSilentlyFallback() async throws {
        let provider = ScriptedInsightProvider(
            responses: [],
            failure: .rejected(statusCode: 429)
        )
        let pipeline = InsightPipeline(provider: provider)

        await #expect(throws: InsightProviderError.rejected(statusCode: 429)) {
            _ = try await pipeline.generateInsights(transcript: [segment("s1", text: "Hello")])
        }
        let requestCount = await provider.recordedRequests().count
        #expect(requestCount == 1)
    }

    @Test("OpenAI Responses disables storage and sends only text JSON")
    func createsPrivateOpenAIRequest() async throws {
        let credentials = MemoryCredentialStore(values: [.openAIAPIKey: "openai-secret"])
        let http = RecordingHTTPClient(plans: [
            .init(status: 200, body: #"{"output_text":"{}"}"#)
        ])
        let provider = OpenAIInsightProvider(
            model: "test-model",
            credentials: credentials,
            httpClient: http
        )

        let output = try await provider.complete(providerRequest())
        let requests = await http.recordedRequests()
        let request = try #require(requests.first)
        let bodyData = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])

        #expect(output == "{}")
        #expect(body["store"] as? Bool == false)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer openai-secret")
        #expect(!String(decoding: bodyData, as: UTF8.self).lowercased().contains("audio"))
    }

    @Test("Anthropic Messages uses an API key and structured output")
    func createsAnthropicRequest() async throws {
        let credentials = MemoryCredentialStore(values: [.anthropicAPIKey: "anthropic-secret"])
        let http = RecordingHTTPClient(plans: [
            .init(status: 200, body: #"{"content":[{"type":"text","text":"{}"}]}"#)
        ])
        let provider = AnthropicInsightProvider(
            model: "test-model",
            credentials: credentials,
            httpClient: http
        )

        let output = try await provider.complete(providerRequest())
        let requests = await http.recordedRequests()
        let request = try #require(requests.first)
        let bodyData = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        let outputConfig = try #require(body["output_config"] as? [String: Any])
        let format = try #require(outputConfig["format"] as? [String: Any])

        #expect(output == "{}")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "anthropic-secret")
        #expect(format["type"] as? String == "json_schema")
    }

    @Test("llama.cpp is restricted to loopback and checked before completion")
    func checksLocalLlamaServer() async throws {
        #expect(throws: InsightProviderError.self) {
            _ = try LlamaCppInsightProvider(baseURL: URL(string: "https://example.com")!)
        }

        let http = RecordingHTTPClient(plans: [
            .init(status: 200, body: "{}"),
            .init(status: 200, body: #"{"choices":[{"message":{"content":"{}"}}]}"#)
        ])
        let provider = try LlamaCppInsightProvider(httpClient: http)
        let output = try await provider.complete(providerRequest())
        let requests = await http.recordedRequests()

        #expect(output == "{}")
        #expect(requests.map(\.httpMethod) == ["GET", "POST"])
        #expect(requests.map { $0.url?.path } == ["/health", "/v1/chat/completions"])
    }

    @Test("Local llama server configuration forces loopback and direct model arguments")
    func configuresLocalLlamaServerSafely() throws {
        let configuration = try LocalLlamaServer.Configuration(
            executableURL: URL(fileURLWithPath: "/opt/hushnote/bin/llama-server"),
            modelURL: URL(fileURLWithPath: "/Users/example/My Model.gguf"),
            port: 18_080
        )

        #expect(configuration.launchArguments == [
            "--host", "127.0.0.1",
            "--port", "18080",
            "-m", "/Users/example/My Model.gguf"
        ])
        #expect(throws: InsightProviderError.self) {
            _ = try LocalLlamaServer.Configuration(
                executableURL: URL(fileURLWithPath: "/tmp/llama-server"),
                modelURL: URL(fileURLWithPath: "/tmp/model.gguf"),
                port: 0
            )
        }
    }

    @Test("Codex App Server uses ephemeral read-only turns with an output schema")
    func usesCodexAppServerProtocol() async throws {
        let transport = MockCodexTransport()
        let provider = CodexAppServerInsightProvider(transport: transport)

        let output = try await provider.complete(providerRequest())
        let health = await provider.healthCheck()
        let messages = await transport.sentMessages()
        let threadStart = try #require(messages.first { $0["method"]?.stringValue == "thread/start" })
        let turnStart = try #require(messages.first { $0["method"]?.stringValue == "turn/start" })

        #expect(output == #"{"answer":"ok"}"#)
        #expect(health == .unavailable("ChatGPT account not connected"))
        #expect(threadStart["params"]?["ephemeral"] == .bool(true))
        #expect(threadStart["params"]?["sandbox"] == .string("read-only"))
        #expect(turnStart["params"]?["sandboxPolicy"]?["type"] == .string("readOnly"))
        #expect(turnStart["params"]?["outputSchema"] == providerRequest().outputSchema)
    }

    @Test("MeetingCore snapshots bridge without audio data")
    func bridgesTranscriptSnapshot() {
        let meetingID = UUID()
        let snapshot = TranscriptSnapshot(
            meetingID: meetingID,
            revision: 1,
            segments: [TranscriptSegment(
                id: "s1",
                meetingID: meetingID,
                source: .microphone,
                startMilliseconds: 0,
                endMilliseconds: 500,
                text: "Hello",
                speakerID: "speaker-1",
                speakerName: "Ava",
                stability: .final
            )]
        )

        #expect(snapshot.insightSegments == [segment("s1", end: 500, speaker: "Ava", text: "Hello")])
    }

    @Test("Oversized transcript segments split without losing text")
    func splitsOversizedSegments() {
        let original = "alpha beta gamma delta epsilon zeta eta theta"
        let chunks = TranscriptChunker(maximumCharacters: 110, overlapSegments: 0)
            .chunks(for: [segment("long", text: original)])
        let pieces = chunks.flatMap(\.segments)

        #expect(pieces.count > 1)
        #expect(pieces.allSatisfy { $0.id == "long" })
        #expect(pieces.map(\.text).joined(separator: " ") == original)
    }

    @Test("Pipeline normalizes ordering, whitespace, and invalid segments before prompting")
    func normalizesTranscriptBeforeProviderCalls() async throws {
        let earlier = segment("earlier", start: 0, end: 500, text: "  First point.  ")
        let later = segment("later", start: 500, end: 1_000, text: "Second point.")
        let citation = EvidenceCitation(
            segmentID: "earlier",
            startMilliseconds: 0,
            endMilliseconds: 500,
            quote: "First point"
        )
        let insights = MeetingInsights(
            overview: CitedInsight(id: "overview", text: "First", citations: [citation])
        )
        let provider = ScriptedInsightProvider(responses: [try json(insights), try json(insights)])
        let pipeline = InsightPipeline(
            provider: provider,
            chunker: TranscriptChunker(maximumCharacters: 1_000, overlapSegments: 0)
        )

        _ = try await pipeline.generateInsights(transcript: [
            later,
            segment("blank", start: 200, end: 300, text: " \n "),
            segment("backwards", start: 800, end: 700, text: "invalid"),
            earlier,
        ])
        let requests = await provider.recordedRequests()
        let extractionPrompt = try #require(requests.first?.userPrompt)
        let firstRange = try #require(extractionPrompt.range(of: "First point"))
        let secondRange = try #require(extractionPrompt.range(of: "Second point"))

        #expect(firstRange.lowerBound < secondRange.lowerBound)
        #expect(!extractionPrompt.contains("backwards"))
        #expect(!extractionPrompt.contains("\"blank\""))
        #expect(!extractionPrompt.contains("  First point.  "))
    }

    @Test("Question answering accepts fenced JSON and rejects unsupported citations")
    func validatesQuestionAnswers() async throws {
        let transcript = [segment("s1", start: 100, end: 500, text: "The launch is Friday.")]
        let validAnswer = MeetingQuestionAnswer(
            question: "When is launch?",
            answer: "Friday.",
            citations: [EvidenceCitation(
                segmentID: "s1",
                startMilliseconds: 100,
                endMilliseconds: 500,
                quote: "launch is Friday"
            )]
        )
        let fenced = "```json\n\(try json(validAnswer))\n```"
        let validProvider = ScriptedInsightProvider(responses: [fenced])

        let validated = try await InsightPipeline(provider: validProvider)
            .answer(question: "When is launch?", transcript: transcript)

        #expect(validated.answer.citations[0].startMilliseconds == 100)
        #expect(validated.answer.citations[0].endMilliseconds == 500)

        let invalidAnswer = MeetingQuestionAnswer(
            question: "What budget?",
            answer: "A million dollars.",
            citations: [EvidenceCitation(
                segmentID: "s1",
                startMilliseconds: 100,
                endMilliseconds: 500,
                quote: "million dollars"
            )]
        )
        let invalidProvider = ScriptedInsightProvider(responses: [try json(invalidAnswer)])
        await #expect(throws: InsightPipelineError.unsupportedCitations) {
            _ = try await InsightPipeline(provider: invalidProvider)
                .answer(question: "What budget?", transcript: transcript)
        }
    }

    @Test("Whitespace-only transcripts fail before contacting a provider")
    func rejectsEmptyTranscriptLocally() async {
        let provider = ScriptedInsightProvider(responses: [])
        await #expect(throws: InsightPipelineError.emptyTranscript) {
            _ = try await InsightPipeline(provider: provider)
                .generateInsights(transcript: [segment("blank", text: " \n ")])
        }

        #expect(await provider.recordedRequests().isEmpty)
    }
}

private func segment(
    _ id: String,
    start: Int64 = 0,
    end: Int64 = 1_000,
    speaker: String? = nil,
    text: String
) -> InsightTranscriptSegment {
    InsightTranscriptSegment(
        id: id,
        startMilliseconds: start,
        endMilliseconds: end,
        speaker: speaker,
        text: text
    )
}

private func json<T: Encodable>(_ value: T) throws -> String {
    String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
}

private func providerRequest() -> InsightProviderRequest {
    InsightProviderRequest(
        purpose: .questionAnswer,
        systemPrompt: "Return JSON.",
        userPrompt: "Transcript text.",
        outputSchemaName: "test_output",
        outputSchema: .object([
            "type": .string("object"),
            "additionalProperties": .bool(false)
        ])
    )
}

private actor ScriptedInsightProvider: InsightProvider {
    nonisolated let descriptor = InsightProviderDescriptor(
        id: "scripted",
        displayName: "Scripted",
        kind: .llamaCpp,
        sendsTranscriptOffDevice: false
    )

    private var responses: [String]
    private let failure: InsightProviderError?
    private var requests: [InsightProviderRequest] = []

    init(responses: [String], failure: InsightProviderError? = nil) {
        self.responses = responses
        self.failure = failure
    }

    func healthCheck() async -> InsightProviderHealth { .available }

    func complete(_ request: InsightProviderRequest) async throws -> String {
        requests.append(request)
        if let failure { throw failure }
        guard !responses.isEmpty else { throw InsightProviderError.malformedResponse }
        return responses.removeFirst()
    }

    func recordedRequests() -> [InsightProviderRequest] { requests }
}

private actor MemoryCredentialStore: CredentialStore {
    private var values: [ProviderCredential: String]

    init(values: [ProviderCredential: String] = [:]) {
        self.values = values
    }

    func setCredential(_ credential: String, for key: ProviderCredential) async throws {
        values[key] = credential
    }

    func credential(for key: ProviderCredential) async throws -> String? {
        values[key]
    }

    func removeCredential(for key: ProviderCredential) async throws {
        values[key] = nil
    }
}

private actor RecordingHTTPClient: HTTPClient {
    struct Plan: Sendable {
        let status: Int
        let body: String
    }

    private var plans: [Plan]
    private var requests: [URLRequest] = []

    init(plans: [Plan]) {
        self.plans = plans
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !plans.isEmpty,
              let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: plans[0].status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
              ) else {
            throw InsightProviderError.transportFailure
        }
        let plan = plans.removeFirst()
        return (Data(plan.body.utf8), response)
    }

    func recordedRequests() -> [URLRequest] { requests }
}

private actor MockCodexTransport: CodexAppServerTransport {
    private let stream: AsyncThrowingStream<JSONValue, Error>
    private let continuation: AsyncThrowingStream<JSONValue, Error>.Continuation
    private var sent: [JSONValue] = []

    init() {
        var captured: AsyncThrowingStream<JSONValue, Error>.Continuation?
        stream = AsyncThrowingStream { captured = $0 }
        continuation = captured!
    }

    func start() async throws {}

    func send(_ message: JSONValue) async throws {
        sent.append(message)
        guard let method = message["method"]?.stringValue else { return }
        switch method {
        case "initialize":
            respond(to: message, result: .object([:]))
        case "thread/start":
            respond(to: message, result: .object([
                "thread": .object(["id": .string("thread-1")])
            ]))
        case "account/read":
            respond(to: message, result: .object(["account": .null]))
        case "turn/start":
            respond(to: message, result: .object([
                "turn": .object(["id": .string("turn-1")])
            ]))
            continuation.yield(.object([
                "method": .string("item/completed"),
                "params": .object([
                    "item": .object([
                        "type": .string("agentMessage"),
                        "text": .string(#"{"answer":"ok"}"#)
                    ])
                ])
            ]))
            continuation.yield(.object([
                "method": .string("turn/completed"),
                "params": .object(["turn": .object([
                    "id": .string("turn-1"),
                    "status": .string("completed")
                ])])
            ]))
        default:
            break
        }
    }

    func messages() async -> AsyncThrowingStream<JSONValue, Error> { stream }

    func stop() async {
        continuation.finish()
    }

    func sentMessages() -> [JSONValue] { sent }

    private func respond(to message: JSONValue, result: JSONValue) {
        guard let id = message["id"] else { return }
        continuation.yield(.object(["id": id, "result": result]))
    }
}
