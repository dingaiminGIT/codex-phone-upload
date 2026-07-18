// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "CodexPhoneUploadMenu",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "CodexPhoneUpload", targets: ["CodexPhoneUploadMenu"])
    ],
    targets: [
        .target(
            name: "CodexPhoneUploadCore",
            path: "Sources/CodexPhoneUploadCore"
        ),
        .executableTarget(
            name: "CodexPhoneUploadMenu",
            dependencies: ["CodexPhoneUploadCore"],
            path: "Sources/CodexPhoneUploadMenu"
        ),
        .executableTarget(
            name: "CodexPhoneUploadSelfTests",
            dependencies: ["CodexPhoneUploadCore"],
            path: "Tests/CodexPhoneUploadMenuTests"
        )
    ]
)
