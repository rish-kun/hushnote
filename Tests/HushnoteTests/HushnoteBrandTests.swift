import AppKit
import Testing
@testable import Hushnote

@Suite("Hushnote brand")
struct HushnoteBrandTests {
    @Test("The shared mark stays inside its requested square")
    func normalizedGeometry() {
        let target = CGRect(x: 17, y: 23, width: 240, height: 240)
        let bounds = HushnoteBrandGeometry.path(in: target).boundingBoxOfPath

        #expect(target.contains(bounds))
        #expect(bounds.width > target.width * 0.7)
        #expect(bounds.height > target.height * 0.7)
    }

    @Test("Menu bar images are true template images")
    func templateImages() {
        let idle = HushnoteBrandImages.menuBarTemplate(isRecording: false)
        let recording = HushnoteBrandImages.menuBarTemplate(isRecording: true)

        #expect(idle.isTemplate)
        #expect(recording.isTemplate)
        #expect(idle.size == CGSize(width: 18, height: 18))
        #expect(recording.accessibilityDescription == "Hushnote is recording")
    }

    @Test("About uses semantic version and build wording")
    func buildLabel() {
        #expect(HushnoteBuildInfo.versionLabel(shortVersion: "1.4", build: "82") == "Version 1.4 (82)")
    }
}
