import Foundation

/// 선분 묶음을 평면 그래프로 만들어 면(face)을 뽑는다.
/// 벽 선분 + 문 개구부 현(chord)을 넣으면 외곽 면 경계 = 영업장 외곽선, 내부 면 = 구획된 실 후보가 된다.
public struct PlanarFaces: Sendable {
    /// 가장 큰 연결 성분의 외곽선.
    public var outer: Polygon?
    /// 내부 면(외곽 면 제외). 면적 내림차순.
    public var faces: [Polygon]
}

public enum PlanarGraph {
    /// - Parameters:
    ///   - segments: 입력 선분.
    ///   - tolerance: 끝점 병합·T 접합 허용 거리(포인트).
    public static func faces(from segments: [Segment], tolerance: Double = 1.5) -> PlanarFaces {
        let segs = segments.filter { $0.length > tolerance * 0.5 }
        guard segs.count >= 3 else { return PlanarFaces(outer: nil, faces: []) }

        // 1. 분할점 수집: 교차점 + T 접합(끝점이 다른 선분 위에 있는 경우)
        var cuts: [[Double]] = Array(repeating: [0, 1], count: segs.count)
        let boxes = segs.map { Rect(points: [$0.a, $0.b]).insetBy(-tolerance) }
        for i in segs.indices {
            for j in (i + 1)..<segs.count {
                let bi = boxes[i], bj = boxes[j]
                if bi.maxX < bj.minX || bj.maxX < bi.minX || bi.maxY < bj.minY || bj.maxY < bi.minY { continue }
                let s = segs[i], o = segs[j]
                if let p = s.intersection(with: o) {
                    cuts[i].append(param(of: p, on: s))
                    cuts[j].append(param(of: p, on: o))
                }
                for e in [o.a, o.b] where s.distance(to: e) <= tolerance {
                    cuts[i].append(param(of: e, on: s))
                }
                for e in [s.a, s.b] where o.distance(to: e) <= tolerance {
                    cuts[j].append(param(of: e, on: o))
                }
            }
        }

        // 2. 정점 병합(격자 해시)
        var snapper = Snapper(tolerance: tolerance)
        var edges = Set<EdgeKey>()
        for (i, s) in segs.enumerated() {
            let ts = cuts[i].map { max(0, min(1, $0)) }.sorted()
            var prev: Int?
            for t in ts {
                let p = s.a + (s.b - s.a) * t
                let v = snapper.vertex(for: p)
                if let u = prev, u != v { edges.insert(EdgeKey(u, v)) }
                prev = v
            }
        }
        let positions = snapper.points

        // 3. 인접 목록 + 매달린 간선 반복 제거
        var adj: [Int: Set<Int>] = [:]
        for e in edges {
            adj[e.a, default: []].insert(e.b)
            adj[e.b, default: []].insert(e.a)
        }
        var changed = true
        while changed {
            changed = false
            for (v, ns) in adj where ns.count <= 1 {
                for n in ns { adj[n]?.remove(v) }
                adj[v] = nil
                changed = true
            }
        }
        guard !adj.isEmpty else { return PlanarFaces(outer: nil, faces: []) }

        // 4. 각도순 정렬
        var sorted: [Int: [Int]] = [:]
        for (v, ns) in adj {
            let pv = positions[v]
            sorted[v] = ns.sorted {
                let a = positions[$0] - pv, b = positions[$1] - pv
                return atan2(a.y, a.x) < atan2(b.y, b.x)
            }
        }

        // 5. 반간선 순회로 면 추출
        var visited = Set<HalfEdge>()
        var cycles: [(polygon: Polygon, signed: Double, vertices: [Int])] = []
        for u in sorted.keys.sorted() {
            for v in sorted[u]! {
                let start = HalfEdge(u, v)
                if visited.contains(start) { continue }
                var cycle: [Int] = []
                var he = start
                var guardCount = 0
                while !visited.contains(he), guardCount < 100_000 {
                    visited.insert(he)
                    cycle.append(he.from)
                    guard let list = sorted[he.to], let idx = list.firstIndex(of: he.from) else { break }
                    let next = list[(idx + 1) % list.count]
                    he = HalfEdge(he.to, next)
                    guardCount += 1
                }
                if cycle.count >= 3 {
                    let poly = Polygon(cycle.map { positions[$0] })
                    cycles.append((poly, poly.signedArea, cycle))
                }
            }
        }
        guard !cycles.isEmpty else { return PlanarFaces(outer: nil, faces: []) }

        // 6. 가장 큰 |면적| 순환 = 외곽 면(그 부호가 외곽 방향). 반대 부호 = 내부 면.
        let outerCycle = cycles.max { abs($0.signed) < abs($1.signed) }!
        let outerSign = outerCycle.signed.sign
        var inner = cycles.filter { $0.signed.sign != outerSign }.map(\.polygon)
        // 같은 성분의 외곽 면들 중 하나만 고른 경우, 단일 면 그래프면 내부 면이 외곽과 같다.
        if inner.isEmpty { inner = [outerCycle.polygon] }
        // 결과를 결정적으로: 다각형은 정규형, 같은 면적은 위치순.
        let faces = inner.map { canonical($0.simplified()) }.sorted {
            if abs($0.area - $1.area) > 1e-6 { return $0.area > $1.area }
            return ($0.centroid.y, $0.centroid.x) < ($1.centroid.y, $1.centroid.x)
        }
        return PlanarFaces(outer: canonical(outerCycle.polygon.simplified()), faces: faces)
    }

    /// 시작 꼭짓점 = (y, x) 가 가장 작은 점, 방향 = 양의 부호 면적.
    static func canonical(_ p: Polygon) -> Polygon {
        var v = p.vertices
        if p.signedArea < 0 { v.reverse() }
        guard let i = v.indices.min(by: { (v[$0].y, v[$0].x) < (v[$1].y, v[$1].x) }) else { return p }
        return Polygon(Array(v[i...] + v[..<i]))
    }

    static func param(of p: Point, on s: Segment) -> Double {
        let ab = s.b - s.a
        let len2 = ab.dot(ab)
        guard len2 > 0 else { return 0 }
        return (p - s.a).dot(ab) / len2
    }
}

private struct EdgeKey: Hashable {
    let a: Int
    let b: Int
    init(_ u: Int, _ v: Int) {
        a = min(u, v)
        b = max(u, v)
    }
}

private struct HalfEdge: Hashable {
    let from: Int
    let to: Int
    init(_ f: Int, _ t: Int) {
        from = f
        to = t
    }
}

/// 허용 거리 안의 점을 같은 정점으로 묶는다.
private struct Snapper {
    let tolerance: Double
    var points: [Point] = []
    var grid: [GridKey: [Int]] = [:]

    init(tolerance: Double) {
        self.tolerance = tolerance
    }

    mutating func vertex(for p: Point) -> Int {
        let k = key(p)
        for dx in -1...1 {
            for dy in -1...1 {
                for idx in grid[GridKey(x: k.x + dx, y: k.y + dy)] ?? [] where points[idx].distance(to: p) <= tolerance {
                    return idx
                }
            }
        }
        points.append(p)
        grid[k, default: []].append(points.count - 1)
        return points.count - 1
    }

    func key(_ p: Point) -> GridKey {
        GridKey(x: Int((p.x / tolerance).rounded(.down)), y: Int((p.y / tolerance).rounded(.down)))
    }
}

private struct GridKey: Hashable {
    let x: Int
    let y: Int
}
