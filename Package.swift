// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SVSLabelRenamer",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SVSLabelRenamer", targets: ["SVSLabelRenamer"])
    ],
    targets: [
        .executableTarget(name: "SVSLabelRenamer"),
        .target(name: "SVSQuickLookCore"),
        .testTarget(
            name: "SVSLabelRenamerTests",
            dependencies: ["SVSLabelRenamer", "SVSQuickLookCore"]
        )
    ]
)
