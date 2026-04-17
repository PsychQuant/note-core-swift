// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NoteCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "NoteCore", targets: ["NoteCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.0"),
    ],
    targets: [
        .target(
            name: "NoteCore",
            dependencies: [
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ]
        ),
        .testTarget(
            name: "NoteCoreTests",
            dependencies: ["NoteCore"]
        ),
    ]
)
