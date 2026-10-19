// swift-tools-version:5.9
import PackageDescription

// BummyTunesCore is deliberately platform-independent: it builds and runs on
// macOS so the whole engine can be verified here, then compiles unchanged for
// iOS. Verification is a plain executable rather than XCTest so it does not
// depend on a test harness this toolchain may not ship.
let package = Package(
    name: "BummyTunes",
    platforms: [.macOS(.v12), .iOS(.v16)],
    products: [
        .library(name: "BummyTunesCore", targets: ["BummyTunesCore"]),
        .executable(name: "bummy-verify", targets: ["BummyVerify"]),
    ],
    targets: [
        .target(name: "COnnxRuntime"),
        .target(
            name: "BummyTunesCore",
            dependencies: ["COnnxRuntime"],
            linkerSettings: [
                // macOS verification links Homebrew's dylib. The iOS build
                // links the xcframework slice instead, wired in build-ios.sh.
                .unsafeFlags(["-L/opt/homebrew/opt/onnxruntime/lib", "-lonnxruntime"],
                             .when(platforms: [.macOS]))
            ]
        ),
        .executableTarget(name: "BummyVerify", dependencies: ["BummyTunesCore"]),
    ]
)
