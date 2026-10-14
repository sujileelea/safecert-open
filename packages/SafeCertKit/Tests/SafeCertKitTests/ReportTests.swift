import Foundation
import Testing
@testable import SafeCertKit

/// 시험용 서술 모델: 정해 둔 문장을 돌려준다.
struct StubNarrator: ReportNarrating {
    var summaryText: String?
    var explanation: String
    var steps: [String]
    var modelName: String { "시험용 모델" }

    func summary(facts: String) async -> String? { summaryText }
    func verdict(facts: String, passages: String) async -> (explanation: String, nextSteps: [String])? { (explanation, steps) }
}

@Suite("보고서")
struct ReportTests {
    static func input(_ sample: SamplePlan = .risky) async throws -> ReportInput {
        let snap = try #require(await AnalysisPipeline.seedSnapshot(now: RuleEngineTests.day))
        let prepared = try await AnalysisPipeline.prepare(pdf: SamplePlanRenderer.pdf(for: sample), pageIndex: 0)
        var scale = try #require(prepared.scaleEstimate)
        scale.confirmed = true
        let r = await AnalysisPipeline.judge(prepared, scale: scale, conditions: Conditions(), snapshot: snap)
        return ReportInput(result: r, plan: prepared.plan, snapshot: snap, projectName: sample.title, fileName: "\(sample.id).pdf",
                           judgedAt: RuleEngineTests.day)
    }

    @Test func reportKeepsVerdictsExactly() async throws {
        let input = try await Self.input()
        let report = await ReportBuilder.build(input, narrator: nil, now: RuleEngineTests.day)
        // X-01 수용 기준: 보고서의 판정은 결과 화면과 같은 값·조항을 갖는다.
        #expect(report.result == input.result)
        #expect(report.sections.map(\.verdict) == input.result.verdicts)
        for s in report.sections {
            #expect(s.explanation == ExplanationComposer.explain(s.verdict, result: input.result, plan: input.plan, snapshot: input.snapshot))
        }
        // 모델이 없으면 규칙 엔진 문장으로 채우고 AI 표시가 없다.
        #expect(report.model == nil)
        #expect(report.aiSentenceCount == 0)
        #expect(report.summary.sentences == ExplanationComposer.narrative(input.result))
        #expect(report.sections.allSatisfy { !$0.narrative.isAI && !$0.narrative.sentences.isEmpty })
    }

    @Test func groundedSentencesKeptOthersDropped() async throws {
        let input = try await Self.input()
        let narrator = StubNarrator(
            summaryText: "도면을 자동으로 검토했다. 이 영업장은 안전합니다. 과태료 300만원이 부과된다. 전문가 감수 전 결과다.",
            explanation: "이 항목은 비상구 기준을 확인한 것이다. 비상구 폭이 123.45m 로 읽혔다.",
            steps: ["현장에서 비상구 위치를 확인한다.", "부적합이므로 즉시 철거한다."]
        )
        let report = await ReportBuilder.build(input, narrator: narrator, now: RuleEngineTests.day)
        #expect(report.model == "시험용 모델")
        #expect(report.summary.isAI)
        #expect(report.summary.sentences == ["도면을 자동으로 검토했다.", "전문가 감수 전 결과다."])
        #expect(report.summary.dropped == 2)
        for s in report.sections {
            #expect(s.narrative.sentences == ["이 항목은 비상구 기준을 확인한 것이다."])
            #expect(s.narrative.dropped == 1)
            #expect(s.nextSteps.sentences == ["현장에서 비상구 위치를 확인한다."])
        }
        #expect(report.droppedSentenceCount == 2 + report.sections.count * 2)
    }

    @Test func allSentencesRejectedFallsBackToRuleText() async throws {
        let input = try await Self.input()
        let narrator = StubNarrator(summaryText: "벌금 999만원.", explanation: "부적합하다.", steps: ["99.9m 를 확보한다."])
        let report = await ReportBuilder.build(input, narrator: narrator, now: RuleEngineTests.day)
        #expect(!report.summary.isAI)
        #expect(report.summary.sentences == ExplanationComposer.narrative(input.result))
        #expect(report.sections.allSatisfy { !$0.narrative.isAI && !$0.nextSteps.isAI })
    }

    @Test func guardRejectsColorNotInFacts() {
        let facts = "판정 색: 주황(위반 가능성 · 확인 필요)\n결과: 비상구 1개"
        #expect(NarrativeGuard.isGrounded("주황 판정이며 비상구 1개를 확인했다.", facts: facts))
        #expect(!NarrativeGuard.isGrounded("빨강 판정이다.", facts: facts))
        #expect(!NarrativeGuard.isGrounded("의무 미충족 상태다.", facts: facts))
        #expect(!NarrativeGuard.isGrounded("비상구 2개가 필요하다.", facts: facts))
    }

    @Test func reportRoundTrips() async throws {
        let report = await ReportBuilder.build(try await Self.input(), narrator: nil, now: RuleEngineTests.day)
        #expect(try JSONDecoder().decode(InspectionReport.self, from: JSONEncoder().encode(report)) == report)
    }
}
