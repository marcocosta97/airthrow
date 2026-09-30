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
        .target(name: "AirThrowCore", resources: [.copy("SourceProviders")]),
        .executableTarget(name: "AirThrowApp", dependencies: ["AirThrowCore"]),
        .executableTarget(name: "AirThrowCLI", dependencies: ["AirThrowCore"]),
        .executableTarget(name: "CoreChecks", dependencies: ["AirThrowCore"], path: "Tests/CoreChecks"),
        .executableTarget(name: "SourceRegistryChecks", dependencies: ["AirThrowCore"], path: "Tests/SourceRegistryChecks")
    ]
)
