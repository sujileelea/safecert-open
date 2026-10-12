import Foundation

/// SafeCertKit 버전·리소스 진입점.
public enum SafeCertKit {
    public static let version = "0.1.0-pilot"

    /// 번들에 녹화된 법령 초기값 폴더(2026-10-12 국가법령정보 공동활용 API 응답).
    public static var lawSeedDirectory: URL? {
        Bundle.module.url(forResource: "LawSeed", withExtension: nil)
    }
}
