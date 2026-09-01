import Foundation

struct FinalizationRuntimeSample: Equatable, Sendable {
    let modelID: String
    let realtimeFactor: Double

    init(modelID: String, realtimeFactor: Double) {
        self.modelID = modelID
        self.realtimeFactor = realtimeFactor
    }
}

struct FinalizationETARange: Equatable, Sendable {
    let lowerBoundSeconds: Int
    let upperBoundSeconds: Int

    init(lowerBoundSeconds: Int, upperBoundSeconds: Int) {
        self.lowerBoundSeconds = max(0, lowerBoundSeconds)
        self.upperBoundSeconds = max(self.lowerBoundSeconds, upperBoundSeconds)
    }

    /// Human-readable copy intentionally stays a range. A single countdown
    /// would imply precision the model cannot provide, especially on a first
    /// run or while Core ML is loading.
    var userFacingText: String {
        guard upperBoundSeconds > 0 else { return "Almost ready" }
        if upperBoundSeconds < 60 {
            return "About \(lowerBoundSeconds)–\(upperBoundSeconds) sec left"
        }
        if lowerBoundSeconds < 60 {
            let upperMinutes = max(1, Int(ceil(Double(upperBoundSeconds) / 60)))
            return "About \(lowerBoundSeconds) sec–\(upperMinutes) min left"
        }
        let lowerMinutes = max(1, Int(ceil(Double(lowerBoundSeconds) / 60)))
        let upperMinutes = max(lowerMinutes, Int(ceil(Double(upperBoundSeconds) / 60)))
        return "About \(lowerMinutes)–\(upperMinutes) min left"
    }
}

/// A deliberately broad estimate. Recent measurements for the selected model
/// narrow the range; a model-family fallback keeps a first run honest without
/// pretending all Whisper sizes finish at the same speed.
enum FinalizationETAPolicy {
    nonisolated static func estimate(
        audioDurationMilliseconds: Int64,
        modelID: String,
        progress: Double = 0,
        recentSamples: [FinalizationRuntimeSample]
    ) -> FinalizationETARange {
        let audioSeconds = Double(max(0, audioDurationMilliseconds)) / 1_000
        let remainingFraction = 1 - min(1, max(0, progress.isFinite ? progress : 0))
        let matching = recentSamples
            .filter { $0.modelID == modelID && $0.realtimeFactor.isFinite && $0.realtimeFactor > 0 }
            .suffix(8)
            .map(\.realtimeFactor)
            .sorted()

        let factor: Double
        let lowerMultiplier: Double
        let upperMultiplier: Double
        if !matching.isEmpty {
            let middle = matching.count / 2
            factor = matching.count.isMultiple(of: 2)
                ? (matching[middle - 1] + matching[middle]) / 2
                : matching[middle]
            if matching.count >= 3 {
                lowerMultiplier = 0.8
                upperMultiplier = 1.25
            } else {
                lowerMultiplier = 0.7
                upperMultiplier = 1.5
            }
        } else {
            factor = fallbackRealtimeFactor(modelID: modelID)
            lowerMultiplier = 0.65
            upperMultiplier = 1.6
        }

        let estimatedRemaining = audioSeconds * factor * remainingFraction
        guard estimatedRemaining > 0 else {
            return FinalizationETARange(lowerBoundSeconds: 0, upperBoundSeconds: 0)
        }
        return FinalizationETARange(
            lowerBoundSeconds: rounded(seconds: max(5, estimatedRemaining * lowerMultiplier)),
            upperBoundSeconds: rounded(seconds: max(10, estimatedRemaining * upperMultiplier))
        )
    }

    private nonisolated static func fallbackRealtimeFactor(modelID: String) -> Double {
        let normalized = modelID.lowercased()
        if normalized.contains("tiny") { return 0.18 }
        if normalized.contains("base") { return 0.28 }
        if normalized.contains("small") { return 0.42 }
        if normalized.contains("medium") { return 0.62 }
        if normalized.contains("large") { return 0.9 }
        return 0.6
    }

    private nonisolated static func rounded(seconds: Double) -> Int {
        let increment = seconds < 60 ? 5.0 : 30.0
        return Int((seconds / increment).rounded() * increment)
    }
}

struct FinalizationProgressUpdate: Equatable, Sendable {
    let state: FinalizationJobState
    let progress: Double

    init(state: FinalizationJobState, progress: Double) {
        self.state = state
        self.progress = progress
    }
}

struct FinalizationProcessingResult: Equatable, Sendable {
    let realtimeFactor: Double?

    init(realtimeFactor: Double? = nil) {
        self.realtimeFactor = realtimeFactor
    }
}

typealias FinalizationProgressReporter = @Sendable (FinalizationProgressUpdate) async throws -> Void

protocol FinalizationJobProcessing: Sendable {
    func process(
        job: FinalizationJob,
        report: @escaping FinalizationProgressReporter
    ) async throws -> FinalizationProcessingResult
}

enum FinalizationQueueEvent: Equatable, Sendable {
    case pausedForLiveCapture
    case claimed(FinalizationJob, eta: FinalizationETARange)
    case updated(FinalizationJob, eta: FinalizationETARange)
    case succeeded(FinalizationJob)
    case failed(FinalizationJob)
    case requeued(FinalizationJob)
    case queueError(String)
}

enum FinalizationQueueRunResult: Equatable, Sendable {
    case pausedForLiveCapture
    case busy
    case idle
    case completed(UUID)
    case failed(UUID)
    case cancelled(UUID)
    case queueError(String)
}

actor FinalizationQueueController {
    typealias EventHandler = @Sendable (FinalizationQueueEvent) -> Void
    typealias RuntimeSamples = @Sendable (String) async -> [FinalizationRuntimeSample]

    private let store: MeetingStore
    private let processor: any FinalizationJobProcessing
    private let pollInterval: Duration
    private let now: @Sendable () -> Date
    private let runtimeSamples: RuntimeSamples
    private let onEvent: EventHandler

    private var liveCaptureActive = false
    private var isProcessing = false
    private var workerTask: Task<Void, Never>?

    init(
        store: MeetingStore,
        processor: any FinalizationJobProcessing,
        pollInterval: Duration = .seconds(2),
        now: @escaping @Sendable () -> Date = Date.init,
        runtimeSamples: @escaping RuntimeSamples = { _ in [] },
        onEvent: @escaping EventHandler = { _ in }
    ) {
        self.store = store
        self.processor = processor
        self.pollInterval = pollInterval
        self.now = now
        self.runtimeSamples = runtimeSamples
        self.onEvent = onEvent
    }

    deinit {
        workerTask?.cancel()
    }

    func start() {
        guard workerTask == nil else { return }
        workerTask = Task { [weak self] in
            await self?.workLoop()
        }
    }

    func stop() async {
        let task = workerTask
        workerTask = nil
        task?.cancel()
        await task?.value
    }

    func setLiveCaptureActive(_ active: Bool) {
        liveCaptureActive = active
        if active { onEvent(.pausedForLiveCapture) }
    }

    @discardableResult
    func retry(jobID: UUID, at date: Date = Date()) async throws -> FinalizationJob {
        try await store.retryFinalizationJob(id: jobID, at: date)
    }

    @discardableResult
    func runNext() async -> FinalizationQueueRunResult {
        guard !isProcessing else { return .busy }
        guard !liveCaptureActive else {
            onEvent(.pausedForLiveCapture)
            return .pausedForLiveCapture
        }
        isProcessing = true
        defer { isProcessing = false }

        let claimed: FinalizationJob
        do {
            guard let job = try await store.claimNextFinalizationJob(
                liveCaptureActive: liveCaptureActive,
                at: now()
            ) else { return .idle }
            claimed = job
        } catch {
            let message = error.localizedDescription
            onEvent(.queueError(message))
            return .queueError(message)
        }

        let samples = await runtimeSamples(claimed.modelID)
        onEvent(.claimed(
            claimed,
            eta: FinalizationETAPolicy.estimate(
                audioDurationMilliseconds: claimed.audioDurationMilliseconds,
                modelID: claimed.modelID,
                progress: claimed.progress,
                recentSamples: samples
            )
        ))

        do {
            let result = try await processor.process(job: claimed) { [store, runtimeSamples, onEvent] update in
                guard FinalizationJobTransitionPolicy.isRunning(update.state) else {
                    throw FinalizationQueueError.invalidProgressState(update.state)
                }
                guard var durable = try await store.finalizationJob(id: claimed.id) else {
                    throw FinalizationQueueError.jobDisappeared(claimed.id)
                }
                durable.state = update.state
                durable.progress = min(0.999, max(durable.progress, update.progress.isFinite ? update.progress : 0))
                try await store.updateFinalizationJob(durable)
                let samples = await runtimeSamples(durable.modelID)
                onEvent(.updated(
                    durable,
                    eta: FinalizationETAPolicy.estimate(
                        audioDurationMilliseconds: durable.audioDurationMilliseconds,
                        modelID: durable.modelID,
                        progress: durable.progress,
                        recentSamples: samples
                    )
                ))
            }
            var durable = try await requireJob(claimed.id)
            durable = try await advanceToCompletableState(durable)
            durable.state = .succeeded
            durable.progress = 1
            durable.finishedAt = now()
            durable.errorMessage = nil
            durable.realtimeFactor = validRealtimeFactor(result.realtimeFactor)
                ?? measuredRealtimeFactor(for: durable)
            try await store.updateFinalizationJob(durable)
            onEvent(.succeeded(durable))
            return .completed(durable.id)
        } catch is CancellationError {
            do {
                var durable = try await requireJob(claimed.id)
                if FinalizationJobTransitionPolicy.isRunning(durable.state) {
                    durable.state = .queued
                    durable.progress = 0
                    durable.startedAt = nil
                    durable.finishedAt = nil
                    durable.errorMessage = nil
                    try await store.updateFinalizationJob(durable)
                    onEvent(.requeued(durable))
                }
                return .cancelled(claimed.id)
            } catch {
                let message = error.localizedDescription
                onEvent(.queueError(message))
                return .queueError(message)
            }
        } catch {
            do {
                var durable = try await requireJob(claimed.id)
                if FinalizationJobTransitionPolicy.isRunning(durable.state) {
                    durable.state = .failed
                    durable.finishedAt = now()
                    durable.errorMessage = error.localizedDescription
                    try await store.updateFinalizationJob(durable)
                }
                onEvent(.failed(durable))
                return .failed(durable.id)
            } catch {
                let message = error.localizedDescription
                onEvent(.queueError(message))
                return .queueError(message)
            }
        }
    }

    private func workLoop() async {
        while !Task.isCancelled {
            let result = await runNext()
            if case .completed = result { continue }
            if case .failed = result { continue }
            do {
                try await Task.sleep(for: pollInterval)
            } catch {
                return
            }
        }
    }

    private func requireJob(_ id: UUID) async throws -> FinalizationJob {
        guard let job = try await store.finalizationJob(id: id) else {
            throw FinalizationQueueError.jobDisappeared(id)
        }
        return job
    }

    private func advanceToCompletableState(_ job: FinalizationJob) async throws -> FinalizationJob {
        var durable = job
        if durable.state == .transcribing {
            durable.state = .diarizing
            durable.progress = max(durable.progress, 0.9)
            try await store.updateFinalizationJob(durable)
        }
        guard durable.state == .diarizing || durable.state == .merging else {
            throw FinalizationQueueError.invalidCompletionState(durable.state)
        }
        return durable
    }

    private func measuredRealtimeFactor(for job: FinalizationJob) -> Double? {
        guard let startedAt = job.startedAt, job.audioDurationMilliseconds > 0 else { return nil }
        let elapsed = max(0, now().timeIntervalSince(startedAt))
        return validRealtimeFactor(elapsed / (Double(job.audioDurationMilliseconds) / 1_000))
    }

    private func validRealtimeFactor(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }
}

enum FinalizationQueueError: Error, Equatable, LocalizedError, Sendable {
    case invalidProgressState(FinalizationJobState)
    case invalidCompletionState(FinalizationJobState)
    case jobDisappeared(UUID)

    var errorDescription: String? {
        switch self {
        case .invalidProgressState(let state):
            "A processor reported the non-running state \(state.rawValue)."
        case .invalidCompletionState(let state):
            "A processor completed from the invalid state \(state.rawValue)."
        case .jobDisappeared(let id):
            "Finalization job \(id) disappeared while it was running."
        }
    }
}
