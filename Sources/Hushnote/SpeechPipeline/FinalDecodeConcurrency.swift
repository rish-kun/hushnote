import Foundation

/// How many VAD chunks the final pass decodes at once.
///
/// WhisperKit defaults to 16 workers on macOS and 4 everywhere else, and the
/// library's own comment explains the split as throughput: only non-macOS
/// devices were seen to regress. That reads the platform, not the machine. Each
/// worker holds a `[1, 5120, 1, 448]` fp16 key and value cache plus `[448,
/// 1500]` alignment weights — about 10.6 MB of decoder state — and, far more
/// expensively, its own live Core ML invocation against a ~400 MB encoder. On a
/// 16 GB Mac all sixteen of those together left the machine with 97 MB of free
/// pages and half a gigabyte of swap in use, and the finalization spent its time
/// paging rather than decoding.
///
/// So the count is budgeted against physical memory instead: one worker per
/// 8 GB, which keeps the whole working set inside the headroom a machine of
/// that size actually has after the OS, the app and the loaded model. The floor
/// keeps a small machine decoding rather than stalling; the ceiling is set low
/// because the encoder is shared and the sixth concurrent invocation buys far
/// less than the first.
enum FinalDecodeConcurrency {
    static let memoryPerWorker: UInt64 = 8 << 30
    static let maximumWorkers = 6

    static func workerCount(physicalMemory: UInt64) -> Int {
        let affordable = min(physicalMemory / memoryPerWorker, UInt64(maximumWorkers))
        return max(1, Int(affordable))
    }
}
