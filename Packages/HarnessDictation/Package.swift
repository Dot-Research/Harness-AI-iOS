// swift-tools-version: 6.0
//
// HarnessDictation — the Dictation tab, Harness Keyboard and the dictation engine behind them.
//
// Targets
//   DictationCore      Pure Swift. Text cleanup, personal dictionary, routing, the keyboard <-> app
//                      bridge protocol, the warm-session state machine, audio math, transcription API
//                      request building. Builds and tests on Linux and Apple platforms.
//   DictationEngine    iOS. Microphone capture, on-device SpeechAnalyzer transcription, paired-computer
//                      and cloud transcription, Foundation Models rewriting, App Group bridge, Keychain.
//                      Extension-safe: no UIApplication, usable from the keyboard.
//   HarnessKeyboardKit iOS. The keyboard extension's view controller, view model and SwiftUI views.
//   DictationAppKit    iOS, app target only. DictationHost (owns the microphone and runs the pipeline)
//                      and the Dictation tab: setup, try-it, modes, routing, dictionary, history.

import PackageDescription

let package = Package(
    name: "HarnessDictation",
    platforms: [
        .iOS("26.0"),
        .macOS("26.0"),
    ],
    products: [
        .library(name: "DictationCore", targets: ["DictationCore"]),
        .library(name: "DictationEngine", targets: ["DictationEngine"]),
        .library(name: "HarnessKeyboardKit", targets: ["HarnessKeyboardKit"]),
        .library(name: "DictationAppKit", targets: ["DictationAppKit"]),
    ],
    targets: [
        .target(
            name: "DictationCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "DictationEngine",
            dependencies: ["DictationCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "HarnessKeyboardKit",
            dependencies: ["DictationCore", "DictationEngine"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "DictationAppKit",
            dependencies: ["DictationCore", "DictationEngine"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "DictationCoreTests",
            dependencies: ["DictationCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
