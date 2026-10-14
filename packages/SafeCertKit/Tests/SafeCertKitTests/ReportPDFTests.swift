import Foundation
import PDFKit
import Testing
@testable import SafeCertKit

@Suite("보고서 PDF")
struct ReportPDFTests {
    @Test func rendersAllPartsWithNotices() async throws {
        let sample = SamplePlan.risky
        let input = try await ReportTests.input(sample)
        let narrator = StubNarrator(summaryText: "도면을 자동으로 검토했다. 전문가 감수 전 결과다.",
                                    explanation: "이 항목은 비상구 기준을 확인한 것이다.", steps: ["현장에서 비상구 위치를 확인한다."])
        let report = await ReportBuilder.build(input, narrator: narrator, now: RuleEngineTests.day)
        let prepared = try await AnalysisPipeline.prepare(pdf: SamplePlanRenderer.pdf(for: sample), pageIndex: 0)
        let data = ReportPDF.render(report, drawing: SamplePlanRenderer.pdf(for: sample), pageIndex: 0, plan: prepared.plan)

        let doc = try #require(PDFDocument(data: data))
        #expect(doc.pageCount >= 3)
        let text = LawText.compact((doc.string as String?) ?? "")
        #expect(text.contains(LawText.compact(ReportBuilder.title)))
        #expect(text.contains(LawText.compact(input.result.summary.headline)))
        #expect(text.contains("감수전·참고용"))
        #expect(text.contains("AI작성"))
        #expect(text.contains(LawText.compact(InspectionReport.disclaimer)))
        for v in input.result.verdicts where !v.summary.isEmpty {
            #expect(text.contains(LawText.compact(v.summary)), "\(v.summary)")
        }
        // 모든 쪽에 바닥글(쪽 번호 n / 전체)
        for i in 0..<doc.pageCount {
            let page = try #require(doc.page(at: i))
            let pageText = LawText.compact((page.string as String?) ?? "")
            #expect(pageText.contains("\(i + 1)/\(doc.pageCount)"))
        }
    }

    @Test func confirmationsFlowIntoReport() async throws {
        var input = try await ReportTests.input(.risky)
        let first = try #require(input.result.verdicts.first)
        input.confirmations = [first.id: RuleEngineTests.day]
        let report = await ReportBuilder.build(input, narrator: nil, now: RuleEngineTests.day)
        #expect(report.confirmedCount == 1)
        #expect(report.sections.first?.confirmedAt == RuleEngineTests.day)
        #expect(report.sections.dropFirst().allSatisfy { $0.confirmedAt == nil })
        let prepared = try await AnalysisPipeline.prepare(pdf: SamplePlanRenderer.pdf(for: .risky), pageIndex: 0)
        let text = LawText.compact((PDFDocument(data: ReportPDF.render(report, drawing: SamplePlanRenderer.pdf(for: .risky), pageIndex: 0, plan: prepared.plan))?.string as String?) ?? "")
        #expect(text.contains("검토자확인1/\(report.sections.count)건"))
        #expect(text.contains("검토자미확인"))
    }

    @Test func rendersWithoutModelAsRuleText() async throws {
        let input = try await ReportTests.input(.noExit)
        let report = await ReportBuilder.build(input, narrator: nil, now: RuleEngineTests.day)
        let prepared = try await AnalysisPipeline.prepare(pdf: SamplePlanRenderer.pdf(for: .noExit), pageIndex: 0)
        let data = ReportPDF.render(report, drawing: SamplePlanRenderer.pdf(for: .noExit), pageIndex: 0, plan: prepared.plan)
        let text = LawText.compact((PDFDocument(data: data)?.string as String?) ?? "")
        #expect(text.contains("규칙엔진문장"))
        #expect(!text.contains("AI작성·"))
    }
}
