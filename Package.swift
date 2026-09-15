// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "CookConsoleCore",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "CookConsole", targets: ["CookConsole"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/groue/GRDB.swift.git",
            exact: "7.11.1"
        ),
    ],
    targets: [
        .target(
            name: "CookConsole",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/CookConsole",
            exclude: [
                "Application",
                "Features",
                "ContentView.swift",
                "CookConsoleApp.swift",
            ]
        ),
        .testTarget(
            name: "CookConsoleTests",
            dependencies: ["CookConsole"],
            path: "Tests/CookConsoleTests"
        ),
    ]
)
