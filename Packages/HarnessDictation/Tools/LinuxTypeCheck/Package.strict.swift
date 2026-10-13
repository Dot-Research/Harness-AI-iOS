// swift-tools-version: 6.0
import PackageDescription
let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]
let package = Package(
    name: "TypeCheck",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "AVFoundation", swiftSettings: v5),
        .target(name: "Speech", dependencies: ["AVFoundation"], swiftSettings: v5),
        .target(name: "FoundationModels", swiftSettings: v5),
        .target(name: "Network", swiftSettings: v5),
        .target(name: "Combine", swiftSettings: v5),
        .target(name: "UIKit", dependencies: ["ObjectiveC"], swiftSettings: v5),
        .target(name: "DictationCore", swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "DictationEngine", dependencies: ["DictationCore", "AVFoundation", "Speech", "FoundationModels", "Network", "Combine"], swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]),
        .target(name: "KeyboardLogic", dependencies: ["DictationCore", "DictationEngine", "UIKit", "Combine"], swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]),
        .target(name: "HostLogic", dependencies: ["DictationCore", "DictationEngine", "AVFoundation", "Combine"], swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]),
        .target(name: "ObjectiveC", swiftSettings: v5),
        .target(name: "UniformTypeIdentifiers", swiftSettings: v5),
        .target(name: "SwiftUI", dependencies: ["UIKit", "Combine", "UniformTypeIdentifiers"], swiftSettings: v5),
        .target(name: "HarnessKeyboardKit", dependencies: ["DictationCore", "DictationEngine", "UIKit", "SwiftUI", "Combine", "ObjectiveC"], swiftSettings: v5),
        .target(name: "DictationAppKit", dependencies: ["DictationCore", "DictationEngine", "SwiftUI", "UIKit", "AVFoundation", "Speech", "Combine", "UniformTypeIdentifiers"], swiftSettings: v5),
        .target(name: "KeyboardExtension", dependencies: ["HarnessKeyboardKit"], swiftSettings: v5),
    ]
)
