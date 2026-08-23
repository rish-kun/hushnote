import Foundation
import Testing
import WhisperKit
@testable import Hushnote

/// WhisperKit's own macOS default is 16 workers, which is a throughput choice
/// made for machines with memory to spare. These pin the count Hushnote asks
/// for instead.
@Suite("The final pass sizes its decode concurrency to the machine")
struct FinalDecodeConcurrencyTests {
    @Test("A 16 GB machine decodes with a handful of workers, not sixteen")
    func sixteenGigabytesGetsAHandful() {
        #expect(FinalDecodeConcurrency.workerCount(physicalMemory: 16 << 30) == 2)
    }

    @Test("A machine too small to budget a worker still gets one")
    func smallMachinesNeverStall() {
        #expect(FinalDecodeConcurrency.workerCount(physicalMemory: 4 << 30) == 1)
        #expect(FinalDecodeConcurrency.workerCount(physicalMemory: 0) == 1)
    }

    @Test("Memory beyond the first machine's buys more workers")
    func largerMachinesDecodeWider() {
        #expect(FinalDecodeConcurrency.workerCount(physicalMemory: 24 << 30) == 3)
        #expect(FinalDecodeConcurrency.workerCount(physicalMemory: 32 << 30) == 4)
        #expect(FinalDecodeConcurrency.workerCount(physicalMemory: 64 << 30) == 6)
    }

    @Test("The count rises with memory and never falls")
    func countIsMonotonic() {
        var previous = 0
        for gigabytes in 1...512 {
            let count = FinalDecodeConcurrency.workerCount(
                physicalMemory: UInt64(gigabytes) << 30
            )
            #expect(count >= previous)
            previous = count
        }
    }

    @Test("No machine, however large, reaches WhisperKit's macOS default")
    func countStaysBelowTheLibraryDefault() {
        for gigabytes in 0...512 {
            let count = FinalDecodeConcurrency.workerCount(
                physicalMemory: UInt64(gigabytes) << 30
            )
            #expect(count >= 1)
            #expect(count < 16)
        }
        #expect(FinalDecodeConcurrency.workerCount(physicalMemory: .max) < 16)
    }

    @Test("The final pass decodes with the worker count this machine can afford")
    func finalPassAsksForTheChosenWorkerCount() async throws {
        let meetingID = UUID()
        let decoder = RecordingFileDecoder([
            .success([
                SpecialTokenFixture.result([
                    SpecialTokenFixture.segment(start: 0, end: 1, text: "Hello")
                ])
            ])
        ])
        let transcriber = WhisperKitFinalTranscriber(decoder: decoder)

        _ = try await transcriber.transcribe(
            meetingID: meetingID,
            tracks: [SpecialTokenFixture.track(meetingID)],
            model: SpeechModelCatalog.whisperSmall,
            revision: 1
        )

        let options = try #require(await decoder.receivedOptions.first)
        #expect(options.concurrentWorkerCount == FinalDecodeConcurrency.workerCount(
            physicalMemory: ProcessInfo.processInfo.physicalMemory
        ))
        #expect(options.concurrentWorkerCount < 16)
    }
}
