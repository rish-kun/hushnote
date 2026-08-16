import Foundation

public struct AudioLeakageResult: Equatable, Sendable {
    public let correlation: Float
    public let lagSamples: Int
    public let isLikelyLeakage: Bool

    public init(correlation: Float, lagSamples: Int, isLikelyLeakage: Bool) {
        self.correlation = correlation
        self.lagSamples = lagSamples
        self.isLikelyLeakage = isLikelyLeakage
    }
}

/// Detects system-audio echo in the microphone track. It intentionally reports
/// rather than mutates audio: callers can flag suspicious regions without ever
/// deleting a speaker's real words.
public struct AudioLeakageDetector: Sendable {
    public let correlationThreshold: Float
    public let minimumRMS: Float
    public let maximumLagMilliseconds: Double

    public init(
        correlationThreshold: Float = 0.92,
        minimumRMS: Float = 0.006,
        maximumLagMilliseconds: Double = 40
    ) {
        precondition((0...1).contains(correlationThreshold))
        precondition(minimumRMS >= 0)
        precondition(maximumLagMilliseconds >= 0)
        self.correlationThreshold = correlationThreshold
        self.minimumRMS = minimumRMS
        self.maximumLagMilliseconds = maximumLagMilliseconds
    }

    public func analyze(
        system reference: [Float],
        microphone candidate: [Float],
        sampleRate: Double
    ) -> AudioLeakageResult {
        guard sampleRate > 0, reference.count >= 32, candidate.count >= 32,
              rms(reference) >= minimumRMS, rms(candidate) >= minimumRMS
        else {
            return AudioLeakageResult(correlation: 0, lagSamples: 0, isLikelyLeakage: false)
        }

        let maximumLag = min(
            Int(sampleRate * maximumLagMilliseconds / 1_000),
            min(reference.count, candidate.count) / 4
        )
        var bestScore: Float = 0
        var bestLag = 0

        for lag in (-maximumLag)...maximumLag {
            let referenceStart = max(0, -lag)
            let candidateStart = max(0, lag)
            let count = min(reference.count - referenceStart, candidate.count - candidateStart)
            guard count >= 32 else { continue }

            var dot: Double = 0
            var referenceEnergy: Double = 0
            var candidateEnergy: Double = 0
            for index in 0..<count {
                let lhs = Double(reference[referenceStart + index])
                let rhs = Double(candidate[candidateStart + index])
                dot += lhs * rhs
                referenceEnergy += lhs * lhs
                candidateEnergy += rhs * rhs
            }
            let denominator = sqrt(referenceEnergy * candidateEnergy)
            guard denominator > 0 else { continue }
            let score = Float(abs(dot / denominator))
            if score > bestScore {
                bestScore = score
                bestLag = lag
            }
        }

        return AudioLeakageResult(
            correlation: bestScore,
            lagSamples: bestLag,
            isLikelyLeakage: bestScore >= correlationThreshold
        )
    }

    private func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let energy = samples.reduce(0.0) { $0 + Double($1 * $1) }
        return Float(sqrt(energy / Double(samples.count)))
    }
}
