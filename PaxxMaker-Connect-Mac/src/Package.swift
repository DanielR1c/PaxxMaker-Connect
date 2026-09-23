// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PaxxMakerConnect",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "PaxxMakerConnect",
            path: "Sources/PaxxMakerConnect",
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        )
    ]
)
