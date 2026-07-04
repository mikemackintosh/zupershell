// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "zupershell",
    platforms: [.macOS(.v13)],
    dependencies: [
        // Miguel de Icaza's terminal core: VT parser + grid + a drawable NSView.
        // We stand on this so we don't hand-write the VT500 state machine on day one.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", branch: "main")
    ],
    targets: [
        .executableTarget(
            name: "zupershell",
            dependencies: ["SwiftTerm"]
        )
    ],
    // Pin to Swift 5 language mode to avoid Swift 6 strict-concurrency errors in a starter.
    swiftLanguageVersions: [.v5]
)
