// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "zupershell",
    platforms: [.macOS(.v13)],
    dependencies: [
        // Miguel de Icaza's terminal core: VT parser + grid + a drawable NSView.
        // We stand on this so we don't hand-write the VT500 state machine on day one.
        // Pinned to a fork carrying the cursorUpdate perf patch (guards against
        // per-mouseMoved NSCursor.set() → AXFMouseCursorGenerator regeneration,
        // ~17% CPU when the pointer sits over the terminal). Drop the fork once
        // upstream merges the fix.
        .package(url: "https://github.com/mikemackintosh/SwiftTerm",
                 revision: "c8b9031")
    ],
    targets: [
        .executableTarget(
            name: "zupershell",
            dependencies: ["SwiftTerm"],
            resources: [.copy("Resources/menus.default.json")]
        )
    ],
    // Pin to Swift 5 language mode to avoid Swift 6 strict-concurrency errors in a starter.
    swiftLanguageVersions: [.v5]
)
