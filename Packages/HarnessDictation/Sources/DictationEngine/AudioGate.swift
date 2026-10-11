#if os(iOS)
import AVFoundation
import Foundation
import DictationCore

/// Sits between the always-on warm microphone and the current transcriber. While no dictation is
/// active, buffers are dropped here and never leave this function. Thread-safe: `route` runs on
/// the audio thread, everything else on the main thread.
public final class AudioGate: @unchecked Sendable {
    public struct Meter: Sendable {
        public var level: Float
        public var silenceReached: Bool
    }

    private let lock = NSLock()
    private var sink: SpeechStreamTranscriber?
    private var smoother = LevelSmoother()
    private var silence = SilenceDetector(requiredDuration: 0)
    private var onMeter: ((Meter) -> Void)?
    private var lastEmit: TimeInterval = 0
    private var silenceReported = false

    public init() {}

    /// Starts sending audio to `sink`. `onMeter` is called on the main queue about 15 times a second.
    public func attach(_ sink: SpeechStreamTranscriber, silenceAutoStopSeconds: Int, onMeter: @escaping (Meter) -> Void) {
        lock.lock()
        self.sink = sink
        self.onMeter = onMeter
        smoother = LevelSmoother()
        silence = SilenceDetector(requiredDuration: TimeInterval(max(0, silenceAutoStopSeconds)))
        silenceReported = false
        lastEmit = 0
        lock.unlock()
    }

    /// Stops sending audio anywhere. Returns the sink that was attached.
    @discardableResult
    public func detach() -> SpeechStreamTranscriber? {
        lock.lock()
        let previous = sink
        sink = nil
        onMeter = nil
        lock.unlock()
        return previous
    }

    public func route(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        guard let sink else {
            lock.unlock()
            return // warm but idle: the audio is discarded
        }
        var meter: Meter?
        if let samples = buffer.firstChannelSamples {
            let level = smoother.push(AudioLevel.normalized(rms: AudioLevel.rms(samples)))
            let now = ProcessInfo.processInfo.systemUptime
            let reached = silence.push(level: level, at: now)
            let shouldReportSilence = reached && !silenceReported
            if shouldReportSilence { silenceReported = true }
            if now - lastEmit > 1.0 / 15.0 || shouldReportSilence {
                lastEmit = now
                meter = Meter(level: level, silenceReached: shouldReportSilence)
            }
        }
        let handler = onMeter
        lock.unlock()

        sink.append(buffer)
        if let meter, let handler {
            DispatchQueue.main.async { handler(meter) }
        }
    }
}
#endif
