import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// 「쉬운 말 요약」 초안 — Apple 기기 내 모델(FoundationModels).
/// 판정이 끝난 뒤에만 쓰고, 결과는 판정에 되돌아가지 않는다. 사실 대조에 실패하면 버린다.
public enum PlainLanguageDrafter {
    public static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if case .available = SystemLanguageModel.default.availability { return true }
        #endif
        return false
    }

    public static func facts(_ r: AnalysisResult) -> String {
        var lines = ["전체: \(r.summary.headline)"]
        for v in r.verdicts {
            lines.append("- \(v.title) / \(v.target) / \(v.color.meaning) / \(v.summary)")
        }
        return lines.joined(separator: "\n")
    }

    public static func draft(for r: AnalysisResult) async -> String? {
        #if canImport(FoundationModels)
        guard isAvailable else { return nil }
        let instructions = """
        너는 소방 안전 검토 결과를 건물주에게 설명하는 도우미다.
        주어진 사실만 사용해 쉬운 한국어 3~4문장으로 요약한다.
        사실에 없는 숫자·법령·기한·벌금·비용을 만들지 않는다.
        「적합」「부적합」이라는 단어를 쓰지 않는다. 전문가 확인 전 결과임을 마지막 문장에 밝힌다.
        """
        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: "사실:\n\(facts(r))")
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return isGrounded(text, facts: facts(r)) ? text : nil
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    /// 사실 대조: 초안의 모든 숫자가 사실에 있어야 하고, 금지어가 없어야 한다.
    public static func isGrounded(_ text: String, facts: String) -> Bool {
        guard !text.isEmpty else { return false }
        let forbidden = ["부적합", "적합합니다", "적합하", "벌금", "과태료", "만원", "억원"]
        if forbidden.contains(where: { text.contains($0) }) { return false }
        let numbers = { (s: String) -> Set<String> in
            Set(s.matches(of: /\d+(?:\.\d+)?/).map { String($0.output) })
        }
        return numbers(text).isSubset(of: numbers(facts))
    }
}
