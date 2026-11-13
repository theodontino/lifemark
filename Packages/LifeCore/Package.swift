// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "LifeCore", platforms: [.macOS(.v14), .iOS(.v17)], products: [.library(name: "LifeCore", targets: ["LifeCore"])], targets: [.target(name: "LifeCore"), .testTarget(name: "LifeCoreTests", dependencies: ["LifeCore"])], swiftLanguageVersions: [.v5])
