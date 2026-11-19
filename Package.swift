// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AltVM",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AltVMCore", targets: ["AltVMCore"]),
        .executable(name: "avm", targets: ["avm"]),
        .executable(name: "AltVM", targets: ["AltVMApp"]),
    ],
    targets: [
        .target(
            name: "AltVMCore",
            linkerSettings: [
                .linkedFramework("Virtualization"),
                .linkedFramework("IOKit"),
                .linkedFramework("CryptoKit"),
            ]
        ),
        .executableTarget(name: "avm", dependencies: ["AltVMCore"]),
        .executableTarget(name: "AltVMApp", dependencies: ["AltVMCore"]),
        .testTarget(name: "AltVMCoreTests", dependencies: ["AltVMCore"]),
    ],
    swiftLanguageModes: [.v5
    ]
)
