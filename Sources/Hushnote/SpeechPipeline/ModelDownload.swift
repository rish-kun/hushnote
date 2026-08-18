import Foundation
import WhisperKit

/// How far a model download has got, and how fast it is moving.
///
/// The rate is optional because it genuinely is not always knowable: nothing is
/// measurable before the second observation, and a download parked on a hash
/// check is moving at no rate at all.
struct ModelDownloadProgress: Equatable, Sendable {
    var fraction: Double = 0
    var bytesPerSecond: Double?

    /// A download that has been asked for but has not reported anything yet.
    static let starting = ModelDownloadProgress()
}

/// Turns a stream of fractional-progress observations into a transfer rate that
/// can be put on screen.
///
/// WhisperKit's `download(variant:progressCallback:)` yields a `Progress` whose
/// `fractionCompleted` is the only thing guaranteed to be there, so the rate is
/// derived from how much of the artifact that fraction moved over how long.
/// Two things make the naive difference unusable:
///
/// - the callback fires once per HTTP chunk, so a pair of chunks routinely
///   share a timestamp and divide a byte delta by zero, and
/// - even when they do not, a per-chunk rate swings by an order of magnitude
///   between frames, which reads as noise rather than as a number.
///
/// So observations are accumulated until at least `minimumSampleInterval` of
/// wall clock has passed, and the result is exponentially smoothed.
struct ModelDownloadRateEstimator: Sendable {
    /// Below this, an interval is not long enough to measure anything against.
    /// A third of a second is short enough that the reading still responds to a
    /// change in conditions within one glance.
    static let minimumSampleInterval: TimeInterval = 0.35

    /// Weight of the newest observation. At a quarter, a chunk arriving ten
    /// times faster than the run rate moves the reading by about three times,
    /// not ten, and a sustained change is fully absorbed in a couple of seconds.
    static let smoothing = 0.25

    private let totalBytes: Int64
    private var anchor: (fraction: Double, time: TimeInterval)?
    private var smoothed: Double?

    init(totalBytes: Int64) {
        self.totalBytes = totalBytes
    }

    /// Folds one observation in and returns the rate to display, in bytes per
    /// second, or nil while there is nothing honest to say.
    ///
    /// - Parameter reportedBytesPerSecond: the rate the transport measured
    ///   itself, when it offers one. HubApi puts it on the `Progress` under
    ///   `ProgressUserInfoKey.throughputKey`, but only for chunks where it could
    ///   measure one, so it is an input rather than the answer.
    mutating func record(
        fraction: Double,
        at time: TimeInterval,
        reportedBytesPerSecond: Double? = nil
    ) -> Double? {
        let fraction = fraction.isFinite ? min(max(fraction, 0), 1) : 0
        guard let previous = anchor else {
            anchor = (fraction, time)
            return nil
        }

        let elapsed = time - previous.time
        guard elapsed >= Self.minimumSampleInterval else { return smoothed }
        anchor = (fraction, time)

        let instantaneous: Double
        if let reported = reportedBytesPerSecond, reported.isFinite, reported >= 0 {
            instantaneous = reported
        } else if totalBytes > 0 {
            // Progress that rewound -- a retried file, a snapshot that restarted
            // -- is not negative movement, it is no movement.
            instantaneous = max(0, (fraction - previous.fraction) * Double(totalBytes)) / elapsed
        } else {
            return smoothed
        }

        guard instantaneous.isFinite else { return smoothed }
        let next = smoothed.map { $0 + Self.smoothing * (instantaneous - $0) } ?? instantaneous
        smoothed = next
        return next
    }
}

/// The two strings the download row shows, kept out of the view so they can be
/// held to a shape.
enum ModelDownloadText {
    static func percentage(_ fraction: Double) -> String {
        let value = fraction.isFinite ? min(max(fraction, 0), 1) : 0
        return "Downloading \(Int((value * 100).rounded(.down)))%"
    }

    /// The transfer rate in the largest unit that keeps it readable. An unknown
    /// or stalled rate is shown as nothing rather than as "0.0 MB/s", which
    /// looks like a stuck download rather than an unmeasured one.
    static func rate(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond, bytesPerSecond.isFinite, bytesPerSecond > 0 else { return "" }
        if bytesPerSecond >= 1_000_000 {
            return String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
        }
        if bytesPerSecond >= 1_000 {
            return String(format: "%.0f KB/s", bytesPerSecond / 1_000)
        }
        return String(format: "%.0f B/s", bytesPerSecond)
    }
}

/// Fetching a model's artifacts, separated from loading them.
///
/// The two were one call: `downloadModel` asked the engine to `load(model:)`,
/// which downloads, prewarms and compiles in a single opaque await. Splitting
/// them is what lets the screen show a fetch that is 24% done, and what lets a
/// test drive that screen without touching the network.
protocol SpeechModelDownloading: Sendable {
    /// - Parameter onProgress: fractional progress, and the byte rate the
    ///   transport measured for this chunk when it measured one.
    /// - Returns: the folder the model's artifacts are in.
    func download(
        model: SpeechModel,
        onProgress: @escaping @Sendable (Double, Double?) -> Void
    ) async throws -> URL
}

/// The real thing. `WhisperKit.download(variant:progressCallback:)` yields a
/// `Progress` per HTTP chunk; HubApi hangs the rate it measured for that chunk
/// on it under `ProgressUserInfoKey.throughputKey` when it has one.
///
/// Cancellation is Task cancellation: HubApi wraps its transfer in
/// `withTaskCancellationHandler` and tells the downloader to stop, so
/// cancelling the task that calls this is enough.
struct WhisperKitModelDownloader: SpeechModelDownloading {
    func download(
        model: SpeechModel,
        onProgress: @escaping @Sendable (Double, Double?) -> Void
    ) async throws -> URL {
        try await WhisperKit.download(
            variant: model.runtimeIdentifier,
            progressCallback: { progress in
                onProgress(
                    progress.fractionCompleted,
                    progress.userInfo[.throughputKey] as? Double
                )
            }
        )
    }
}

/// The running rate average, in a box.
///
/// The progress callback is `@Sendable` and fires from whatever thread finished
/// a chunk, but an estimator carries state across calls. Hopping to an actor per
/// chunk would let two reports land out of order, and a progress bar that goes
/// backwards for a frame is worse than one that is a little late.
private final class RateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var estimator: ModelDownloadRateEstimator

    init(totalBytes: Int64) {
        estimator = ModelDownloadRateEstimator(totalBytes: totalBytes)
    }

    func record(fraction: Double, at time: TimeInterval, reported: Double?) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        return estimator.record(fraction: fraction, at: time, reportedBytesPerSecond: reported)
    }
}

/// Drives one model download from asked-for to on disk, reporting every state
/// the row should show.
///
/// This is deliberately not a method on `AppCoordinator`: the coordinator opens
/// the real meeting database in its initialiser and cannot be built in a test,
/// and the two states most worth pinning down -- cancelled, and
/// landed-but-would-not-load -- are exactly the ones a real download will not
/// produce on demand.
struct ModelDownloadRunner: Sendable {
    private let downloader: any SpeechModelDownloading
    private let now: @Sendable () -> TimeInterval

    init(
        downloader: any SpeechModelDownloading,
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.downloader = downloader
        self.now = now
    }

    /// - Parameter install: what to do with the artifacts once they are on
    ///   disk. Loading is separate from fetching, and it can fail on its own:
    ///   Core ML compilation is where a model that downloaded perfectly still
    ///   does not come up, and calling that row "Ready" is how a meeting starts
    ///   against a model that is not there.
    /// - Parameter report: every state the row should show, ending in `.ready`,
    ///   `.failed` or -- for a cancellation -- `.notInstalled`.
    func run(
        model: SpeechModel,
        install: @Sendable (URL) async throws -> Void,
        report: @escaping @Sendable (ModelAvailability) -> Void
    ) async {
        let rate = RateBox(totalBytes: model.approximateDownloadBytes)
        do {
            let folder = try await downloader.download(model: model) { fraction, reported in
                report(
                    .downloading(
                        ModelDownloadProgress(
                            fraction: fraction,
                            bytesPerSecond: rate.record(fraction: fraction, at: now(), reported: reported)
                        )
                    )
                )
            }
            try Task.checkCancellation()
            try await install(folder)
            report(.ready)
        } catch is CancellationError {
            // Stopping a download is not a failure, and a row that says
            // "Retry" after the user pressed Cancel is arguing with them.
            report(.notInstalled)
        } catch {
            report(Task.isCancelled ? .notInstalled : .failed(error.localizedDescription))
        }
    }
}
