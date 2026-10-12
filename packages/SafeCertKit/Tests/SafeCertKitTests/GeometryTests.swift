import Foundation
import Testing
@testable import SafeCertKit

@Suite("기하")
struct GeometryTests {
    @Test func polygonAreaCentroidDiameter() {
        let rect = Polygon([Point(0, 0), Point(30, 0), Point(30, 40), Point(0, 40)])
        #expect(rect.area == 1200)
        #expect(rect.centroid == Point(15, 20))
        #expect(rect.diameter == 50)
        #expect(rect.contains(Point(10, 10)))
        #expect(!rect.contains(Point(31, 10)))
    }

    @Test func segmentIntersectionAndDistance() {
        let s = Segment(Point(0, 0), Point(10, 0))
        let o = Segment(Point(5, -5), Point(5, 5))
        #expect(s.intersection(with: o) == Point(5, 0))
        #expect(s.distance(to: Point(5, 3)) == 3)
        #expect(s.isParallel(to: Segment(Point(0, 2), Point(9, 2))))
    }

    @Test func arcFitQuarterCircle() {
        // 반지름 10, 중심 (0,0) 사분원을 베지어 근사(κ = 0.5523)로 만든다.
        let k = 0.5523 * 10
        let cubic = Cubic(Point(10, 0), Point(10, k), Point(k, 10), Point(0, 10))
        let arc = Arc.fit([cubic])
        #expect(arc != nil)
        #expect(abs(arc!.radius - 10) < 0.1)
        #expect(abs(arc!.sweepDegrees - 90) < 2)
        #expect(arc!.center.distance(to: .zero) < 0.1)
    }

    @Test func straightCubicIsNotArc() {
        let cubic = Cubic(Point(0, 0), Point(3, 0), Point(6, 0), Point(9, 0))
        #expect(Arc.fit([cubic]) == nil)
    }

    @Test func planarFacesFindsOuterAndRooms() {
        // 20×10 외곽 + 가운데 칸막이 = 실 2개. 매달린 선분(가구)은 무시된다.
        let segs = [
            Segment(Point(0, 0), Point(20, 0)),
            Segment(Point(20, 0), Point(20, 10)),
            Segment(Point(20, 10), Point(0, 10)),
            Segment(Point(0, 10), Point(0, 0)),
            Segment(Point(10, 0), Point(10, 10)),
            Segment(Point(3, 3), Point(5, 5))
        ]
        let f = PlanarGraph.faces(from: segs, tolerance: 0.5)
        #expect(f.outer != nil)
        #expect(abs(f.outer!.area - 200) < 1e-6)
        #expect(f.faces.count == 2)
        #expect(f.faces.allSatisfy { abs($0.area - 100) < 1e-6 })
    }

    @Test func planarFacesHandlesTJunctionWithinTolerance() {
        // 칸막이 끝점이 외벽에서 0.8 떨어져 있어도 허용 거리 안이면 접합한다.
        let segs = [
            Segment(Point(0, 0), Point(20, 0)),
            Segment(Point(20, 0), Point(20, 10)),
            Segment(Point(20, 10), Point(0, 10)),
            Segment(Point(0, 10), Point(0, 0)),
            Segment(Point(10, 0.8), Point(10, 9.2))
        ]
        let f = PlanarGraph.faces(from: segs, tolerance: 1.0)
        #expect(f.faces.count == 2)
    }
}
