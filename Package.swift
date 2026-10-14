// swift-tools-version: 6.0
import PackageDescription

let gifskiLibDir = Context.packageDirectory + "/Vendor/lib"

let package = Package(
    name: "GifTrim",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "GifTrim", targets: ["GifTrim"]),
        .executable(name: "giftrim-cli", targets: ["giftrim-cli"]),
        .library(name: "GifTrimCore", targets: ["GifTrimCore"]),
    ],
    targets: [
        // C bridge to libgifski (built by scripts/build-gifski.sh into Vendor/lib).
        .target(
            name: "CGifski",
            linkerSettings: [
                .unsafeFlags(["-L", gifskiLibDir]),
                .linkedLibrary("gifski"),
            ]
        ),
        .target(
            name: "GifTrimCore",
            dependencies: ["CGifski"]
        ),
        .executableTarget(
            name: "GifTrim",
            dependencies: ["GifTrimCore"],
            exclude: ["Resources"]
        ),
        .executableTarget(
            // Installed as `giftrim` (the build name differs only because macOS paths are
            // case-insensitive and would collide with the GifTrim app binary).
            name: "giftrim-cli",
            dependencies: ["GifTrimCore"],
            path: "Sources/GifTrimCLI"
        ),
        .testTarget(
            name: "GifTrimCoreTests",
            dependencies: ["GifTrimCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
