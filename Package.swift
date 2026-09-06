// swift-tools-version: 5.9
import PackageDescription

// Layout:
//  - MacMusicPluginKit: all logic + SwiftUI views (a library, so it is testable).
//  - MacMusicPlugin:     the thin @main executable that hosts the MenuBarExtra.
//  - MMPTests:           a plain executable test suite. XCTest / `swift test` is
//                        unavailable under the Command Line Tools (no full Xcode),
//                        so `swift run MMPTests` runs the suite, locally and in CI.
let package = Package(
    name: "MacMusicPlugin",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .target(
            name: "MacMusicPluginKit",
            path: "Sources/MacMusicPluginKit",
            swiftSettings: [
                // Lets MMPTests reach internal symbols via `@testable import`.
                .unsafeFlags(["-enable-testing"], .when(configuration: .debug))
            ]
        ),
        .executableTarget(
            name: "MacMusicPlugin",
            dependencies: ["MacMusicPluginKit"],
            path: "Sources/MacMusicPlugin"
        ),
        .executableTarget(
            name: "MMPTests",
            dependencies: ["MacMusicPluginKit"],
            path: "Tests/MMPTests"
        ),
    ]
)
