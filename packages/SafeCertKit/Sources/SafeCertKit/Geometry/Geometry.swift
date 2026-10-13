import Foundation

/// 페이지 좌표계의 점. 단위는 PDF 포인트(1/72 inch), 원점은 페이지 좌상단, y 는 아래로 증가.
public struct Point: Hashable, Codable, Sendable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = Point(0, 0)

    public static func + (a: Point, b: Point) -> Point { Point(a.x + b.x, a.y + b.y) }
    public static func - (a: Point, b: Point) -> Point { Point(a.x - b.x, a.y - b.y) }
    public static func * (a: Point, k: Double) -> Point { Point(a.x * k, a.y * k) }

    public var length: Double { (x * x + y * y).squareRoot() }

    public func distance(to other: Point) -> Double { (self - other).length }

    public func dot(_ o: Point) -> Double { x * o.x + y * o.y }
    public func cross(_ o: Point) -> Double { x * o.y - y * o.x }

    public var normalized: Point {
        let l = length
        return l > 0 ? Point(x / l, y / l) : .zero
    }
}

public struct Segment: Hashable, Codable, Sendable {
    public var a: Point
    public var b: Point

    public init(_ a: Point, _ b: Point) {
        self.a = a
        self.b = b
    }

    public var length: Double { a.distance(to: b) }
    public var midpoint: Point { (a + b) * 0.5 }
    public var direction: Point { (b - a).normalized }

    /// 점에서 선분까지 최단 거리.
    public func distance(to p: Point) -> Double {
        let ab = b - a
        let len2 = ab.dot(ab)
        guard len2 > 0 else { return p.distance(to: a) }
        let t = max(0, min(1, (p - a).dot(ab) / len2))
        return p.distance(to: a + ab * t)
    }

    /// 두 선분의 교점(끝점 포함). 평행이면 nil.
    public func intersection(with o: Segment) -> Point? {
        let r = b - a
        let s = o.b - o.a
        let denom = r.cross(s)
        guard abs(denom) > 1e-12 else { return nil }
        let t = (o.a - a).cross(s) / denom
        let u = (o.a - a).cross(r) / denom
        let eps = 1e-9
        guard t >= -eps, t <= 1 + eps, u >= -eps, u <= 1 + eps else { return nil }
        return a + r * t
    }

    /// 두 선분이 (각도 허용 오차 안에서) 평행한가.
    public func isParallel(to o: Segment, toleranceDegrees: Double = 3) -> Bool {
        let c = abs(direction.cross(o.direction))
        return c < sin(toleranceDegrees * .pi / 180)
    }
}

public struct Rect: Hashable, Codable, Sendable {
    public var minX: Double
    public var minY: Double
    public var maxX: Double
    public var maxY: Double

    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    public init(points: [Point]) {
        precondition(!points.isEmpty)
        minX = points.map(\.x).min()!
        minY = points.map(\.y).min()!
        maxX = points.map(\.x).max()!
        maxY = points.map(\.y).max()!
    }

    public var width: Double { maxX - minX }
    public var height: Double { maxY - minY }
    public var center: Point { Point((minX + maxX) / 2, (minY + maxY) / 2) }
    public var diagonal: Double { (width * width + height * height).squareRoot() }

    public func contains(_ p: Point) -> Bool {
        p.x >= minX && p.x <= maxX && p.y >= minY && p.y <= maxY
    }

    public func insetBy(_ d: Double) -> Rect {
        Rect(minX: minX + d, minY: minY + d, maxX: maxX - d, maxY: maxY - d)
    }
}

public struct Polygon: Hashable, Codable, Sendable {
    public var vertices: [Point]

    public init(_ vertices: [Point]) {
        self.vertices = vertices
    }

    /// 부호 있는 면적(좌상단 원점 좌표계에서 화면상 시계 방향이 양수).
    public var signedArea: Double {
        guard vertices.count >= 3 else { return 0 }
        var s = 0.0
        for i in vertices.indices {
            let p = vertices[i]
            let q = vertices[(i + 1) % vertices.count]
            s += p.x * q.y - q.x * p.y
        }
        return s / 2
    }

    public var area: Double { abs(signedArea) }

    public var bounds: Rect { Rect(points: vertices) }

    public var edges: [Segment] {
        vertices.indices.map { Segment(vertices[$0], vertices[($0 + 1) % vertices.count]) }
    }

    public var centroid: Point {
        let a = signedArea
        guard abs(a) > 1e-9 else {
            let n = Double(vertices.count)
            return Point(vertices.map(\.x).reduce(0, +) / n, vertices.map(\.y).reduce(0, +) / n)
        }
        var cx = 0.0, cy = 0.0
        for i in vertices.indices {
            let p = vertices[i]
            let q = vertices[(i + 1) % vertices.count]
            let f = p.x * q.y - q.x * p.y
            cx += (p.x + q.x) * f
            cy += (p.y + q.y) * f
        }
        return Point(cx / (6 * a), cy / (6 * a))
    }

    /// 가장 먼 두 꼭짓점 사이 거리(다각형의 가장 긴 대각선).
    public var diameter: Double {
        var best = 0.0
        for i in vertices.indices {
            for j in (i + 1)..<vertices.count {
                best = max(best, vertices[i].distance(to: vertices[j]))
            }
        }
        return best
    }

    public func contains(_ p: Point) -> Bool {
        var inside = false
        var j = vertices.count - 1
        for i in vertices.indices {
            let a = vertices[i], b = vertices[j]
            if (a.y > p.y) != (b.y > p.y) {
                let x = (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x
                if p.x < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    /// 점에서 다각형 경계까지 최단 거리.
    public func distanceToBoundary(_ p: Point) -> Double {
        edges.map { $0.distance(to: p) }.min() ?? .infinity
    }

    /// 일직선 위의 중간 꼭짓점을 제거한다.
    public func simplified(collinearTolerance: Double = 0.5) -> Polygon {
        guard vertices.count > 3 else { return self }
        var out: [Point] = []
        let n = vertices.count
        for i in 0..<n {
            let prev = vertices[(i - 1 + n) % n]
            let cur = vertices[i]
            let next = vertices[(i + 1) % n]
            if Segment(prev, next).distance(to: cur) > collinearTolerance { out.append(cur) }
        }
        return out.count >= 3 ? Polygon(out) : self
    }
}

/// 3차 베지어 곡선.
public struct Cubic: Hashable, Codable, Sendable {
    public var p0: Point
    public var c1: Point
    public var c2: Point
    public var p3: Point

    public init(_ p0: Point, _ c1: Point, _ c2: Point, _ p3: Point) {
        self.p0 = p0
        self.c1 = c1
        self.c2 = c2
        self.p3 = p3
    }

    public func point(at t: Double) -> Point {
        let u = 1 - t
        let a = p0 * (u * u * u)
        let b = c1 * (3 * u * u * t)
        let c = c2 * (3 * u * t * t)
        let d = p3 * (t * t * t)
        return a + b + c + d
    }

    public func sampled(_ n: Int = 8) -> [Point] {
        (0...n).map { point(at: Double($0) / Double(n)) }
    }
}

/// 원호(문 열림 궤적). 중심 = 문 경첩.
public struct Arc: Hashable, Codable, Sendable {
    public var center: Point
    public var radius: Double
    public var start: Point
    public var end: Point
    /// 호가 쓸고 지나간 각도(도).
    public var sweepDegrees: Double

    /// 연속된 곡선 묶음(한 원호가 여러 베지어로 나뉜 경우 포함)이 원호인지 맞춘다.
    /// 표본점 전부가 한 원 위에 있으면(상대 오차 3% 이하) 원호로 본다.
    public static func fit(_ curves: [Cubic]) -> Arc? {
        guard curves.first != nil else { return nil }
        return fit(points: curves.flatMap { $0.sampled(6) })
    }

    /// 순서 있는 점열(직선 조각으로 그린 원호 포함)이 원호인지 맞춘다.
    public static func fit(points pts: [Point], tolerance: Double = 0.03) -> Arc? {
        guard pts.count >= 5, let first = pts.first, let last = pts.last else { return nil }
        let a = pts[0], b = pts[pts.count / 2], c = pts[pts.count - 1]
        guard let center = circumcenter(a, b, c) else { return nil }
        let r = center.distance(to: a)
        guard r > 1e-6 else { return nil }
        let maxDev = pts.map { abs($0.distance(to: center) - r) / r }.max() ?? 1
        guard maxDev < tolerance else { return nil }
        // 각도 누적으로 스윕 계산
        var sweep = 0.0
        for i in 1..<pts.count {
            let v1 = pts[i - 1] - center, v2 = pts[i] - center
            sweep += atan2(v1.cross(v2), v1.dot(v2))
        }
        return Arc(center: center, radius: r, start: first, end: last, sweepDegrees: abs(sweep) * 180 / .pi)
    }

    static func circumcenter(_ a: Point, _ b: Point, _ c: Point) -> Point? {
        let d = 2 * (a.x * (b.y - c.y) + b.x * (c.y - a.y) + c.x * (a.y - b.y))
        guard abs(d) > 1e-9 else { return nil }
        let a2 = a.x * a.x + a.y * a.y, b2 = b.x * b.x + b.y * b.y, c2 = c.x * c.x + c.y * c.y
        let ux = (a2 * (b.y - c.y) + b2 * (c.y - a.y) + c2 * (a.y - b.y)) / d
        let uy = (a2 * (c.x - b.x) + b2 * (a.x - c.x) + c2 * (b.x - a.x)) / d
        return Point(ux, uy)
    }
}

public extension Polygon {
    /// 점들의 볼록 껍질(단조 사슬). 3점 미만이면 nil.
    static func convexHull(_ points: [Point]) -> Polygon? {
        let pts = Array(Set(points)).sorted { ($0.x, $0.y) < ($1.x, $1.y) }
        guard pts.count >= 3 else { return nil }
        func cross(_ o: Point, _ a: Point, _ b: Point) -> Double { (a - o).cross(b - o) }
        var lower: [Point] = []
        for p in pts {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        var upper: [Point] = []
        for p in pts.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        let hull = Array(lower.dropLast() + upper.dropLast())
        return hull.count >= 3 ? Polygon(hull) : nil
    }
}
