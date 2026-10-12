import Foundation
import Testing
@testable import SafeCertKit

@Suite("분석 진입점")
struct PipelineTests {
    @Test func prepareAndJudgeSample() async throws {
        let snap = try #require(await AnalysisPipeline.seedSnapshot(now: RuleEngineTests.day))
        let prepared = try await AnalysisPipeline.prepare(pdf: SamplePlanRenderer.pdf(for: .compliant), pageIndex: 0)
        #expect(prepared.isVector)
        #expect(prepared.pageCount == 1)
        var scale = try #require(prepared.scaleEstimate)
        scale.confirmed = true
        let r = await AnalysisPipeline.judge(prepared, scale: scale, conditions: Conditions(), snapshot: snap)
        #expect(r.verdicts.count == 4)
        // 저장 왕복(앱은 JSON 으로 보관한다)
        let decoded = try JSONDecoder().decode(AnalysisResult.self, from: JSONEncoder().encode(r))
        #expect(decoded == r)
        let snapDecoded = try JSONDecoder().decode(LawSnapshot.self, from: JSONEncoder().encode(snap))
        #expect(snapDecoded == snap)
    }
}
