import Foundation
import Testing
@testable import Hushnote

/// Nothing here touches the network. `SpeechModelDownloading` exists precisely
/// so the state a row goes through can be driven from a fake, because the real
/// path fetches several hundred megabytes and the states that matter most --
/// cancelled, and failed-while-installing -- are the ones a real download will
/// not produce on demand.
private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ModelAvailability] = []

    func append(_ value: ModelAvailability) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [ModelAvailability] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// A clock the fake transport advances, so the rate estimator's sampling floor
/// is crossed without any test sleeping through it.
private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        value += seconds
        lock.unlock()
    }

    func now() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class DownloadBaseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: URL?

    func record(_ url: URL?) {
        lock.lock()
        storage = url
        lock.unlock()
    }

    var value: URL? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private struct FakeDownloader: SpeechModelDownloading {
    var fractions: [Double] = []
    var clock: FakeClock?
    var failure: (any Error)?
    /// Blocks until the task is cancelled, which is how the cancel path is
    /// exercised without a race.
    var blocks = false
    var downloadBaseRecorder: DownloadBaseRecorder?

    func download(
        model: SpeechModel,
        downloadBase: URL?,
        onProgress: @escaping @Sendable (Double, Double?) -> Void
    ) async throws -> URL {
        downloadBaseRecorder?.record(downloadBase)
        for fraction in fractions {
            clock?.advance(1)
            onProgress(fraction, nil)
        }
        if blocks {
            try await Task.sleep(for: .seconds(30))
        }
        if let failure { throw failure }
        return URL(fileURLWithPath: "/tmp/hushnote-tests/\(model.runtimeIdentifier)")
    }
}

private struct FakeFailure: Error, LocalizedError {
    var errorDescription: String? { "the host refused the connection" }
}

@Suite("Model download runner")
struct ModelDownloadRunnerTests {
    private let model = SpeechModelCatalog.whisperSmall

    @Test("A download walks the row from asked-for to on disk")
    func happyPathEndsReady() async {
        let clock = FakeClock()
        let collector = Collector()
        let runner = ModelDownloadRunner(
            downloader: FakeDownloader(fractions: [0.25, 0.5, 1], clock: clock),
            now: clock.now
        )

        await runner.run(model: model, install: { _ in }, report: collector.append)

        let states = collector.values
        #expect(states.last == .ready)
        #expect(states.compactMap(\.progress?.fraction) == [0.25, 0.5, 1])
    }

    @Test("A download uses the selected cache root")
    func selectedDownloadBaseReachesTransport() async {
        let recorder = DownloadBaseRecorder()
        let base = URL(fileURLWithPath: "/Volumes/Models/Hushnote Models/WhisperKit")
        let runner = ModelDownloadRunner(
            downloader: FakeDownloader(downloadBaseRecorder: recorder)
        )

        await runner.run(model: model, downloadBase: base, install: { _ in }, report: { _ in })

        #expect(recorder.value == base)
    }

    @Test("The states carry a measured rate once there is enough to measure")
    func progressCarriesARate() async {
        let clock = FakeClock()
        let collector = Collector()
        let runner = ModelDownloadRunner(
            downloader: FakeDownloader(fractions: [0, 0.25, 0.5], clock: clock),
            now: clock.now
        )

        await runner.run(model: model, install: { _ in }, report: collector.append)

        // A quarter of a 488 MB model in one second.
        let rates = collector.values.compactMap(\.progress?.bytesPerSecond)
        #expect(rates.isEmpty == false)
        #expect(abs((rates.last ?? 0) - 122_000_000) < 2_000_000)
    }

    @Test("A cancelled download leaves the row where it started, not failed")
    func cancellationIsNotAFailure() async {
        let collector = Collector()
        let runner = ModelDownloadRunner(
            downloader: FakeDownloader(fractions: [0.1], blocks: true),
            now: { 0 }
        )

        let task = Task { await runner.run(model: model, install: { _ in }, report: collector.append) }
        // Let the fake report its first chunk before pulling the plug.
        try? await Task.sleep(for: .milliseconds(60))
        task.cancel()
        await task.value

        let states = collector.values
        #expect(states.last == .notInstalled)
        #expect(states.contains(.ready) == false)
        #expect(states.contains { if case .failed = $0 { return true } else { return false } } == false)
    }

    @Test("A transport that refuses says so on the row")
    func failureCarriesTheReason() async {
        let collector = Collector()
        let runner = ModelDownloadRunner(
            downloader: FakeDownloader(failure: FakeFailure()),
            now: { 0 }
        )

        await runner.run(model: model, install: { _ in }, report: collector.append)

        #expect(collector.values.last == .failed("the host refused the connection"))
    }

    /// Artifacts on disk are not a model that loaded. Core ML compilation is
    /// where a model that downloaded fine still fails, and calling that row
    /// "Ready" is how a meeting starts against a model that is not there.
    @Test("A download that lands but will not load is not ready")
    func installFailureIsNotReady() async {
        let collector = Collector()
        let runner = ModelDownloadRunner(
            downloader: FakeDownloader(fractions: [1]),
            now: { 0 }
        )

        await runner.run(model: model, install: { _ in throw FakeFailure() }, report: collector.append)

        #expect(collector.values.last == .failed("the host refused the connection"))
        #expect(collector.values.contains(.ready) == false)
    }
}
