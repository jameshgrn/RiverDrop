// swift-tools-version: 5.10
import PackageDescription
let package = Package(
    name: "dummy",
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.11.1")
    ],
    targets: [
        .executableTarget(name: "dummy", dependencies: ["Citadel"])
    ]
)
