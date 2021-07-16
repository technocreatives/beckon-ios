// swift-tools-version:5.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Beckon",
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        .library(
            name: "Beckon",
            targets: ["Beckon"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ReactiveX/RxSwift.git", .exact("6.2.0")),
        .package(name: "RxFeedback", url: "https://github.com/NoTests/RxFeedback.swift", .exact("4.0.0")),
    ],
    targets: [
        .target(
            name: "Beckon",
            dependencies: ["RxSwift", .product(name: "RxCocoa", package: "RxSwift"), "RxFeedback"]),
    ]
)
