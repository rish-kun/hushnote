import Foundation
import Testing
@testable import Hushnote

/// WhisperKit hands back a `Progress` and nothing else that the screen can
/// show as a transfer rate on its own, so the rate is derived here from
/// fractional-progress deltas over time. It is derived rather than read off a
/// clock tick because the callback fires per HTTP chunk: hundreds of times a
/// second at the start of a file and not at all while a hash is verified.
@Suite("Model download rate")
struct ModelDownloadRateTests {
    private let total: Int64 = 600_000_000

    @Test("One observation is not a rate")
    func firstSampleHasNoRate() {
        var estimator = ModelDownloadRateEstimator(totalBytes: total)

        #expect(estimator.record(fraction: 0.1, at: 100) == nil)
    }

    /// 6 MB every second of a 600 MB download is one percent a second.
    @Test("A steady stream reads as its actual rate")
    func steadyStreamConverges() {
        var estimator = ModelDownloadRateEstimator(totalBytes: total)
        var rate: Double?
        for step in 0...10 {
            rate = estimator.record(fraction: Double(step) / 100, at: 100 + Double(step))
        }

        #expect(rate != nil)
        #expect(abs((rate ?? 0) - 6_000_000) < 60_000)
    }

    /// The callback fires per chunk, and two chunks routinely land inside the
    /// same clock tick. Dividing a byte delta by an interval of zero is how a
    /// download reads "inf GB/s" for a frame.
    @Test("Samples closer together than the sampling floor are folded, not divided by nothing")
    func burstsDoNotProduceAbsurdRates() {
        var estimator = ModelDownloadRateEstimator(totalBytes: total)
        _ = estimator.record(fraction: 0, at: 100)
        var readings: [Double] = []
        for step in 1...200 {
            // Chunks arrive in pairs sharing a timestamp.
            let time = 100 + Double(step / 2) * 0.01
            if let rate = estimator.record(fraction: Double(step) / 2_000, at: time) {
                readings.append(rate)
            }
        }

        // 200 chunks of 0.05% of 600 MB, spread over one second, is 60 MB/s
        // whatever the chunk cadence.
        #expect(readings.isEmpty == false)
        #expect(readings.allSatisfy { $0.isFinite })
        #expect(readings.allSatisfy { $0 < 200_000_000 })
        #expect(abs((readings.last ?? 0) - 60_000_000) < 20_000_000)
    }

    @Test("A single burst does not throw the reading")
    func smoothingBoundsASpike() {
        var estimator = ModelDownloadRateEstimator(totalBytes: total)
        var rate: Double?
        for step in 0...10 {
            rate = estimator.record(fraction: Double(step) / 100, at: 100 + Double(step))
        }
        let settled = rate ?? 0
        let spiked = estimator.record(fraction: 0.20, at: 111) ?? 0

        // The reading has to move -- a rate that ignores a real change in
        // conditions is a decoration -- but a chunk arriving ten times faster
        // than the run rate must not put a "60 MB/s" on screen for one frame.
        #expect(spiked > settled)
        #expect(spiked < settled * 4)
    }

    @Test("Progress that stalls or rewinds never reads as a negative rate")
    func nonAdvancingProgressIsNotNegative() {
        var estimator = ModelDownloadRateEstimator(totalBytes: total)
        _ = estimator.record(fraction: 0.5, at: 100)
        let stalled = estimator.record(fraction: 0.5, at: 105)
        let rewound = estimator.record(fraction: 0.4, at: 110)

        #expect((stalled ?? 0) >= 0)
        #expect((rewound ?? 0) >= 0)
    }

    /// HubApi does put a byte rate on the `Progress` it hands out, under
    /// `ProgressUserInfoKey.throughputKey`, but only for chunks where the
    /// downloader could measure one. When it is there it beats a difference of
    /// two fractions rounded to whole percents.
    @Test("A rate the transport measured itself is preferred over a derived one")
    func reportedThroughputWins() {
        var estimator = ModelDownloadRateEstimator(totalBytes: total)
        _ = estimator.record(fraction: 0.10, at: 100, reportedBytesPerSecond: 12_000_000)
        let rate = estimator.record(fraction: 0.11, at: 101, reportedBytesPerSecond: 12_000_000)

        #expect(abs((rate ?? 0) - 12_000_000) < 120_000)
    }

    @Test("A download with no known size still reports progress, just no rate")
    func unknownTotalHasNoRate() {
        var estimator = ModelDownloadRateEstimator(totalBytes: 0)
        _ = estimator.record(fraction: 0.1, at: 100)

        #expect(estimator.record(fraction: 0.2, at: 101) == nil)
    }
}

@Suite("Model download text")
struct ModelDownloadTextTests {
    @Test("The percentage is whole, clamped, and reads like the button it replaces")
    func percentage() {
        #expect(ModelDownloadText.percentage(0.2437) == "Downloading 24%")
        #expect(ModelDownloadText.percentage(0) == "Downloading 0%")
        #expect(ModelDownloadText.percentage(1) == "Downloading 100%")
        #expect(ModelDownloadText.percentage(1.4) == "Downloading 100%")
        #expect(ModelDownloadText.percentage(-0.2) == "Downloading 0%")
        #expect(ModelDownloadText.percentage(.nan) == "Downloading 0%")
    }

    @Test("The rate is shown in the unit it fits, or not at all")
    func rate() {
        #expect(ModelDownloadText.rate(9_800_000) == "9.8 MB/s")
        #expect(ModelDownloadText.rate(850_000) == "850 KB/s")
        #expect(ModelDownloadText.rate(1_000_000) == "1.0 MB/s")
        #expect(ModelDownloadText.rate(nil) == "")
        #expect(ModelDownloadText.rate(0) == "")
    }
}
