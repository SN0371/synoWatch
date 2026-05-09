// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SynoWatch",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "SynoWatch",
            path: "Sources/SynoWatch"
        ),
    ]
)
