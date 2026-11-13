// swift-tools-version: 6.4
import PackageDescription
let package = Package(
    name: "LifeNearby", platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "LifeNearby", targets: ["LifeNearby"])],
    dependencies: [.package(path: "../LifeStore")],
    targets: [.target(name: "LifeNearby", dependencies: ["LifeStore"]), .testTarget(name: "LifeNearbyTests", dependencies: ["LifeNearby", "LifeStore"])]
)
