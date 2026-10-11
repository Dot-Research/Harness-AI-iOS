// Minimal stand-ins for Apple's AVFoundation, shaped like the real Swift API, so the dictation
// engine's own logic can be type-checked on Linux. Bodies are fatalError: never executed.
@_exported import Foundation

public typealias AVAudioFrameCount = UInt32
public typealias AVAudioPacketCount = UInt32
public typealias AVAudioNodeBus = Int

public enum AVAudioCommonFormat: UInt, Sendable { case otherFormat, pcmFormatFloat32, pcmFormatFloat64, pcmFormatInt16, pcmFormatInt32 }

open class AVAudioFormat: NSObject, @unchecked Sendable {
    public var sampleRate: Double { fatalError() }
    public var channelCount: UInt32 { fatalError() }
    public init?(commonFormat: AVAudioCommonFormat, sampleRate: Double, channels: UInt32, interleaved: Bool) { fatalError() }
}

open class AVAudioBuffer: NSObject, NSCopying {
    public func copy(with zone: NSZone? = nil) -> Any { fatalError() }
}

open class AVAudioPCMBuffer: AVAudioBuffer {
    public var format: AVAudioFormat { fatalError() }
    public var frameLength: AVAudioFrameCount { get { fatalError() } set {} }
    public var frameCapacity: AVAudioFrameCount { fatalError() }
    public var floatChannelData: UnsafePointer<UnsafeMutablePointer<Float>>? { fatalError() }
    public init?(pcmFormat: AVAudioFormat, frameCapacity: AVAudioFrameCount) { fatalError() }
}

open class AVAudioTime: NSObject {}

open class AVAudioNode: NSObject {
    public func outputFormat(forBus bus: AVAudioNodeBus) -> AVAudioFormat { fatalError() }
    public func installTap(onBus bus: AVAudioNodeBus, bufferSize: AVAudioFrameCount, format: AVAudioFormat?, block: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) { fatalError() }
    public func removeTap(onBus bus: AVAudioNodeBus) { fatalError() }
}

open class AVAudioInputNode: AVAudioNode {}

open class AVAudioEngine: NSObject {
    public override init() {}
    public var inputNode: AVAudioInputNode { fatalError() }
    public func prepare() { fatalError() }
    public func start() throws { fatalError() }
    public func stop() { fatalError() }
}

public typealias NSErrorPointer = UnsafeMutablePointer<NSError?>?
public enum AVAudioConverterInputStatus: Int { case haveData, noDataNow, endOfStream }
public enum AVAudioConverterOutputStatus: Int { case haveData, inputRanDry, endOfStream, error }
public enum AVAudioConverterPrimeMethod: Int { case pre, normal, none }
public typealias AVAudioConverterInputBlock = (AVAudioPacketCount, UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer?

open class AVAudioConverter: NSObject {
    public init?(from fromFormat: AVAudioFormat, to toFormat: AVAudioFormat) { fatalError() }
    public var primeMethod: AVAudioConverterPrimeMethod { get { fatalError() } set {} }
    public func convert(to outputBuffer: AVAudioBuffer, error outError: NSErrorPointer, withInputFrom inputBlock: AVAudioConverterInputBlock) -> AVAudioConverterOutputStatus { fatalError() }
}

public let AVAudioSessionInterruptionTypeKey = "AVAudioSessionInterruptionTypeKey"
public let AVAudioSessionRouteChangeReasonKey = "AVAudioSessionRouteChangeReasonKey"

open class AVAudioSession: NSObject {
    public static func sharedInstance() -> AVAudioSession { fatalError() }

    public struct Category: Hashable, Sendable {
        public static let playAndRecord = Category()
        public static let record = Category()
    }

    public struct Mode: Hashable, Sendable {
        public static let `default` = Mode()
    }

    public struct CategoryOptions: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let mixWithOthers = CategoryOptions(rawValue: 1)
        public static let allowBluetooth = CategoryOptions(rawValue: 4)
        public static let defaultToSpeaker = CategoryOptions(rawValue: 8)
    }

    public struct SetActiveOptions: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let notifyOthersOnDeactivation = SetActiveOptions(rawValue: 1)
    }

    public enum InterruptionType: UInt { case began = 1, ended = 0 }
    public enum RouteChangeReason: UInt { case unknown, newDeviceAvailable, oldDeviceUnavailable, categoryChange, override, wakeFromSleep, noSuitableRouteForCategory, routeConfigurationChange }

    public static let interruptionNotification = Notification.Name("AVAudioSessionInterruptionNotification")
    public static let mediaServicesWereResetNotification = Notification.Name("AVAudioSessionMediaServicesWereResetNotification")
    public static let routeChangeNotification = Notification.Name("AVAudioSessionRouteChangeNotification")

    public func setCategory(_ category: Category, mode: Mode, options: CategoryOptions = []) throws { fatalError() }
    public func setActive(_ active: Bool, options: SetActiveOptions = []) throws { fatalError() }
}

open class AVAudioApplication: NSObject {
    public static var shared: AVAudioApplication { fatalError() }
    public enum recordPermission: Int { case undetermined, denied, granted }
    public static func requestRecordPermission() async -> Bool { fatalError() }
}

extension AVAudioApplication {
    public var recordPermission: AVAudioApplication.recordPermission { fatalError() }
}
