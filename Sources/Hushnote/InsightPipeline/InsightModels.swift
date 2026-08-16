import Foundation

public struct InsightTranscriptSegment: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let startMilliseconds: Int64
    public let endMilliseconds: Int64
    public let speaker: String?
    public let text: String

    public init(
        id: String,
        startMilliseconds: Int64,
        endMilliseconds: Int64,
        speaker: String? = nil,
        text: String
    ) {
        self.id = id
        self.startMilliseconds = startMilliseconds
        self.endMilliseconds = endMilliseconds
        self.speaker = speaker
        self.text = text
    }
}

public struct EvidenceCitation: Codable, Equatable, Sendable {
    public let segmentID: String
    public let startMilliseconds: Int64
    public let endMilliseconds: Int64
    public let quote: String

    public init(
        segmentID: String,
        startMilliseconds: Int64,
        endMilliseconds: Int64,
        quote: String
    ) {
        self.segmentID = segmentID
        self.startMilliseconds = startMilliseconds
        self.endMilliseconds = endMilliseconds
        self.quote = quote
    }
}

public struct CitedInsight: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let text: String
    public let citations: [EvidenceCitation]

    public init(id: String, text: String, citations: [EvidenceCitation]) {
        self.id = id
        self.text = text
        self.citations = citations
    }
}

public struct ActionItemInsight: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let text: String
    public let owner: String?
    public let dueDate: String?
    public let citations: [EvidenceCitation]

    public init(
        id: String,
        text: String,
        owner: String? = nil,
        dueDate: String? = nil,
        citations: [EvidenceCitation]
    ) {
        self.id = id
        self.text = text
        self.owner = owner
        self.dueDate = dueDate
        self.citations = citations
    }
}

public struct MeetingInsights: Codable, Equatable, Sendable {
    public let overview: CitedInsight
    public let keyPoints: [CitedInsight]
    public let decisions: [CitedInsight]
    public let actionItems: [ActionItemInsight]
    public let openQuestions: [CitedInsight]
    public let risks: [CitedInsight]
    public let topics: [CitedInsight]

    public init(
        overview: CitedInsight,
        keyPoints: [CitedInsight] = [],
        decisions: [CitedInsight] = [],
        actionItems: [ActionItemInsight] = [],
        openQuestions: [CitedInsight] = [],
        risks: [CitedInsight] = [],
        topics: [CitedInsight] = []
    ) {
        self.overview = overview
        self.keyPoints = keyPoints
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
        self.risks = risks
        self.topics = topics
    }
}

public struct MeetingQuestionAnswer: Codable, Equatable, Sendable {
    public let question: String
    public let answer: String
    public let citations: [EvidenceCitation]

    public init(question: String, answer: String, citations: [EvidenceCitation]) {
        self.question = question
        self.answer = answer
        self.citations = citations
    }
}

public struct InsightValidationReport: Codable, Equatable, Sendable {
    public let rejectedClaims: Int
    public let rejectedCitations: Int

    public init(rejectedClaims: Int = 0, rejectedCitations: Int = 0) {
        self.rejectedClaims = rejectedClaims
        self.rejectedCitations = rejectedCitations
    }
}

public struct ValidatedMeetingInsights: Codable, Equatable, Sendable {
    public let insights: MeetingInsights
    public let validation: InsightValidationReport

    public init(insights: MeetingInsights, validation: InsightValidationReport) {
        self.insights = insights
        self.validation = validation
    }
}

public struct ValidatedQuestionAnswer: Codable, Equatable, Sendable {
    public let answer: MeetingQuestionAnswer
    public let validation: InsightValidationReport

    public init(answer: MeetingQuestionAnswer, validation: InsightValidationReport) {
        self.answer = answer
        self.validation = validation
    }
}

