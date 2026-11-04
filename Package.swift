// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WGCNE",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "WGCNE", targets: ["WGCNE"])],
    targets: [
        .target(name: "WGCNE", path: "apple/Sources/WGCNE"),
        .testTarget(name: "WGCNETests", dependencies: ["WGCNE"], path: "apple/Tests/WGCNETests")
    ],
    swiftLanguageVersions: [.v5]
)
