import Foundation
#if canImport(FoundationModels)
import FoundationModels

@Generable
struct SummaryWriting {
    @Guide(description: "검토 결과 전체를 실무자에게 알리는 보고서 문체(~다) 한국어 3~4문장")
    var summary: String
}

@Generable
struct VerdictWriting {
    @Guide(description: "이 판정이 무엇을 확인했고 왜 이런 결과가 나왔는지 보고서 문체(~다) 한국어 2~3문장")
    var explanation: String
    @Guide(description: "도면 작성자가 다음에 확인하거나 보완할 일. 항목마다 보고서 문체 한 문장", .count(1...3))
    var nextSteps: [String]
}
#endif

/// 보고서 서술 — Apple 기기 내 모델(FoundationModels). 도면·결과는 기기 밖으로 나가지 않는다.
/// 같은 입력에 같은 글이 나오도록 탐욕 샘플링을 쓰고, 판정마다 새 세션을 연다(앞 판정 내용이 섞이지 않게).
public struct OnDeviceReportNarrator: ReportNarrating {
    public init() {}

    public var modelName: String { "Apple 기기 내 모델(FoundationModels)" }

    public static var isAvailable: Bool { PlainLanguageDrafter.isAvailable }

    static let instructions = """
    너는 소방 도면 사전검토 보고서를 쓰는 작성자다. 독자는 다중이용업소 영업장을 설계·시공하는 실무자다.
    규칙:
    1. 주어진 「사실」과 「조문」에 있는 내용만 쓴다. 사실에 없는 숫자·면적·거리·날짜·조항 번호를 만들지 않는다.
    2. 판정 색과 결과는 사실에 적힌 그대로 전한다. 더 좋게도 더 나쁘게도 바꾸지 않는다.
    3. 「적합」「부적합」「안전하다」「위반이다」처럼 단정하는 말을 쓰지 않는다. 전문가 감수 전 결과다.
    4. 벌금·과태료 금액·공사비·손해액을 쓰지 않는다.
    5. 보고서 문체(~다)로 간결하게 쓴다.
    """

    public func summary(facts: String) async -> String? {
        #if canImport(FoundationModels)
        guard Self.isAvailable else { return nil }
        do {
            let session = LanguageModelSession(instructions: Self.instructions)
            let response = try await session.respond(to: "사실:\n\(facts)\n\n검토 결과 전체 요약을 써라.", generating: SummaryWriting.self,
                                                     options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 400))
            return response.content.summary
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    public func verdict(facts: String, passages: String) async -> (explanation: String, nextSteps: [String])? {
        #if canImport(FoundationModels)
        guard Self.isAvailable else { return nil }
        do {
            let session = LanguageModelSession(instructions: Self.instructions)
            let prompt = "사실:\n\(facts)\n\n조문:\n\(passages)\n\n이 판정의 설명과 확인·보완할 일을 써라."
            let response = try await session.respond(to: prompt, generating: VerdictWriting.self,
                                                     options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 500))
            return (response.content.explanation, response.content.nextSteps)
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }
}
