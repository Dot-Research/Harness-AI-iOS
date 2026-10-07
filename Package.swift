// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Harness",
    platforms: [.iOS("26.0"), .macOS(.v14)],
    products: [.library(name: "HarnessCore", targets: ["HarnessCore"])],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3", providers: [.apt(["libsqlite3-dev"]), .brew(["sqlite3"])]),
        .target(name: "HarnessCore", dependencies: ["CSQLite"]),
        .testTarget(name: "HarnessCoreTests", dependencies: ["HarnessCore"])
    ],
    swiftLanguageModes: [.v5]
)
