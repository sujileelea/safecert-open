import Foundation
import Testing
@testable import SafeCertKit

/// 실제 CAD 출력물 특성(벽 = 칠한 도형·얇은 펜, 문 궤적 = 직선 조각, 글자 = 외곽선)을 흉내 낸 샘플로
/// 실도면 대응 경로(상대 굵기 벽 층 · 직선 조각 원호 · 기기 내 OCR · 외곽 껍질)를 고정한다.
@Suite("CAD 출력형 도면")
struct CADExportTests {
    @Test func outlinedTextVectorPDFHasNoExtractableText() throws {
        let page = try VectorPDF.read(SamplePlanRenderer.pdf(for: .compliant, style: .cadExport))
        #expect(page.texts.isEmpty)
        #expect(page.strokes.flatMap(\.curveRuns).isEmpty || page.strokes.filter { $0.isStroked }.flatMap(\.curveRuns).allSatisfy { Arc.fit($0) == nil })
    }

    @Test func pipelineReadsCADExportSample() async throws {
        let plan = SamplePlan.compliant
        let prepared = try await AnalysisPipeline.prepare(pdf: SamplePlanRenderer.pdf(for: plan, style: .cadExport), pageIndex: 0)
        let k = plan.pointsPerMeter
        print("CAD texts", prepared.recognizedTexts?.map(\.text) ?? [])
        print("CAD scale", String(describing: prepared.scaleEstimate))
        print("CAD boundary", prepared.plan.boundary.map { ($0.area / (k * k), prepared.plan.boundaryConfidence) } as Any)
        print("CAD doors", prepared.plan.doors.map { "\($0.id):\($0.role):\($0.label ?? "-"):\(($0.openingWidth / k * 100).rounded() / 100)" })
        print("CAD notes", prepared.plan.notes)

        // 글자: OCR 로 실명·출입구·축척을 되찾는다
        let texts = try #require(prepared.recognizedTexts)
        #expect(texts.contains { $0.text.contains("비상구") })
        #expect(texts.contains { $0.text.contains("주출입구") })
        // 축척: 표기 1:100
        #expect(prepared.scaleEstimate?.ratio == 100)
        // 벽·외곽: 영업장 16 × 10 m(벽 두께 포함 허용)
        let area = try #require(prepared.plan.boundary?.area) / (k * k)
        #expect(area > 150 && area < 170, "\(area)")
        // 문: 직선 조각 원호 4개, 외부 2개(주출입구·비상구)
        #expect(prepared.plan.doors.count == 4)
        #expect(prepared.plan.mainEntrances.count == 1)
        #expect(prepared.plan.emergencyExits.count == 1)
        #expect(abs((prepared.plan.emergencyExits.first?.openingWidth ?? 0) / k - 0.9) < 0.05)
    }
}
