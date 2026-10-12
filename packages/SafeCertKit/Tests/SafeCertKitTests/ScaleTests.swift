import Foundation
import Testing
@testable import SafeCertKit

@Suite("축척")
struct ScaleTests {
    @Test func titleBlockCrossValidatedByDimensions() throws {
        let page = try VectorPDF.read(SamplePlanRenderer.pdf(for: .compliant))
        let s = try #require(ScaleEstimator.estimate(page))
        #expect(s.ratio == 100)
        #expect(s.source == .titleBlock)
        #expect(s.crossChecks == 2)
        #expect(s.conflicts == 0)
        #expect(s.isCrossValidated)
        #expect(!s.confirmed)
        #expect(abs(s.meters(SamplePlan.compliant.pointsPerMeter) - 1) < 1e-9)
    }

    @Test func dimensionsOnlyWhenNoTitle() {
        let texts = [TextRun(text: "16000", bounds: Rect(minX: 300, minY: 60, maxX: 330, maxY: 70)),
                     TextRun(text: "8000", bounds: Rect(minX: 300, minY: 200, maxX: 325, maxY: 210))]
        let k = 72 / 25.4 * 10 // 1:100 에서 1 m 의 포인트
        let strokes = [
            Stroke(segments: [Segment(Point(90, 75), Point(90 + 16 * k, 75))], curveRuns: [], closedPolygons: [], lineWidth: 0.4, isStroked: true, isFilled: false),
            Stroke(segments: [Segment(Point(200, 215), Point(200 + 8 * k, 215))], curveRuns: [], closedPolygons: [], lineWidth: 0.4, isStroked: true, isFilled: false),
            Stroke(segments: [Segment(Point(0, 0), Point(10, 0))], curveRuns: [], closedPolygons: [], lineWidth: 4, isStroked: true, isFilled: false)
        ]
        let page = VectorPage(index: 0, width: 1000, height: 700, strokes: strokes, texts: texts)
        let s = ScaleEstimator.estimate(page)
        #expect(s?.ratio == 100)
        #expect(s?.source == .dimensions)
    }

    @Test func declaredPatterns() {
        let t = ["축척 1:100", "SCALE 1/50", "S=1:200", "1:300"].map { TextRun(text: $0, bounds: Rect(minX: 0, minY: 0, maxX: 1, maxY: 1)) }
        #expect(ScaleEstimator.declaredRatios(t) == [100, 50, 200])
    }

    @Test func tieBreaksDeterministically() {
        // 1:100 지지 2 · 1:200 지지 2 → 작은 번호(100)
        let k100 = 72 / 25.4 * 10, k200 = 72 / 25.4 * 5
        func dim(_ text: String, _ y: Double, _ len: Double) -> (TextRun, Stroke) {
            (TextRun(text: text, bounds: Rect(minX: 300, minY: y - 10, maxX: 330, maxY: y)),
             Stroke(segments: [Segment(Point(100, y + 5), Point(100 + len, y + 5))], curveRuns: [], closedPolygons: [], lineWidth: 0.4, isStroked: true, isFilled: false))
        }
        let items = [dim("10000", 100, 10 * k100), dim("8000", 200, 8 * k100), dim("6000", 300, 6 * k200), dim("4000", 400, 4 * k200)]
        let wall = Stroke(segments: [Segment(Point(0, 0), Point(10, 0))], curveRuns: [], closedPolygons: [], lineWidth: 4, isStroked: true, isFilled: false)
        let page = VectorPage(index: 0, width: 1000, height: 700, strokes: items.map(\.1) + [wall], texts: items.map(\.0))
        for _ in 0..<5 { #expect(ScaleEstimator.estimate(page)?.ratio == 100) }
    }
}
