// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AirThrow",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AirThrowApp", targets: ["AirThrowApp"]),
        .executable(name: "athrow", targets: ["AirThrowCLI"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "AirThrowCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "AirThrowApp", dependencies: ["AirThrowCore"]),
        .executableTarget(name: "AirThrowCLI", dependencies: ["AirThrowCore"]),
        .executableTarget(name: "CoreChecks", dependencies: ["AirThrowCore"], path: "Tests/CoreChecks"),
        .executableTarget(name: "PlaybackLogChecks", dependencies: ["AirThrowCore"], path: "Tests/PlaybackLogChecks"),
        .executableTarget(name: "SourceRegistryChecks", dependencies: ["AirThrowCore"], path: "Tests/SourceRegistryChecks"),
        .executableTarget(name: "NativePreparationChecks", dependencies: ["AirThrowCore"], path: "Tests/NativePreparationChecks"),
        .executableTarget(name: "SuperResolutionBench", path: "Tests/SuperResolutionBench"),
        .executableTarget(name: "SuperResolutionChecks", dependencies: ["AirThrowCore"], path: "Tests/SuperResolutionChecks")
    ]
)
