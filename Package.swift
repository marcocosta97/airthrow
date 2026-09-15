// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AirPlayer",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AirPlayerApp", targets: ["AirPlayerApp"]),
        .executable(name: "airplayer", targets: ["AirPlayerCLI"])
    ],
    targets: [
        .target(name: "AirPlayerCore"),
        .executableTarget(name: "AirPlayerApp", dependencies: ["AirPlayerCore"]),
        .executableTarget(name: "AirPlayerCLI", dependencies: ["AirPlayerCore"]),
        .executableTarget(name: "CoreChecks", dependencies: ["AirPlayerCore"], path: "Tests/CoreChecks")
    ]
)
