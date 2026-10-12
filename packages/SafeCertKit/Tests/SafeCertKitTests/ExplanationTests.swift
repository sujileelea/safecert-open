import Foundation
import Testing
@testable import SafeCertKit

@Suite("설명")
struct ExplanationTests {
    @Test func sevenSectionsWithVerbatimLawText() async throws {
        let snap = await LawSync.run(fetcher: try #require(BundledLawFetcher.bundled), previous: nil, isSeed: true, now: RuleEngineTests.day)
        let page = try VectorPDF.read(SamplePlanRenderer.pdf(for: .risky))
        let plan = PlanInterpreter.interpret(page)
        var scale = ScaleEstimator.estimate(page)
        scale?.confirmed = true
        let r = RuleEngine.evaluate(.init(plan: plan, scale: scale, conditions: Conditions(), snapshot: snap))
        let v = try #require(r.verdicts.first { $0.rule == .exitLocation })
        let e = ExplanationComposer.explain(v, result: r, plan: plan, snapshot: snap)
        #expect(e.sections.map(\.number) == [1, 2, 3, 4, 5, 6, 7])
        #expect(e.sections[4].lines.contains("검토 상태: 전문가 미확인(감수 전)"))
        let cite = try #require(e.citations.first { $0.key == .ruleExitLocation })
        #expect(cite.text == snap.clause(.ruleExitLocation)?.text)
        #expect(e.lawStatus.first?.contains(snap.baseDate) == true)
        #expect(e.sections[0].lines[0].contains("영업장"))

        let n = ExplanationComposer.narrative(r)
        #expect(n.first?.contains("감수 전") == true)
        #expect(n.contains { $0.hasPrefix("의무 미충족") })
        #expect(!n.joined().contains("부적합"))
    }

    @Test func groundingFilter() {
        let facts = "전체: 판정 유보 — 확인 필요 2건\n- 비상구 위치 / 이격거리 4.83m < 기준 9.43m"
        #expect(PlainLanguageDrafter.isGrounded("비상구가 주출입구에서 4.83m 떨어져 기준 9.43m보다 가깝습니다. 전문가 확인 전 결과입니다.", facts: facts))
        #expect(!PlainLanguageDrafter.isGrounded("비상구가 3m 떨어져 있습니다.", facts: facts))
        #expect(!PlainLanguageDrafter.isGrounded("이 영업장은 부적합합니다.", facts: facts))
        #expect(!PlainLanguageDrafter.isGrounded("과태료가 부과될 수 있습니다.", facts: facts))
    }
}
