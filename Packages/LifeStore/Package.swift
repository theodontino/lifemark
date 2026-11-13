// swift-tools-version: 6.4
import PackageDescription
let package = Package(
    name: "LifeStore", platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "LifeStore", targets: ["LifeStore"])],
    dependencies: [.package(path: "../LifeCore"), .package(url: "https://github.com/pointfreeco/sqlite-data", exact: "1.13.0"), .package(url: "https://github.com/groue/GRDB.swift", from: "7.6.0")],
    targets: [
        .target(name: "LifeStore", dependencies: ["LifeCore", .product(name: "SQLiteData", package: "sqlite-data"), .product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "LifeStoreTests", dependencies: ["LifeStore", "LifeCore"])
    ]
)
