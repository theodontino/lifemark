// swift-tools-version: 6.4
import PackageDescription
let package = Package(name: "LifeUI", platforms: [.iOS(.v17), .macOS(.v14)], products: [.library(name: "LifeUI", targets: ["LifeUI"])], dependencies: [.package(path: "../LifeCore"), .package(path: "../LifeStore")], targets: [.target(name: "LifeUI", dependencies: ["LifeCore", "LifeStore"])], swiftLanguageModes: [.v5])
