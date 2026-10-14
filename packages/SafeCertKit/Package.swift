// swift-tools-version: 6.2
import PackageDescription

// SafeCert 사전 파일럿의 순수 로직. 외부 라이브러리 없이 Apple 퍼스트파티 프레임워크만 쓴다
// (Foundation · CoreGraphics · PDFKit · CoreText · CryptoKit · Vision). 생성형 AI 는 외부 LLM(Gemini) 을 URLSession 으로 부른다.
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
