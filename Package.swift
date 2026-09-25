// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TypingPetMac",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "TypingPet", targets: ["TypingPet"])
    ],
    targets: [
        .executableTarget(
            name: "TypingPet",
            exclude: ["Resources"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "TypingPetTests",
            dependencies: ["TypingPet"]
        )
    ]
)
