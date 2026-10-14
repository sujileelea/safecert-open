import Foundation
import SafeCertKit
import Security

/// 인증값·API 키를 키체인에 둔다. 값은 화면·로그에 출력하지 않는다.
enum KeychainStore {
    private static let service = "com.alnair.safecert"
    private static let lawAccount = "law-api-oc"
    private static let geminiAccount = "gemini-api-key"

    /// 국가법령정보 API 인증값(OC).
    static var lawOC: String? { read(lawAccount) }
    static func setLawOC(_ value: String?) { write(lawAccount, value) }

    /// 외부 생성형 LLM(Google Gemini) API 키.
    static var geminiKey: String? { read(geminiAccount) }
    static func setGeminiKey(_ value: String?) { write(geminiAccount, value) }

    /// 키가 있으면 Gemini 호출기, 없으면 nil(보고서·쉬운 말 요약은 AI 없이).
    static var gemini: GeminiClient? { geminiKey.map { GeminiClient(apiKey: $0) } }

    private static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        let value = String(decoding: data, as: UTF8.self)
        return value.isEmpty ? nil : value
    }

    private static func write(_ account: String, _ value: String?) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}
