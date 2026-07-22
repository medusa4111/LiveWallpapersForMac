// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LiveWallpapersForMac",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Live Wallpapers for Mac", targets: ["LiveWallpapersForMac"])
    ],
    targets: [
        .executableTarget(name: "LiveWallpapersForMac")
    ],
    swiftLanguageVersions: [.v5]
)
