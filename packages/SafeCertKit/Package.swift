// swift-tools-version: 6.2
import PackageDescription

// SafeCert 사전 파일럿의 순수 로직. Apple 퍼스트파티 프레임워크만 쓴다
// (Foundation · CoreGraphics · PDFKit · CoreText · CryptoKit · FoundationModels).
let package = Package(
    name: "SafeCertKit",
    defaultLocalization: "ko",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "SafeCertKit", targets: ["SafeCertKit"])
    ],
    targets: [
        .target(
            name: "SafeCertKit",
            resources: [.copy("Resources/LawSeed")]
        ),
        .testTarget(
            name: "SafeCertKitTests",
            dependencies: ["SafeCertKit"]
        )
    ]
)
