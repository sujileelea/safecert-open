import SafeCertKit
import SwiftUI

/// 도면 + 오버레이. 확대(핀치)·이동(드래그)·두 번 탭 원위치. 표식을 탭하면 해당 판정을 고른다.
struct DrawingCanvas: View {
    enum Mode {
        /// 확인 단계: 인식한 외곽·문만.
        case detected
        /// 결과 단계: 판정 색.
        case verdicts([Verdict])
    }

    let pdf: Data
    let pageIndex: Int
    let plan: PlanModel
    let mode: Mode
    @Binding var selectedID: String?
    /// 검토자가 확인 체크한 판정 — 표식에 초록 체크를 붙인다.
    var confirmed: Set<String> = []

    @State private var rendered: RenderedPage?
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var drag: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            // 처음 화면은 페이지 전체가 아니라 영업장(+ 출입구 표기 여백)에 맞춘다.
            let focus = focusRect
            let fit = min(geo.size.width / focus.width, geo.size.height / focus.height) * 0.92
            let size = CGSize(width: plan.pageWidth * fit, height: plan.pageHeight * fit)
            let shift = CGSize(width: (plan.pageWidth / 2 - focus.midX) * fit, height: (plan.pageHeight / 2 - focus.midY) * fit)
            let z = zoom * pinch
            ZStack {
                Color.white
                ZStack {
                    if let rendered {
                        Image(decorative: rendered.image, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: size.width, height: size.height)
                    } else {
                        ProgressView().frame(width: size.width, height: size.height)
                    }
                    overlay(fit: fit, zoom: z).frame(width: size.width, height: size.height)
                    markers(fit: fit, zoom: z).frame(width: size.width, height: size.height)
                }
                .frame(width: size.width, height: size.height)
                .offset(shift)
                .scaleEffect(z)
                .offset(x: pan.width + drag.width, y: pan.height + drag.height)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .overlay { ReviewWatermark() }
            .overlay(alignment: .bottomLeading) {
                if case .verdicts = mode { legend.padding(16) }
            }
            .contentShape(Rectangle())
            .gesture(
                SimultaneousGesture(
                    MagnifyGesture().updating($pinch) { v, s, _ in s = v.magnification }
                        .onEnded { v in zoom = min(8, max(1, zoom * v.magnification)) },
                    DragGesture().updating($drag) { v, s, _ in s = v.translation }
                        .onEnded { v in pan.width += v.translation.width; pan.height += v.translation.height }
                )
            )
            .onTapGesture(count: 2) {
                withAnimation(.snappy) {
                    zoom = 1
                    pan = .zero
                }
            }
        }
        .task(id: "\(pdf.count)-\(pageIndex)") {
            rendered = await PageRenderer.render(pdf: pdf, pageIndex: pageIndex)
        }
    }

    /// 영업장 외곽 + 외부 문 표기를 감싸는 영역(포인트). 외곽이 없으면 페이지 전체.
    private var focusRect: CGRect {
        guard let b = plan.boundary?.bounds else { return CGRect(x: 0, y: 0, width: plan.pageWidth, height: plan.pageHeight) }
        var r = CGRect(x: b.minX, y: b.minY, width: b.width, height: b.height)
        for d in plan.exteriorDoors {
            r = r.union(CGRect(x: d.openEnd.x, y: d.openEnd.y, width: 1, height: 1))
            // 출입구 표기·규격 표기도 화면 안에 둔다.
            for t in plan.texts where t.text == d.label || t.text == d.tag?.raw {
                guard t.center.distance(to: d.center) < d.radius * 4 + 80 else { continue }
                r = r.union(CGRect(x: t.bounds.minX, y: t.bounds.minY, width: t.bounds.width, height: t.bounds.height))
            }
        }
        let margin = max(r.width, r.height) * 0.12
        return r.insetBy(dx: -margin, dy: -margin)
    }

    private var verdicts: [Verdict] {
        if case .verdicts(let v) = mode { return v }
        return []
    }

    // MARK: 오버레이

    private func overlay(fit: CGFloat, zoom: CGFloat) -> some View {
        Canvas { ctx, _ in
            func pt(_ p: Point) -> CGPoint { CGPoint(x: p.x * fit, y: p.y * fit) }
            let lw = 1 / zoom

            if let b = plan.boundary {
                var path = Path()
                path.addLines(b.vertices.map { pt($0) })
                path.closeSubpath()
                ctx.stroke(path, with: .color(Theme.ink.opacity(0.35)), style: StrokeStyle(lineWidth: 1.5 * lw, dash: [6 * lw, 4 * lw]))
            }

            switch mode {
            case .detected:
                for room in plan.rooms {
                    var path = Path()
                    path.addLines(room.polygon.vertices.map { pt($0) })
                    path.closeSubpath()
                    ctx.fill(path, with: .color(Theme.ink.opacity(0.04)))
                }
                for d in plan.doors {
                    var chord = Path()
                    chord.move(to: pt(d.hinge))
                    chord.addLine(to: pt(d.closedEnd))
                    let tint: Color = d.role == .interior ? Theme.secondary : Theme.ink
                    ctx.stroke(chord, with: .color(tint), lineWidth: (d.role == .interior ? 2 : 4) * lw)
                }
            case .verdicts(let list):
                // 선택된 판정의 영역·선은 진하게, 나머지는 옅게
                for v in list.reversed() {
                    let color = Theme.color(v.color)
                    let selected = selectedID == v.id
                    let alpha: Double = selectedID == nil || selected ? 1 : 0.35
                    if let area = v.location.area, selected {
                        var path = Path()
                        path.addLines(area.vertices.map { pt($0) })
                        path.closeSubpath()
                        ctx.fill(path, with: .color(color.opacity(0.10)))
                        ctx.stroke(path, with: .color(color), lineWidth: 3 * lw)
                    }
                    if let line = v.location.line {
                        var path = Path()
                        path.move(to: pt(line.a))
                        path.addLine(to: pt(line.b))
                        let dashed = v.rule == .exitLocation
                        ctx.stroke(path, with: .color(color.opacity(alpha)),
                                   style: StrokeStyle(lineWidth: (selected ? 5 : 3.5) * lw, lineCap: .round, dash: dashed ? [8 * lw, 6 * lw] : []))
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func markers(fit: CGFloat, zoom: CGFloat) -> some View {
        ZStack {
            switch mode {
            case .detected:
                ForEach(plan.exteriorDoors) { d in
                    Text(d.role == .mainEntrance ? "주" : d.role == .emergencyExit ? "비" : "?")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Theme.ink, in: Circle())
                        .scaleEffect(1 / zoom)
                        .position(x: d.center.x * fit, y: d.center.y * fit)
                }
            case .verdicts(let list):
                ForEach(Array(markerItems(list).enumerated()), id: \.offset) { _, item in
                    Button {
                        withAnimation(.snappy) { selectedID = item.verdict.id }
                    } label: {
                        Text("\(item.number)")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 26, height: 26)
                            .background(Theme.color(item.verdict.color), in: Circle())
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                            .overlay(alignment: .topTrailing) {
                                if confirmed.contains(item.verdict.id) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(.white, Theme.color(.green))
                                        .offset(x: 7, y: -7)
                                }
                            }
                            .shadow(color: .black.opacity(selectedID == item.verdict.id ? 0.35 : 0.15), radius: 3, y: 1)
                            .scaleEffect((selectedID == item.verdict.id ? 1.25 : 1) / zoom)
                            .opacity(selectedID == nil || selectedID == item.verdict.id ? 1 : 0.55)
                    }
                    .buttonStyle(.plain)
                    .position(x: item.point.x * fit + item.nudge.width, y: item.point.y * fit + item.nudge.height)
                }
            }
        }
    }

    private struct MarkerItem {
        let verdict: Verdict
        let number: Int
        let point: Point
        let nudge: CGSize
    }

    /// 판정마다 대표 표식 하나: 영업장 전체 판정은 외곽 중심, 거리 판정은 선 가운데, 문 판정은 문.
    /// 표식끼리 가까우면(포인트 기준 12 이내) 아래로 비켜 놓는다.
    private func markerItems(_ list: [Verdict]) -> [MarkerItem] {
        var placed: [Point] = []
        return list.enumerated().compactMap { i, v in
            let anchor: Point?
            switch v.rule {
            case .exitRequired: anchor = v.location.area?.centroid ?? v.location.markers.first
            case .exitLocation: anchor = v.location.line?.midpoint ?? v.location.markers.last
            case .exitSize: anchor = v.location.markers.first
            }
            guard var p = anchor else { return nil }
            while placed.contains(where: { $0.distance(to: p) < 12 }) { p = Point(p.x, p.y + 12) }
            placed.append(p)
            return MarkerItem(verdict: v, number: i + 1, point: p, nudge: .zero)
        }
    }

    private var legend: some View {
        HStack(spacing: 12) {
            ForEach(VerdictColor.allCases, id: \.self) { c in
                HStack(spacing: 4) {
                    ColorDot(color: c, size: 8)
                    Text(c.meaning).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.white.opacity(0.92), in: Capsule())
        .overlay(Capsule().stroke(Theme.hairline))
    }
}
