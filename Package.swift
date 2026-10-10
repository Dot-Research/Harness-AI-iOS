// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Harness",
    platforms: [.iOS("26.0"), .macOS(.v14)],
    products: [.library(name: "HarnessCore", targets: ["HarnessCore"])],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3", providers: [.apt(["libsqlite3-dev"]), .brew(["sqlite3"])]),
        // Xcode builds don't autolink the library named in CSQLite's module map (the app failed to link),
        // so link it explicitly. libsqlite3 ships with Apple SDKs; Linux gets it from libsqlite3-dev.
        .target(name: "HarnessCore", dependencies: ["CSQLite"], linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(name: "HarnessCoreTests", dependencies: ["HarnessCore"])
    ],
    swiftLanguageModes: [.v5]
)
