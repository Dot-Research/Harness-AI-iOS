// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Harness",
    platforms: [.iOS("26.0"), .macOS(.v14)],
    products: [.library(name: "HarnessCore", targets: ["HarnessCore"])],
    targets: [
        // No pkg-config: on a Mac with Homebrew's sqlite, Xcode would link Homebrew's macOS library
        // into the iOS app. Apple SDKs ship SQLite; on Linux install libsqlite3-dev.
        .systemLibrary(name: "CSQLite"),
        .target(name: "HarnessCore", dependencies: ["CSQLite"]),
        .testTarget(name: "HarnessCoreTests", dependencies: ["HarnessCore"])
    ],
    swiftLanguageModes: [.v5]
)
