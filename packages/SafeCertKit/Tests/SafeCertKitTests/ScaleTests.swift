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
            (TextRun(text: text, bounds: Rect(minX: 100 + len / 2 - 15, minY: y - 10, maxX: 100 + len / 2 + 15, maxY: y)),
             Stroke(segments: [Segment(Point(100, y + 5), Point(100 + len, y + 5))], curveRuns: [], closedPolygons: [], lineWidth: 0.4, isStroked: true, isFilled: false))
        }
        let items = [dim("10000", 100, 10 * k100), dim("8000", 200, 8 * k100), dim("6000", 300, 6 * k200), dim("4000", 400, 4 * k200)]
        let wall = Stroke(segments: (0..<4).map { Segment(Point(0, Double($0) * 20), Point(10, Double($0) * 20)) }, curveRuns: [], closedPolygons: [], lineWidth: 4, isStroked: true, isFilled: false)
        let page = VectorPage(index: 0, width: 1000, height: 700, strokes: items.map(\.1) + [wall], texts: items.map(\.0))
        for _ in 0..<5 { #expect(ScaleEstimator.estimate(page)?.ratio == 100) }
    }

    @Test func dimensionConsensusOverridesShrunkPrint() {
        // 표기는 1:150 인데 치수 3개가 1:212(A3→A4 축소 인쇄)를 가리킨다.
        let k = 72 / 25.4 * 1000 / 212 // 1 m 의 포인트(1:212)
        func dim(_ mm: Int, _ y: Double) -> (TextRun, Stroke) {
            let len = Double(mm) / 1000 * k
            return (TextRun(text: String(mm), bounds: Rect(minX: 100 + len / 2 - 10, minY: y - 8, maxX: 100 + len / 2 + 10, maxY: y)),
                    Stroke(segments: [Segment(Point(100, y + 4), Point(100 + len, y + 4))], curveRuns: [], closedPolygons: [], lineWidth: 0.12, isStroked: true, isFilled: false))
        }
        let items = [dim(12000, 100), dim(6000, 200), dim(3000, 300), dim(4500, 400)]
        let title = TextRun(text: "SCALE : 1/ 150", bounds: Rect(minX: 500, minY: 500, maxX: 560, maxY: 508))
        let wall = Stroke(segments: (0..<4).map { Segment(Point(0, Double($0) * 20), Point(10, Double($0) * 20)) }, curveRuns: [], closedPolygons: [], lineWidth: 0.72, isStroked: true, isFilled: false)
        let page = VectorPage(index: 0, width: 595, height: 842, strokes: items.map(\.1) + [wall], texts: items.map(\.0) + [title])
        let s = ScaleEstimator.estimate(page)
        #expect(s?.source == .dimensions)
        #expect(s.map { abs($0.ratio - 212) <= 2 } == true, "\(String(describing: s))")
        #expect(s?.evidence.first?.contains("1:150 과 다름") == true)
    }
}
