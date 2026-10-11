#if os(iOS)
import AVFoundation
import DictationCore

public enum AudioCaptureError: LocalizedError {
    case permissionDenied
    case noInputDevice

    public var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Microphone access is off for Harness. Turn it on in Settings."
        case .noInputDevice: return "No microphone is available right now."
        }
    }
}

/// Owns the microphone. Runs for the whole warm session; buffers are handed to `onBuffer` on the
/// audio thread, and the host decides whether they belong to a dictation or get dropped.
/// Audio is never written to disk. Use from the main actor; only `onBuffer` runs elsewhere.
@MainActor
public final class AudioCapture {
    /// Called on the audio thread for every microphone buffer. Set before `start()`.
    public var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    /// Called on the main actor when a call, Siri or another app takes the audio session.
    public var onInterruption: (() -> Void)?

    public private(set) var isRunning = false
    private let engine = AVAudioEngine()
    private var observers: [NSObjectProtocol] = []

    public init() {}

    public nonisolated static var permission: AVAudioApplication.recordPermission {
        AVAudioApplication.shared.recordPermission
    }

    public nonisolated static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    /// Must be called while the app is in the foreground. Keeps running in the background thanks
    /// to the `audio` background mode.
    public func start() throws {
        guard !isRunning else { return }
        guard Self.permission == .granted else { throw AudioCaptureError.permissionDenied }

        let session = AVAudioSession.sharedInstance()
        // mixWithOthers: a warm microphone must not stop the user's music or podcast.
        try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .allowBluetooth, .defaultToSpeaker])
        try session.setActive(true)

        guard installTap() else { throw AudioCaptureError.noInputDevice }
        engine.prepare()
        try engine.start()
        isRunning = true
        observeSession()
    }

    public func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        removeObservers()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// Installs the tap with the input's current format. False if there is no usable input.
    private func installTap() -> Bool {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return false }
        input.removeTap(onBus: 0)
        let handler = onBuffer
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            handler?(buffer)
        }
        return true
    }

    private func observeSession() {
        removeObservers()
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
                guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
                MainActor.assumeIsolated { self?.handleLoss() }
            },
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleLoss() }
            },
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
                // A headset change swaps the input format; restart the tap with the new format.
                guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                      let reason = AVAudioSession.RouteChangeReason(rawValue: raw),
                      reason == .newDeviceAvailable || reason == .oldDeviceUnavailable else { return }
                MainActor.assumeIsolated { self?.restartTap() }
            },
        ]
    }

    private func removeObservers() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    private func restartTap() {
        guard isRunning else { return }
        engine.stop()
        guard installTap() else { handleLoss(); return }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            handleLoss()
        }
    }

    private func handleLoss() {
        guard isRunning else { return }
        stop()
        onInterruption?()
    }
}

/// Converts whatever the microphone delivers to a target format (sample rate, channels, sample
/// type). One converter per stream; call from a single thread.
public final class PCMConverter {
    public let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    public init(outputFormat: AVAudioFormat) {
        self.outputFormat = outputFormat
    }

    public func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        if buffer.format == outputFormat { return buffer }
        if converter == nil || inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
            converter?.primeMethod = .none
            inputFormat = buffer.format
        }
        guard let converter else { throw ConversionError.unsupported }
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { throw ConversionError.allocation }
        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error { throw conversionError ?? ConversionError.unsupported }
        return output
    }

    public enum ConversionError: Error {
        case unsupported
        case allocation
    }
}

extension AVAudioPCMBuffer {
    /// Mono float samples (first channel) for level metering.
    var firstChannelSamples: UnsafeBufferPointer<Float>? {
        guard let data = floatChannelData else { return nil }
        return UnsafeBufferPointer(start: data[0], count: Int(frameLength))
    }
}
#endif
