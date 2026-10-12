import CoreGraphics
import CoreText
import Foundation

/// 시연·시험용 다중이용업소 영업장 평면도 명세(실측 m 단위).
/// CAD 출력 PDF 관례를 따른다: 벽 = 굵은 중심선, 문 = 문짝 선 + 사분원 열림 궤적, 실명·출입구 표기 = 글자,
/// 표제란 축척 표기, 치수선 + 치수 문자(mm).
public struct SamplePlan: Sendable, Hashable, Identifiable {
    public enum Wall: String, Sendable, Hashable { case left, right, top, bottom }

    public struct Door: Sendable, Hashable {
        public var wall: Wall
        /// 벽 시작점(좌·우 벽은 위쪽 끝, 상·하 벽은 왼쪽 끝)에서 개구부 시작까지 거리(m).
        public var offset: Double
        public var width: Double
        public var label: String?
        /// 문 규격 표기(예: "W900×H2100"). nil 이면 표기 없음.
        public var tag: String?
        /// true = 영업장 밖으로 열림(피난방향).
        public var swingsOut: Bool

        public init(wall: Wall, offset: Double, width: Double, label: String?, tag: String?, swingsOut: Bool = true) {
            self.wall = wall
            self.offset = offset
            self.width = width
            self.label = label
            self.tag = tag
            self.swingsOut = swingsOut
        }
    }

    /// 영업장 내부 칸막이 실(사각형). 아래쪽 벽 가운데에 실 출입문을 낸다.
    public struct Room: Sendable, Hashable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double
        public var label: String
        public var doorWidth: Double

        public init(x: Double, y: Double, width: Double, height: Double, label: String, doorWidth: Double = 0.9) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
            self.label = label
            self.doorWidth = doorWidth
        }
    }

    public var id: String
    public var title: String
    public var summary: String
    public var width: Double
    public var height: Double
    public var hallLabel: String
    public var doors: [Door]
    public var rooms: [Room]
    public var scale: Int

    public init(id: String, title: String, summary: String, width: Double, height: Double, hallLabel: String,
                doors: [Door], rooms: [Room], scale: Int = 100) {
        self.id = id
        self.title = title
        self.summary = summary
        self.width = width
        self.height = height
        self.hallLabel = hallLabel
        self.doors = doors
        self.rooms = rooms
        self.scale = scale
    }

    /// 1 m 를 종이 위 포인트로.
    public var pointsPerMeter: Double { 1000.0 / Double(scale) * 72.0 / 25.4 }
}

public extension SamplePlan {
    /// 적합 후보 — 비상구가 주된 출입구 반대편, 규격 표기 있음.
    static let compliant = SamplePlan(
        id: "sample-a",
        title: "샘플 A · 일반음식점 영업장",
        summary: "비상구가 주된 출입구 반대편에 있고 문 규격이 표기된 도면",
        width: 16, height: 10, hallLabel: "홀",
        doors: [
            Door(wall: .left, offset: 4.4, width: 1.2, label: "주출입구", tag: "W1200×H2100"),
            Door(wall: .right, offset: 7.2, width: 0.9, label: "비상구", tag: "W900×H2100")
        ],
        rooms: [
            Room(x: 11, y: 0, width: 5, height: 4, label: "주방"),
            Room(x: 6, y: 0, width: 4, height: 4, label: "룸1")
        ]
    )

    /// 위험 후보 — 비상구가 주된 출입구 가까이, 폭 미달, 규격 표기 없음.
    static let risky = SamplePlan(
        id: "sample-b",
        title: "샘플 B · 노래연습장 영업장",
        summary: "비상구가 주된 출입구 가까이 있고 폭이 좁은 도면",
        width: 16, height: 10, hallLabel: "복도",
        doors: [
            Door(wall: .left, offset: 1.5, width: 1.2, label: "주출입구", tag: nil),
            Door(wall: .top, offset: 4.0, width: 0.7, label: "비상구", tag: nil)
        ],
        rooms: [
            Room(x: 8, y: 0, width: 4, height: 4, label: "룸1"),
            Room(x: 12, y: 0, width: 4, height: 4, label: "룸2"),
            Room(x: 8, y: 6, width: 4, height: 4, label: "룸3"),
            Room(x: 12, y: 6, width: 4, height: 4, label: "룸4")
        ]
    )

    /// 비상구 없음 — 30㎡ 단일 공간. 피난층 여부에 따라 결과가 갈린다.
    static let noExit = SamplePlan(
        id: "sample-c",
        title: "샘플 C · 휴게음식점 소형 영업장",
        summary: "주된 출입구만 있는 30㎡ 개방형 영업장",
        width: 6, height: 5, hallLabel: "매장",
        doors: [
            Door(wall: .bottom, offset: 2.4, width: 1.2, label: "주출입구", tag: "W1200×H2100")
        ],
        rooms: []
    )

    static let all: [SamplePlan] = [.compliant, .risky, .noExit]
}

// MARK: - PDF 렌더링

public enum SamplePlanRenderer {
    /// A3 가로 벡터 PDF 를 만든다.
    public static func pdf(for plan: SamplePlan) -> Data {
        let page = CGRect(x: 0, y: 0, width: 1190.55, height: 841.89)
        let data = NSMutableData()
        var box = page
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        ctx.beginPDFPage(nil)
        // 좌상단 원점으로 뒤집는다.
        ctx.translateBy(x: 0, y: page.height)
        ctx.scaleBy(x: 1, y: -1)
        draw(plan, in: ctx, page: page)
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }

    static func draw(_ plan: SamplePlan, in ctx: CGContext, page: CGRect) {
        let k = plan.pointsPerMeter
        let origin = CGPoint(x: 140, y: 150)
        func P(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: origin.x + x * k, y: origin.y + y * k) }

        let wallWidth = 0.15 * k
        let partitionWidth = 0.1 * k

        // 외벽: 문 개구부를 뺀 구간만 그린다.
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
        ctx.setLineCap(.butt)
        ctx.setLineWidth(wallWidth)
        for wall in [SamplePlan.Wall.top, .right, .bottom, .left] {
            let len = (wall == .top || wall == .bottom) ? plan.width : plan.height
            let openings = plan.doors.filter { $0.wall == wall }.map { ($0.offset, $0.offset + $0.width) }.sorted { $0.0 < $1.0 }
            var cursor = 0.0
            for (s, e) in openings + [(len, len)] {
                if s > cursor + 1e-6 {
                    let (a, b) = wallPoints(wall, cursor, s, plan)
                    ctx.move(to: P(a.x, a.y))
                    ctx.addLine(to: P(b.x, b.y))
                    ctx.strokePath()
                }
                cursor = e
            }
        }

        // 칸막이 실
        ctx.setLineWidth(partitionWidth)
        for r in plan.rooms {
            let doorStart = r.x + (r.width - r.doorWidth) / 2
            let doorEnd = doorStart + r.doorWidth
            let bottomY = r.y + r.height
            let topY = r.y
            // 실이 영업장 위쪽에 붙어 있으면 아래 벽에, 아래쪽에 붙어 있으면 위 벽에 문을 낸다.
            let doorOnBottom = r.y < plan.height / 2
            let doorY = doorOnBottom ? bottomY : topY
            var lines: [(CGPoint, CGPoint)] = [
                (P(r.x, r.y), P(r.x + r.width, r.y)),
                (P(r.x + r.width, r.y), P(r.x + r.width, bottomY)),
                (P(r.x, bottomY), P(r.x + r.width, bottomY)),
                (P(r.x, r.y), P(r.x, bottomY))
            ]
            let doorEdgeIndex = doorOnBottom ? 2 : 0
            lines.remove(at: doorEdgeIndex)
            lines.append((P(r.x, doorY), P(doorStart, doorY)))
            lines.append((P(doorEnd, doorY), P(r.x + r.width, doorY)))
            for (a, b) in lines {
                ctx.move(to: a)
                ctx.addLine(to: b)
                ctx.strokePath()
            }
            // 실 문: 실 안쪽으로 열림
            let hinge = P(doorStart, doorY)
            let dir: CGFloat = doorOnBottom ? -1 : 1
            drawDoor(ctx, hinge: hinge, closedEnd: P(doorEnd, doorY), openEnd: CGPoint(x: hinge.x, y: hinge.y + dir * r.doorWidth * k))
            text(ctx, r.label, at: P(r.x + r.width / 2, r.y + r.height / 2), size: 11)
        }

        // 영업장 출입문
        for d in plan.doors {
            let (hingeM, closedM) = wallPoints(d.wall, d.offset, d.offset + d.width, plan)
            let hinge = P(hingeM.x, hingeM.y)
            let closed = P(closedM.x, closedM.y)
            let outward = outwardNormal(d.wall)
            let sign: CGFloat = d.swingsOut ? 1 : -1
            let open = CGPoint(x: hinge.x + outward.x * sign * d.width * k, y: hinge.y + outward.y * sign * d.width * k)
            drawDoor(ctx, hinge: hinge, closedEnd: closed, openEnd: open)
            let mid = CGPoint(x: (hinge.x + closed.x) / 2, y: (hinge.y + closed.y) / 2)
            let labelOffset: CGFloat = 1.9 * k
            let labelAt = CGPoint(x: mid.x + outward.x * labelOffset, y: mid.y + outward.y * labelOffset)
            if let label = d.label { text(ctx, label, at: labelAt, size: 11) }
            if let tag = d.tag {
                text(ctx, tag, at: CGPoint(x: labelAt.x, y: labelAt.y + 14), size: 8)
            }
        }

        // 홀 이름
        text(ctx, plan.hallLabel, at: P(plan.width * 0.35, plan.height * 0.6), size: 13)

        // 치수선(가로·세로) + 치수 문자(mm)
        ctx.setLineWidth(0.4)
        let dimY = -2.6
        ctx.move(to: P(0, dimY)); ctx.addLine(to: P(plan.width, dimY)); ctx.strokePath()
        for x in [0, plan.width] {
            ctx.move(to: P(x, dimY - 0.25)); ctx.addLine(to: P(x, dimY + 0.25)); ctx.strokePath()
        }
        text(ctx, String(Int((plan.width * 1000).rounded())), at: P(plan.width / 2, dimY - 0.45), size: 9)
        let dimX = -3.2
        ctx.move(to: P(dimX, 0)); ctx.addLine(to: P(dimX, plan.height)); ctx.strokePath()
        for y in [0, plan.height] {
            ctx.move(to: P(dimX - 0.25, y)); ctx.addLine(to: P(dimX + 0.25, y)); ctx.strokePath()
        }
        text(ctx, String(Int((plan.height * 1000).rounded())), at: P(dimX - 0.6, plan.height / 2), size: 9)

        // 표제란
        let tb = CGRect(x: page.width - 330, y: page.height - 120, width: 290, height: 80)
        ctx.setLineWidth(0.6)
        ctx.stroke(tb)
        text(ctx, plan.title, at: CGPoint(x: tb.midX, y: tb.minY + 20), size: 11)
        text(ctx, "영업장 평면도", at: CGPoint(x: tb.midX, y: tb.minY + 42), size: 9)
        text(ctx, "축척 1:\(plan.scale)", at: CGPoint(x: tb.midX, y: tb.minY + 62), size: 9)
    }

    static func wallPoints(_ wall: SamplePlan.Wall, _ s: Double, _ e: Double, _ plan: SamplePlan) -> (Point, Point) {
        switch wall {
        case .top: return (Point(s, 0), Point(e, 0))
        case .bottom: return (Point(s, plan.height), Point(e, plan.height))
        case .left: return (Point(0, s), Point(0, e))
        case .right: return (Point(plan.width, s), Point(plan.width, e))
        }
    }

    static func outwardNormal(_ wall: SamplePlan.Wall) -> CGPoint {
        switch wall {
        case .top: return CGPoint(x: 0, y: -1)
        case .bottom: return CGPoint(x: 0, y: 1)
        case .left: return CGPoint(x: -1, y: 0)
        case .right: return CGPoint(x: 1, y: 0)
        }
    }

    /// 문짝(경첩 → 열린 위치) 선 + 열린 위치 → 닫힌 위치 사분원.
    static func drawDoor(_ ctx: CGContext, hinge: CGPoint, closedEnd: CGPoint, openEnd: CGPoint) {
        ctx.setLineWidth(0.5)
        ctx.move(to: hinge)
        ctx.addLine(to: openEnd)
        ctx.strokePath()
        let r = hypot(openEnd.x - hinge.x, openEnd.y - hinge.y)
        let a0 = atan2(openEnd.y - hinge.y, openEnd.x - hinge.x)
        let a1 = atan2(closedEnd.y - hinge.y, closedEnd.x - hinge.x)
        var delta = a1 - a0
        while delta > .pi { delta -= 2 * .pi }
        while delta < -.pi { delta += 2 * .pi }
        ctx.move(to: openEnd)
        ctx.addArc(center: hinge, radius: r, startAngle: a0, endAngle: a0 + delta, clockwise: delta < 0)
        ctx.strokePath()
    }

    static func text(_ ctx: CGContext, _ string: String, at center: CGPoint, size: CGFloat) {
        let font = CTFontCreateWithName("AppleSDGothicNeo-Regular" as CFString, size, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attrs))
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: center.x - bounds.width / 2, y: center.y + bounds.height / 2)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}
