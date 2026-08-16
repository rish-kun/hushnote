import Foundation
import Testing
@testable import Hushnote

@Suite("Speech model catalog")
struct ModelCatalogTests {
    @Test("Catalog identifiers are unique and round-trip through lookup")
    func identifiersAreUniqueAndDiscoverable() {
        let models = SpeechModelCatalog.all

        #expect(Set(models.map(\.id)).count == models.count)
        #expect(models.allSatisfy { SpeechModelCatalog.model(id: $0.id) == $0 })
        #expect(SpeechModelCatalog.model(id: "missing") == nil)
    }

    @Test("Quality defaults match the prototype policy")
    func defaultsMatchPolicy() {
        #expect(SpeechModelCatalog.recommended == SpeechModelCatalog.whisperLargeV3Turbo)
        #expect(SpeechModelCatalog.whisperLargeV3Turbo.runtimeIdentifier.contains("turbo"))
        #expect(SpeechModelCatalog.whisperLargeV3.tier == .accurate)
        #expect(SpeechModelCatalog.all.allSatisfy { $0.isMultilingual })
        #expect(SpeechModelCatalog.all.allSatisfy { $0.approximateDownloadBytes > 0 })
        #expect(SpeechModelCatalog.all.allSatisfy { $0.minimumMemoryBytes > 0 })
    }

    @Test("Manifest metadata survives Codable persistence")
    func codableRoundTrip() throws {
        let encoded = try JSONEncoder().encode(SpeechModelCatalog.whisperLargeV3)
        let decoded = try JSONDecoder().decode(SpeechModel.self, from: encoded)

        #expect(decoded == SpeechModelCatalog.whisperLargeV3)
        #expect(decoded.licenseName == "MIT")
    }

    @Test("Export formats expose stable file extensions")
    func exportExtensions() {
        #expect(MeetingExportFormat.markdown.fileExtension == "md")
        #expect(MeetingExportFormat.srt.fileExtension == "srt")
        #expect(MeetingExportFormat.json.fileExtension == "json")
    }
}
