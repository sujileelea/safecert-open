import Foundation
import Testing
@testable import SafeCertKit

@Suite("벡터 PDF 해석")
struct VectorPDFTests {
    @Test func readsWallsArcsAndTextFromSample() throws {
        let data = SamplePlanRenderer.pdf(for: .compliant)
        #expect(VectorPDF.pageCount(data) == 1)
        let page = try VectorPDF.read(data)
        #expect(abs(page.width - 1190.55) < 0.1)

        let k = SamplePlan.compliant.pointsPerMeter
        let walls = page.strokes.filter { abs($0.lineWidth - 0.15 * k) < 0.05 }
        #expect(!walls.isEmpty)

        let arcs = page.strokes.flatMap(\.curveRuns).compactMap { Arc.fit($0) }
        // 영업장 출입문 2 + 실 문 2
        #expect(arcs.count == 4)
        #expect(arcs.contains { abs($0.radius - 0.9 * k) < 0.5 })
        #expect(arcs.contains { abs($0.radius - 1.2 * k) < 0.5 })

        let texts = page.texts.map(\.text)
        for expected in ["비상구", "주출입구", "주방", "룸1", "16000", "10000", "W900×H2100"] {
            #expect(texts.contains(expected), "글자 누락: \(expected) — 읽은 글자 \(texts)")
        }
        #expect(texts.contains { $0.contains("1:100") })
    }

    @Test func textPositionsAreTopLeftOrigin() throws {
        let plan = SamplePlan.compliant
        let page = try VectorPDF.read(SamplePlanRenderer.pdf(for: plan))
        let k = plan.pointsPerMeter
        // 비상구 표기는 오른쪽 벽(x = 140 + 16k) 바깥, y 는 7.65 m 부근
        let exit = try #require(page.texts.first { $0.text == "비상구" })
        #expect(exit.center.x > 140 + 16 * k)
        #expect(abs(exit.center.y - (150 + 7.65 * k)) < 12)
    }

    @Test func rejectsGarbage() {
        #expect(throws: VectorPDFError.unreadable) { try VectorPDF.read(Data("not a pdf".utf8)) }
    }
}
