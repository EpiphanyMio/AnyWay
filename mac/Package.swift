// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AnyWay",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "LocationSimulator", targets: ["LocationSimulator"])],
    targets: [
        .executableTarget(name: "LocationSimulator"),
        .testTarget(name: "LocationSimulatorTests", dependencies: ["LocationSimulator"])
    ]
)
