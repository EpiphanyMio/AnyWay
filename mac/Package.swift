// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AnyWay",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "AnyWay", targets: ["AnyWay"])],
    targets: [
        .executableTarget(name: "AnyWay"),
        .testTarget(name: "AnyWayTests", dependencies: ["AnyWay"])
    ]
)
