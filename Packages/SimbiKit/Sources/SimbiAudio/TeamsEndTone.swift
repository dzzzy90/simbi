import Accelerate
import Foundation

/// Recognizes either Teams exit sound in the 16 kHz system stream.
/// The reference ships with the app so capture works offline.
struct TeamsEndTone {
    private var callEnd: WaveformMatcher
    private var meetingLeave: WaveformMatcher
    private var detected = false

    init() throws {
        guard let end = WaveformMatcher(reference: try Self.reference("Teams_Call_Ended"), threshold: 0.90),
              let leave = WaveformMatcher(reference: try Self.reference("Teams_Meet_Up_Leave"), threshold: 0.65)
        else { throw CocoaError(.fileReadCorruptFile) }
        callEnd = end
        meetingLeave = leave
    }

    mutating func consume(_ samples: [Float]) -> Bool {
        guard !detected else { return false }
        detected = callEnd.consume(samples) || meetingLeave.consume(samples)
        return detected
    }

    private static func reference(_ name: String) throws -> [Float] {
        guard let url = Bundle.module.url(forResource: name, withExtension: "pcm")
        else { throw CocoaError(.fileNoSuchFile) }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty, data.count.isMultiple(of: 2) else { throw CocoaError(.fileReadCorruptFile) }
        return stride(from: 0, to: data.count, by: 2).map { i in
            let bits = UInt16(data[i]) | (UInt16(data[i + 1]) << 8)
            return Float(Int16(bitPattern: bits)) / 32768
        }
    }

}

private struct WaveformMatcher {
    private let threshold: Double
    private let template: [Float]
    private var history: [Float] = []
    private var partial: [Float] = []
    private var sinceCheck = 0
    private var detected = false

    init?(reference: [Float], threshold: Double) {
        self.threshold = threshold
        var coarse: [Float] = []
        for i in stride(from: 0, to: reference.count - 3, by: 4) {
            let sum = reference[i] + reference[i + 1] + reference[i + 2] + reference[i + 3]
            coarse.append(sum * 0.25)
        }
        guard let peak = coarse.map(abs).max(), peak > 0,
              let first = coarse.firstIndex(where: { abs($0) > peak * 0.02 }),
              let last = coarse.lastIndex(where: { abs($0) > peak * 0.02 }),
              last - first >= 400 else { return nil }
        let signal = Array(coarse[first...last])
        let norm = sqrt(signal.reduce(0) { $0 + $1 * $1 })
        template = signal.map { $0 / norm }
    }

    mutating func consume(_ samples: [Float]) -> Bool {
        guard !detected else { return false }
        for sample in samples {
            partial.append(sample)
            guard partial.count == 4 else { continue }
            history.append(partial.reduce(0, +) * 0.25)
            partial.removeAll(keepingCapacity: true)
            sinceCheck += 1
            guard sinceCheck >= 128, history.count >= template.count else { continue }
            sinceCheck = 0
            let count = history.count - template.count + 1
            var correlations = [Float](repeating: 0, count: count)
            vDSP_conv(history, 1, template, 1, &correlations, 1,
                      vDSP_Length(count), vDSP_Length(template.count))
            var power = history.prefix(template.count).reduce(0.0) { $0 + Double($1) * Double($1) }
            for i in 0..<count {
                if power > 1e-10, Double(abs(correlations[i])) > threshold * sqrt(power) {
                    detected = true
                    return true
                }
                if i + template.count < history.count {
                    let entering = Double(history[i + template.count]), leaving = Double(history[i])
                    power += entering * entering - leaving * leaving
                }
            }
            history.removeFirst(count)
        }
        return false
    }
}
