import Foundation

/// 벡터 페이지를 영업장 평면 모델로 해석한다(D-03). 규칙 기반·결정적.
public enum PlanInterpreter {
    static let emergencyKeywords = ["비상구", "비상출구", "비상 출구", "피난구", "EXIT"]
    static let mainKeywords = ["주출입구", "주 출입구", "주된 출입구", "주된출입구", "출입구", "입구", "ENTRANCE"]

    public static func interpret(_ page: VectorPage) -> PlanModel {
        var notes: [String] = []

        // 1. 벽 = 굵은 선. 기준 = 가장 굵은 선의 45% 이상(최소 1.2pt).
        let stroked = page.strokes.filter(\.isStroked)
        let maxWidth = stroked.map(\.lineWidth).max() ?? 0
        let wallThreshold = max(1.2, maxWidth * 0.45)
        let wallSegments = stroked.filter { $0.lineWidth >= wallThreshold }.flatMap(\.segments)
        let thinSegments = stroked.filter { $0.lineWidth < wallThreshold }.flatMap(\.segments)
        if wallSegments.count < 4 {
            notes.append("벽으로 볼 굵은 선이 부족하다(\(wallSegments.count)개). 벽을 굵은 선으로 출력한 CAD PDF 가 필요하다.")
        }
        let tolerance = max(1.5, maxWidth * 0.75)

        // 2. 문 = 원호(스윕 60~120°) + 경첩에서 나가는 문짝 선.
        var rawDoors: [(hinge: Point, closed: Point, open: Point, radius: Double)] = []
        for run in stroked.flatMap(\.curveRuns) {
            guard let arc = Arc.fit(run), arc.sweepDegrees >= 60, arc.sweepDegrees <= 120,
                  arc.radius >= 8, arc.radius <= 150 else { continue }
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
        var boundary = faces.outer
        var boundaryConfidence = 0.9
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
            let onBoundary = boundary.map { $0.distanceToBoundary(mid) <= tolerance * 1.5 } ?? false
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
