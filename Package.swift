// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PortableMemory",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "PortableMemory", targets: ["PortableMemory"]),
    ],
    dependencies: [
        // The only dependency: SHA-256 for content hashing + checksums. swift-crypto
        // gives the same API on Apple platforms AND Linux, so adopters aren't locked to
        // Apple. Nothing else — the format is plain JSONL + a manifest.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        .target(
            name: "PortableMemory",
            dependencies: [.product(name: "Crypto", package: "swift-crypto")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PortableMemoryTests",
            dependencies: ["PortableMemory"]
        ),
    ]
)
