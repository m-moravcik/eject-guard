// swift-tools-version: 5.9
import PackageDescription

// This package exists for the tests, not for shipping.
//
// The app and the CLI are assembled by build.sh, which compiles the same Core
// sources straight into each binary and wraps the app in its bundle. Declaring
// Core as a library here lets `swift test` reach it with @testable, so nothing
// in Core has to be made public and the shipping build is untouched.
let package = Package(
    name: "TMEjectGuard",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "TMEjectGuardCore", path: "Sources/Core"),
        .testTarget(
            name: "TMEjectGuardCoreTests",
            dependencies: ["TMEjectGuardCore"],
            path: "Tests"),
    ]
)
