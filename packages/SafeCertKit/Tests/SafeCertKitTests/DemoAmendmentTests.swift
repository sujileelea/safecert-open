import Foundation
import Testing
@testable import SafeCertKit

@Suite("시연용 가상 법령 변경")
struct DemoAmendmentTests {
    @Test func amendedCriterionTurnsVerdictYellowOnly() async throws {
        let snap = try #require(await AnalysisPipeline.seedSnapshot(now: RuleEngineTests.day))
        let demo = snap.simulatingAmendment(of: .exitLocation)
        #expect(demo.isDemo && !snap.isDemo)
        #expect(demo.source.contains("시연용"))
        #expect(snap.state(.exitLocation)?.status == .verified, "원본은 그대로")
        #expect(demo.state(.exitLocation)?.status == .interpretationChanged)
        #expect(demo.state(.exitLocation)?.criterion == snap.state(.exitLocation)?.criterion, "이전 기준 값 유지")

        let prepared = try await AnalysisPipeline.prepare(pdf: SamplePlanRenderer.pdf(for: .risky), pageIndex: 0)
        var scale = try #require(prepared.scaleEstimate)
        scale.confirmed = true
        let before = await AnalysisPipeline.judge(prepared, scale: scale, conditions: Conditions(), snapshot: snap)
        let after = await AnalysisPipeline.judge(prepared, scale: scale, conditions: Conditions(), snapshot: demo)

        let location = try #require(after.verdicts.first { $0.rule == .exitLocation })
        #expect(location.color == .yellow)
        #expect(location.lawFlags.contains { if case .interpretationChanged = $0 { true } else { false } })
        // 다른 규칙 판정은 그대로
        #expect(after.verdicts.filter { $0.rule != .exitLocation }.map(\.color) == before.verdicts.filter { $0.rule != .exitLocation }.map(\.color))
    }
}
