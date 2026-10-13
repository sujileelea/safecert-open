import Foundation

/// 벡터 페이지를 영업장 평면 모델로 해석한다(D-03). 규칙 기반·결정적.
public enum PlanInterpreter {
    static let emergencyKeywords = ["비상구", "비상출구", "비상 출구", "피난구", "EXIT"]
    static let mainKeywords = ["주출입구", "주 출입구", "주된 출입구", "주된출입구", "출입구", "입구", "ENTRANCE"]

    public static func interpret(_ page: VectorPage) -> PlanModel {
        var notes: [String] = []

        // 1. 벽 = 도면 안에서 상대적으로 굵은 선 층(절대 굵기는 출력 축척·용지마다 다르다).
        //    CAD 는 벽을 선으로도, 칠한 도형(단면 채움)으로도 출력하므로 둘 다 본다.
        let stroked = page.strokes.filter { $0.isStroked || $0.isFilled }
        let wallClass = wallWidthClass(stroked)
        let wallThreshold = max(0.2, wallClass * 0.6)
        let wallSegments = stroked.filter { $0.lineWidth >= wallThreshold }.flatMap(\.segments)
        let thinSegments = stroked.filter { $0.lineWidth < wallThreshold }.flatMap(\.segments)
        if wallSegments.count < 4 {
            notes.append("벽으로 볼 굵은 선이 부족하다(\(wallSegments.count)개). 벽을 다른 선보다 굵게 출력한 CAD PDF 가 필요하다.")
        }
        let tolerance = max(1.5, wallClass * 0.75)

        // 2. 문 = 원호(스윕 60~120°) + 경첩에서 나가는 문짝 선. 원호는 곡선 또는 짧은 직선 조각으로 그려진다.
        var rawDoors: [(hinge: Point, closed: Point, open: Point, radius: Double)] = []
        // 원호 후보는 「그린 선」에서만 찾는다(칠한 도형 = 벽 단면·글자 외곽선의 곡선은 문이 아니다).
        func doorLike(_ a: Arc) -> Bool { a.sweepDegrees >= 60 && a.sweepDegrees <= 120 && a.radius >= 8 && a.radius <= 150 }
        let drawn = page.strokes.filter(\.isStroked)
        let curveArcs = drawn.flatMap(\.curveRuns).compactMap { Arc.fit($0) }.filter(doorLike)
        let thinDrawn = drawn.filter { $0.lineWidth < wallThreshold }.flatMap(\.segments)
        let polyArcs = polylineArcs(thinDrawn).filter(doorLike).filter { p in
            !curveArcs.contains { $0.center.distance(to: p.center) < 1 && abs($0.radius - p.radius) < 1 }
        }
        for arc in curveArcs + polyArcs {
            let hinge = arc.center
            let leafAtStart = thinSegments.contains { touches($0, hinge, arc.start, tolerance) }
            let leafAtEnd = thinSegments.contains { touches($0, hinge, arc.end, tolerance) }
            let (open, closed): (Point, Point)
            if leafAtStart, !leafAtEnd {
                (open, closed) = (arc.start, arc.end)
            } else if leafAtEnd, !leafAtStart {
                (open, closed) = (arc.end, arc.start)
            } else {
                // 문짝 선이 없으면 벽과 나란한 쪽을 닫힌 위치로 본다.
                let dirStart = Segment(hinge, arc.start)
                let alongWall = wallSegments.contains { $0.distance(to: hinge) < tolerance * 2 && $0.isParallel(to: dirStart, toleranceDegrees: 8) }
                (open, closed) = alongWall ? (arc.end, arc.start) : (arc.start, arc.end)
            }
            rawDoors.append((hinge, closed, open, arc.radius))
        }

        // 3. 벽 + 문 개구부 현으로 면 추출 → 외곽선·실.
        let chords = rawDoors.map { Segment($0.hinge, $0.closed) }
        let faces = PlanarGraph.faces(from: wallSegments + chords, tolerance: tolerance)
        // 벽 묶음의 외곽 껍질: 닫힌 외곽 면이 페이지 테두리이거나 껍질보다 훨씬 작으면(창·문 틈으로 외곽이 열린 두 줄 벽) 껍질을 쓴다.
        let hull = buildingHull(wallSegments, pageDiagonal: (page.width * page.width + page.height * page.height).squareRoot())
        var boundary = faces.outer
        var boundaryConfidence = 0.9
        let pageArea = page.width * page.height
        if let outer = boundary, outer.area > pageArea * 0.7 {
            boundary = nil
        }
        if let outer = boundary, let hull, outer.area < hull.area * 0.6 {
            boundary = nil
        }
        if boundary == nil || (boundary?.area ?? 0) < 100, let hull, hull.area > 100 {
            boundary = hull
            boundaryConfidence = 0.7
            notes.append("벽이 닫힌 외곽을 이루지 않아(창·문 틈) 벽 묶음의 외곽 껍질을 영업장 외곽으로 추정했다.")
        }
        if boundary == nil || (boundary?.area ?? 0) < 100 {
            if !wallSegments.isEmpty {
                let r = Rect(points: wallSegments.flatMap { [$0.a, $0.b] })
                boundary = Polygon([Point(r.minX, r.minY), Point(r.maxX, r.minY), Point(r.maxX, r.maxY), Point(r.minX, r.maxY)])
                boundaryConfidence = 0.5
                notes.append("벽이 닫힌 외곽을 이루지 않아 벽 범위의 사각형을 영업장 외곽으로 가정했다.")
            } else {
                boundary = nil
                boundaryConfidence = 0
            }
        }

        // 4. 외부 문 판별 + 열림 방향
        var doors: [DoorObject] = []
        for (i, d) in rawDoors.enumerated() {
            let mid = Segment(d.hinge, d.closed).midpoint
            let onBoundary = boundary.map { $0.distanceToBoundary(mid) <= max(tolerance * 1.5, $0.diameter * 0.012) } ?? false
            let outward = boundary.map { !$0.contains(d.open) }
            doors.append(DoorObject(
                id: "D\(i + 1)",
                hinge: d.hinge,
                closedEnd: d.closed,
                openEnd: d.open,
                radius: d.radius,
                role: onBoundary ? .unknownExterior : .interior,
                roleConfidence: onBoundary ? 0.5 : 0.8,
                label: nil,
                tag: nil,
                swingsOutward: onBoundary ? outward : nil
            ))
        }
        // 위치 순(위 → 아래, 왼 → 오른)으로 번호를 다시 매겨 결과를 안정화한다.
        doors.sort { ($0.center.y, $0.center.x) < ($1.center.y, $1.center.x) }
        for i in doors.indices { doors[i].id = "D\(i + 1)" }

        // 5. 표기로 역할 지정 — 표기 하나는 가장 가까운 외부 문 하나에만.
        let exteriorIdx = doors.indices.filter { doors[$0].role.isExterior }
        var usedLabel = Set<Int>()
        let labelCandidates: [(textIndex: Int, role: DoorRole)] = page.texts.enumerated().compactMap { idx, t in
            let s = t.text.uppercased()
            if emergencyKeywords.contains(where: { s.contains($0) }) { return (idx, .emergencyExit) }
            if mainKeywords.contains(where: { s.contains($0) }) { return (idx, .mainEntrance) }
            // CAD 약어 ENT(출입구) — 단어 단위로만
            if s.range(of: #"(^|[^A-Z])ENT([^A-Z]|$)"#, options: .regularExpression) != nil { return (idx, .mainEntrance) }
            return nil
        }
        var pairs: [(dist: Double, door: Int, text: Int, role: DoorRole)] = []
        for di in exteriorIdx {
            let d = doors[di]
            let reach = d.radius * 3 + 40
            for c in labelCandidates {
                let dist = page.texts[c.textIndex].center.distance(to: d.center)
                if dist <= reach { pairs.append((dist, di, c.textIndex, c.role)) }
            }
        }
        var labeledDoors = Set<Int>()
        for p in pairs.sorted(by: { $0.dist < $1.dist }) where !labeledDoors.contains(p.door) && !usedLabel.contains(p.text) {
            doors[p.door].role = p.role
            doors[p.door].roleConfidence = 0.95
            doors[p.door].label = page.texts[p.text].text
            labeledDoors.insert(p.door)
            usedLabel.insert(p.text)
        }
        // 표기 없는 외부 문: 주된 출입구가 아직 없으면 가장 넓은 문을 주된 출입구로 추정, 나머지는 비상구로 추정.
        let unlabeled = exteriorIdx.filter { !labeledDoors.contains($0) }
        if !unlabeled.isEmpty {
            let hasMain = doors.contains { $0.role == .mainEntrance }
            let widest = unlabeled.max { doors[$0].openingWidth < doors[$1].openingWidth }!
            for di in unlabeled {
                if !hasMain && di == widest {
                    doors[di].role = .mainEntrance
                } else {
                    doors[di].role = .emergencyExit
                }
                doors[di].roleConfidence = unlabeled.count == 1 && !hasMain ? 0.6 : 0.4
            }
            notes.append("표기 없는 외부 문 \(unlabeled.count)개의 역할을 폭으로 추정했다.")
        }

        // 6. 문 규격 표기(W900×H2100 등) 연결
        var usedTag = Set<Int>()
        for di in doors.indices where doors[di].role.isExterior {
            let d = doors[di]
            let reach = d.radius * 3 + 60
            let best = page.texts.enumerated()
                .compactMap { idx, t -> (Int, DoorTag, Double)? in
                    guard !usedTag.contains(idx), let tag = parseTag(t.text) else { return nil }
                    let dist = t.center.distance(to: d.center)
                    return dist <= reach ? (idx, tag, dist) : nil
                }
                .min { $0.2 < $1.2 }
            if let (idx, tag, _) = best {
                doors[di].tag = tag
                usedTag.insert(idx)
            }
        }

        // 7. 실: 가장 큰 면 = 홀, 나머지 중 홀 면적의 1% 이상 = 구획된 실
        var hall: RoomObject?
        var rooms: [RoomObject] = []
        let roomTexts = page.texts.filter { t in
            !labelCandidates.contains { page.texts[$0.textIndex] == t } && parseTag(t.text) == nil && !t.text.allSatisfy(\.isNumber)
        }
        if let outer = boundary {
            let inside = faces.faces.filter { outer.contains($0.centroid) || outer.area - $0.area < 1 }
            if let first = inside.first {
                hall = RoomObject(id: "H", polygon: first, label: label(in: first, texts: roomTexts, excluding: inside.dropFirst().map { $0 }))
                for (i, f) in inside.dropFirst().enumerated() where f.area >= first.area * 0.01 && isRoomShaped(f) {
                    rooms.append(RoomObject(id: "R\(i + 1)", polygon: f, label: label(in: f, texts: roomTexts, excluding: [])))
                }
            }
        }

        // 공동주택·여러 세대 표기 → 다중이용업소 영업장 도면이 아닐 수 있음을 알린다.
        let allText = page.texts.map(\.text).joined(separator: " ")
        let unitMarks = allText.matches(of: /\d{3}\s*(~\s*\d{3})?\s*호/).count
        if unitMarks >= 2 || ["오피스텔", "아파트", "다세대", "다가구", "공동주택", "세대"].contains(where: { allText.contains($0) }) {
            notes.append("도면에 여러 세대(호)·공동주택 표기가 있다. 다중이용업소 영업장 평면이 아니면 조건에서 「다중이용업소 영업장」을 끄면 대상 외로 처리된다.")
        }

        return PlanModel(
            pageWidth: page.width,
            pageHeight: page.height,
            boundary: boundary,
            boundaryConfidence: boundaryConfidence,
            rooms: rooms,
            hall: hall,
            doors: doors,
            wallSegments: wallSegments,
            texts: page.texts,
            notes: notes
        )
    }

    /// 벽 층 굵기: 선분 수가 전체의 1%(최소 4개) 이상인 굵기 중 가장 굵은 것.
    static func wallWidthClass(_ strokes: [Stroke]) -> Double {
        var counts: [Double: Int] = [:]
        for s in strokes { counts[(s.lineWidth * 100).rounded() / 100, default: 0] += s.segments.count }
        let total = counts.values.reduce(0, +)
        let minCount = max(4, total / 100)
        return counts.filter { $0.value >= minCount }.keys.max() ?? counts.keys.max() ?? 0
    }

    /// 짧은 직선 조각을 끝점으로 이어 원호(문 열림 궤적)를 찾는다. 급하게 꺾이는 곳(35° 초과)에서 끊는다.
    static func polylineArcs(_ segments: [Segment]) -> [Arc] {
        let short = segments.filter { $0.length > 0.05 && $0.length <= 25 }
        guard short.count >= 4 else { return [] }
        func key(_ p: Point) -> GridKey2 { GridKey2(x: Int((p.x * 20).rounded()), y: Int((p.y * 20).rounded())) }
        var byVertex: [GridKey2: [Int]] = [:]
        for (i, s) in short.enumerated() {
            byVertex[key(s.a), default: []].append(i)
            byVertex[key(s.b), default: []].append(i)
        }
        var used = Set<Int>()
        var arcs: [Arc] = []
        /// i 번 선분에서 끝점 from 쪽으로 이어지는 다음 선분(차수 2 정점에서만, 완만한 꺾임만).
        func next(_ i: Int, at p: Point) -> (Int, Point)? {
            let k = key(p)
            guard let list = byVertex[k], list.count == 2, let j = list.first(where: { $0 != i }), !used.contains(j) else { return nil }
            let s = short[i], t = short[j]
            let far = key(t.a) == k ? t.b : t.a
            let d1 = (p - (key(s.a) == k ? s.b : s.a)).normalized
            let d2 = (far - p).normalized
            let turn = acos(max(-1, min(1, d1.dot(d2)))) * 180 / .pi
            let ratio = max(s.length, t.length) / max(min(s.length, t.length), 1e-6)
            guard turn <= 35, ratio <= 3 else { return nil }
            return (j, far)
        }
        for i in short.indices.sorted(by: { (short[$0].a.y, short[$0].a.x) < (short[$1].a.y, short[$1].a.x) }) where !used.contains(i) {
            used.insert(i)
            var pts = [short[i].a, short[i].b]
            var cur = i
            while let (j, far) = next(cur, at: pts.last!) {
                used.insert(j)
                pts.append(far)
                cur = j
            }
            cur = i
            while let (j, far) = next(cur, at: pts.first!) {
                used.insert(j)
                pts.insert(far, at: 0)
                cur = j
            }
            if pts.count >= 5, let arc = Arc.fit(points: pts, tolerance: 0.04) { arcs.append(arc) }
        }
        return arcs
    }

    /// 벽 선분을 근접 군집으로 묶어 가장 넓은 군집의 볼록 껍질.
    static func buildingHull(_ walls: [Segment], pageDiagonal: Double) -> Polygon? {
        guard walls.count >= 8 else { return nil }
        let gap = pageDiagonal * 0.04
        let boxes = walls.map { Rect(points: [$0.a, $0.b]).insetBy(-gap / 2) }
        var parent = Array(walls.indices)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
            return x
        }
        for i in walls.indices {
            for j in (i + 1)..<walls.count {
                let a = boxes[i], b = boxes[j]
                if a.maxX < b.minX || b.maxX < a.minX || a.maxY < b.minY || b.maxY < a.minY { continue }
                let ri = find(i), rj = find(j)
                if ri != rj { parent[max(ri, rj)] = min(ri, rj) }
            }
        }
        // 가장 넓은 땅을 차지하는 군집(범위 사각형 넓이) = 건물. 로고·표제란처럼 선이 촘촘한 작은 군집을 피한다.
        var members: [Int: [Int]] = [:]
        for i in walls.indices { members[find(i), default: []].append(i) }
        let spans = members.mapValues { idx -> Double in
            let r = Rect(points: idx.flatMap { [walls[$0].a, walls[$0].b] })
            return idx.count >= 8 ? r.width * r.height : 0
        }
        guard let best = spans.max(by: { ($0.value, -$0.key) < ($1.value, -$1.key) })?.key, spans[best, default: 0] > 0 else { return nil }
        let pts = walls.indices.filter { find($0) == best }.flatMap { [walls[$0].a, walls[$0].b] }
        return Polygon.convexHull(pts).map { PlanarGraph.canonical($0) }
    }

    /// 선분이 두 점을 잇는가(허용 거리 안).
    static func touches(_ s: Segment, _ p: Point, _ q: Point, _ tol: Double) -> Bool {
        (s.a.distance(to: p) <= tol && s.b.distance(to: q) <= tol) || (s.b.distance(to: p) <= tol && s.a.distance(to: q) <= tol)
    }

    /// 문 규격 표기 해석. 예: "W900×H2100", "900x2100", "W 900 X H 2,100".
    public static func parseTag(_ text: String) -> DoorTag? {
        let s = text.uppercased().replacingOccurrences(of: ",", with: "").replacingOccurrences(of: " ", with: "")
        let pattern = #"W?(\d{3,4})(?:MM)?[×X*]H?(\d{3,4})"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let wr = Range(m.range(at: 1), in: s), let hr = Range(m.range(at: 2), in: s),
              let w = Int(s[wr]), let h = Int(s[hr]) else { return nil }
        return DoorTag(raw: text, widthMM: w, heightMM: h)
    }

    /// 벽 두께 띠 같은 가늘고 긴 면을 거른다.
    static func isRoomShaped(_ p: Polygon) -> Bool {
        let b = p.bounds
        let minSide = min(b.width, b.height)
        return minSide > 0 && p.area / (b.width * b.height) > 0.5 && minSide > 10
    }

    static func label(in polygon: Polygon, texts: [TextRun], excluding: [Polygon]) -> String? {
        texts.first { t in polygon.contains(t.center) && !excluding.contains { $0.contains(t.center) } }?.text
    }
}

struct GridKey2: Hashable {
    let x: Int
    let y: Int
}
