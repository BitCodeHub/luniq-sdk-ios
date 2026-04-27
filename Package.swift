// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LuniqSDK",
    platforms: [.iOS(.v13)],
    products: [
        .library(name: "LuniqSDK", targets: ["LuniqSDK"]),
    ],
    targets: [
        .target(
            name: "LuniqSDK",
            path: "Sources/LuniqSDK",
            linkerSettings: [
                .linkedFramework("UIKit"),
                .linkedFramework("Foundation"),
            ]
        ),
        .testTarget(
            name: "LuniqSDKTests",
            dependencies: ["LuniqSDK"],
            path: "Tests/LuniqSDKTests"
        ),
    ]
)
