import Foundation

/// Microphone level for the waveform, from raw samples.
public enum AudioLevel {
    /// Root-mean-square of the samples.
    public static func rms(_ samples: UnsafeBufferPointer<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }

    public static func rms(_ samples: [Float]) -> Float {
        samples.withUnsafeBufferPointer { rms($0) }
    }

    /// Maps RMS to 0...1 on a decibel scale: -50 dBFS and below is silence, -5 dBFS is full.
    public static func normalized(rms: Float, floorDB: Float = -50, ceilingDB: Float = -5) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        let clamped = min(max(db, floorDB), ceilingDB)
        return (clamped - floorDB) / (ceilingDB - floorDB)
    }
}

/// Smooths levels so the waveform rises fast and falls gently.
public struct LevelSmoother: Sendable {
    public var attack: Float
    public var release: Float
    public private(set) var value: Float = 0

    public init(attack: Float = 0.6, release: Float = 0.12) {
        self.attack = attack
        self.release = release
    }

    public mutating func push(_ level: Float) -> Float {
        let k = level > value ? attack : release
        value += (level - value) * k
        return value
    }
}

/// Detects a continuous stretch of silence for auto-stop.
public struct SilenceDetector: Sendable {
    public var threshold: Float
    public var requiredDuration: TimeInterval
    private var silentSince: TimeInterval?
    private var heardSpeech = false

    public init(threshold: Float = 0.12, requiredDuration: TimeInterval) {
        self.threshold = threshold
        self.requiredDuration = requiredDuration
    }

    /// Feed a normalized level and the time it was measured. Returns true once silence has lasted
    /// `requiredDuration` after some speech was heard.
    public mutating func push(level: Float, at time: TimeInterval) -> Bool {
        guard requiredDuration > 0 else { return false }
        if level >= threshold {
            heardSpeech = true
            silentSince = nil
            return false
        }
        guard heardSpeech else { return false }
        if silentSince == nil { silentSince = time }
        return time - (silentSince ?? time) >= requiredDuration
    }

    public mutating func reset() {
        silentSince = nil
        heardSpeech = false
    }
}

/// Encodes mono Float32 PCM as a 16-bit WAV file in memory, for routes that upload audio.
/// Nothing is written to disk.
public enum WAVEncoder {
    public static func encode(samples: [Float], sampleRate: Int) -> Data {
        var data = Data()
        let byteCount = samples.count * 2
        data.reserveCapacity(44 + byteCount)

        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }

        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + byteCount))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))          // PCM chunk size
        append(UInt16(1))           // PCM format
        append(UInt16(1))           // mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2)) // byte rate
        append(UInt16(2))           // block align
        append(UInt16(16))          // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(byteCount))
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            append(Int16(clamped * Float(Int16.max)))
        }
        return data
    }
}
