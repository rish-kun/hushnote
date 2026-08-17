import Foundation
import Testing
@testable import Hushnote

/// A provider nobody can select is not a feature. This is the registration:
/// every tool has a way to be chosen, and choosing it reaches that tool.
@Suite("Agent CLI settings")
struct AgentCLISettingsTests {
    @Test("Every CLI tool is selectable, and every selection reaches one tool")
    func registersEveryTool() {
        let mapped = InsightProviderChoice.allCases.compactMap(\.agentCLITool)

        #expect(Set(mapped) == Set(AgentCLITool.allCases))
        #expect(mapped.count == AgentCLITool.allCases.count)
    }

    @Test("The existing choices are not quietly turned into CLI providers")
    func leavesExistingChoicesAlone() {
        for choice in [InsightProviderChoice.local, .openAI, .anthropic, .chatGPT] {
            #expect(choice.agentCLITool == nil)
        }
        #expect(InsightProviderChoice.local.isLocal)
        #expect(!InsightProviderChoice.claudeCLI.isLocal)
    }

    @Test("A CLI provider says the transcript leaves the device")
    func declaresOffDevice() {
        for choice in InsightProviderChoice.allCases {
            guard let tool = choice.agentCLITool else { continue }
            #expect(tool.descriptor.sendsTranscriptOffDevice)
        }
    }
}
