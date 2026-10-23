// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HSShot",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "HSShot", targets: ["HSShot"])],
    targets: [
        .executableTarget(name: "HSShot", path: "Sources/HSShot"),
        .testTarget(name: "HSShotTests", dependencies: ["HSShot"], path: "Tests/HSShotTests")
    ],
    swiftLanguageVersions: [.v5]
)
