import CoreGraphics
import CoreText
import Foundation

/// 보고서 → A4 PDF(CoreGraphics·CoreText). 쪽마다 머리글·「감수 전 · 참고용」 바닥글·워터마크를 넣고,
/// AI 가 쓴 문단은 색 상자와 「AI 작성」 표시로 규칙 엔진 문장과 구분한다.
public enum ReportPDF {
    public static func render(_ report: InspectionReport, drawing pdf: Data, pageIndex: Int, plan: PlanModel) -> Data {
        // 1차로 쪽 수를 센 뒤 「n / 전체」 바닥글을 넣어 다시 그린다.
        let count = draw(report, drawing: pdf, pageIndex: pageIndex, plan: plan, totalPages: nil).pages
        return draw(report, drawing: pdf, pageIndex: pageIndex, plan: plan, totalPages: count).data
    }

    static func draw(_ report: InspectionReport, drawing pdf: Data, pageIndex: Int, plan: PlanModel, totalPages: Int?) -> (data: Data, pages: Int) {
        let out = NSMutableData()
        var media = CGRect(x: 0, y: 0, width: Page.width, height: Page.height)
        let info = [kCGPDFContextTitle: "\(report.title) — \(report.projectName)", kCGPDFContextCreator: "SafeCert"] as CFDictionary
        guard let consumer = CGDataConsumer(data: out as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &media, info) else { return (Data(), 0) }
        let c = Composer(ctx: ctx, report: report, totalPages: totalPages)
        c.cover()
        c.drawingPage(pdf: pdf, pageIndex: pageIndex, plan: plan)
        for s in report.sections { c.section(s) }
        c.closing()
        c.finish()
        return (out as Data, c.pageNumber)
    }
}

// MARK: - 쪽 규격·스타일

enum Page {
    static let width: CGFloat = 595.28
    static let height: CGFloat = 841.89
    static let margin: CGFloat = 46
    static let top: CGFloat = 58
    static let bottom: CGFloat = 56
    static var contentWidth: CGFloat { width - margin * 2 }
}

enum Style {
    static func font(_ size: CGFloat, _ weight: String = "Regular") -> CTFont {
        CTFontCreateWithName("AppleSDGothicNeo-\(weight)" as CFString, size, nil)
    }

    static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    static let ink = rgb(0x1C1C1E)
    static let secondary = rgb(0x6E6E73)
    static let line = rgb(0xE3E3E8)
    static let card = rgb(0xF5F5F7)
    static let reserved = rgb(0x6B4FBB)
    static let ai = rgb(0x3A5BD9)
    static let aiBackground = rgb(0xEEF2FF)
    static let boundary = rgb(0x3A5BD9)

    static func color(_ c: VerdictColor) -> CGColor {
        switch c {
        case .red: rgb(0xD93025)
        case .orange: rgb(0xE8710A)
        case .yellow: rgb(0xE0A800)
        case .green: rgb(0x1E8E3E)
        case .gray: rgb(0x8A8F96)
        }
    }

    static func text(_ s: String, _ font: CTFont, _ color: CGColor = ink, lineSpacing: CGFloat = 2.5) -> NSAttributedString {
        var spacing = lineSpacing
        let style = withUnsafeBytes(of: &spacing) { ptr -> CTParagraphStyle in
            var settings = [CTParagraphStyleSetting(spec: .lineSpacingAdjustment, valueSize: MemoryLayout<CGFloat>.size, value: ptr.baseAddress!)]
            return CTParagraphStyleCreate(&settings, settings.count)
        }
        return NSAttributedString(string: s, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): style,
        ])
    }
}

// MARK: - 조판기

/// 위에서부터 내려 쓰는 조판기. `cursor` 는 쪽 위에서 잰 거리(포인트), 그리기는 PDF 기본 좌표(좌하단 원점).
final class Composer {
    let ctx: CGContext
    let report: InspectionReport
    let totalPages: Int?
    private(set) var pageNumber = 0
    private var cursor: CGFloat = 0
    private var pageOpen = false

    init(ctx: CGContext, report: InspectionReport, totalPages: Int?) {
        self.ctx = ctx
        self.report = report
        self.totalPages = totalPages
    }

    var remaining: CGFloat { Page.height - Page.bottom - cursor }

    /// 위 기준 사각형 → PDF 좌표.
    func rect(x: CGFloat, top: CGFloat, width: CGFloat, height: CGFloat) -> CGRect {
        CGRect(x: x, y: Page.height - top - height, width: width, height: height)
    }

    func newPage() {
        if pageOpen { closePage() }
        ctx.beginPDFPage(nil)
        pageOpen = true
        pageNumber += 1
        cursor = Page.top
        ctx.textMatrix = .identity
        watermark()
        header()
    }

    func finish() {
        if pageOpen { closePage() }
        ctx.closePDF()
    }

    private func closePage() {
        footer()
        ctx.endPDFPage()
        pageOpen = false
    }

    func ensure(_ height: CGFloat) {
        if !pageOpen || remaining < height { newPage() }
    }

    func space(_ h: CGFloat) { cursor += h }

    // MARK: 쪽 장식

    private func header() {
        let left = Style.text("\(report.title) · \(report.projectName)", Style.font(8), Style.secondary)
        let right = Style.text("법령 기준일 \(report.result.lawBaseDate)", Style.font(8), Style.secondary)
        drawLine(left, x: Page.margin, baselineFromTop: 32)
        drawLine(right, x: Page.width - Page.margin - lineWidth(right), baselineFromTop: 32)
        hairline(top: 40)
    }

    private func footer() {
        hairline(top: Page.height - 40)
        let left = Style.text("감수 전 · 참고용 — \(InspectionReport.disclaimer)", Style.font(7.5), Style.secondary)
        let n = totalPages.map { "\(pageNumber) / \($0)" } ?? "\(pageNumber)"
        let right = Style.text(n, Style.font(8), Style.secondary)
        drawLine(left, x: Page.margin, baselineFromTop: Page.height - 26)
        drawLine(right, x: Page.width - Page.margin - lineWidth(right), baselineFromTop: Page.height - 26)
    }

    private func watermark() {
        ctx.saveGState()
        ctx.translateBy(x: Page.width / 2, y: Page.height / 2)
        ctx.rotate(by: .pi / 6)
        let mark = Style.text("감수 전 · 참고용", Style.font(64, "Bold"), Style.rgb(0x000000, 0.045))
        let w = lineWidth(mark)
        ctx.textPosition = CGPoint(x: -w / 2, y: -20)
        CTLineDraw(CTLineCreateWithAttributedString(mark), ctx)
        ctx.restoreGState()
    }

    func hairline(top: CGFloat, x: CGFloat = Page.margin, width: CGFloat = Page.contentWidth, color: CGColor = Style.line) {
        ctx.setFillColor(color)
        ctx.fill(rect(x: x, top: top, width: width, height: 0.6))
    }

    func lineWidth(_ s: NSAttributedString) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(s), nil, nil, nil))
    }

    func drawLine(_ s: NSAttributedString, x: CGFloat, baselineFromTop: CGFloat) {
        ctx.textPosition = CGPoint(x: x, y: Page.height - baselineFromTop)
        CTLineDraw(CTLineCreateWithAttributedString(s), ctx)
    }

    // MARK: 글 흐름

    func measure(_ s: NSAttributedString, width: CGFloat) -> CGFloat {
        let fs = CTFramesetterCreateWithAttributedString(s)
        return ceil(CTFramesetterSuggestFrameSizeWithConstraints(fs, CFRange(location: 0, length: 0), nil,
                                                                 CGSize(width: width, height: .greatestFiniteMagnitude), nil).height)
    }

    /// 쪽을 넘겨 가며 흐르는 글.
    func flow(_ s: NSAttributedString, indent: CGFloat = 0, trailing: CGFloat = 0, after: CGFloat = 6) {
        let width = Page.contentWidth - indent - trailing
        let fs = CTFramesetterCreateWithAttributedString(s)
        var start = 0
        while start < s.length {
            ensure(14)
            let frameRect = rect(x: Page.margin + indent, top: cursor, width: width, height: remaining)
            let frame = CTFramesetterCreateFrame(fs, CFRange(location: start, length: 0), CGPath(rect: frameRect, transform: nil), nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            if visible.length == 0 {
                newPage()
                continue
            }
            CTFrameDraw(frame, ctx)
            let used = CTFramesetterSuggestFrameSizeWithConstraints(fs, CFRange(location: start, length: visible.length), nil,
                                                                    CGSize(width: width, height: .greatestFiniteMagnitude), nil).height
            cursor += ceil(used)
            start += visible.length
            if start < s.length { newPage() }
        }
        cursor += after
    }

    /// 쪽 안에서 끊지 않는 글(높이를 재고 모자라면 다음 쪽).
    func block(_ s: NSAttributedString, indent: CGFloat = 0, after: CGFloat = 6) {
        let h = measure(s, width: Page.contentWidth - indent)
        if h < Page.height - Page.top - Page.bottom { ensure(h) }
        flow(s, indent: indent, after: after)
    }

    func heading(_ title: String, size: CGFloat = 13, before: CGFloat = 10) {
        ensure(size + 40)
        space(before)
        flow(Style.text(title, Style.font(size, "Bold")), after: 6)
    }

    /// 작은 꼬리표(색 테두리 알약).
    @discardableResult
    func tag(_ text: String, color: CGColor, x: CGFloat, top: CGFloat) -> CGFloat {
        let s = Style.text(text, Style.font(7.5, "SemiBold"), color)
        let w = lineWidth(s) + 10
        let r = rect(x: x, top: top, width: w, height: 13)
        ctx.setStrokeColor(color)
        ctx.setLineWidth(0.7)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 6.5, cornerHeight: 6.5, transform: nil))
        ctx.strokePath()
        drawLine(s, x: x + 5, baselineFromTop: top + 9.6)
        return w
    }

    /// 서술 문단 — AI 문장은 연한 파랑 상자 + 「AI 작성」, 규칙 엔진 문장은 꼬리표만.
    func narrative(_ n: ReportNarrative, bullets: Bool = false) {
        // AI 문장은 한 문단, 규칙 엔진 문장(마침표 없는 항목 줄)은 줄마다.
        let body = bullets ? n.sentences.map { "• \($0)" }.joined(separator: "\n") : n.isAI ? n.text : n.sentences.joined(separator: "\n")
        let s = Style.text(body, Style.font(10), Style.ink, lineSpacing: 3.5)
        let pad: CGFloat = 9
        let h = measure(s, width: Page.contentWidth - pad * 2) + pad * 2 + 18
        ensure(min(h, 200))
        let top = cursor
        if n.isAI && h < remaining {
            ctx.setFillColor(Style.aiBackground)
            ctx.addPath(CGPath(roundedRect: rect(x: Page.margin, top: top, width: Page.contentWidth, height: h), cornerWidth: 6, cornerHeight: 6, transform: nil))
            ctx.fillPath()
        }
        if n.isAI {
            let model = report.model ?? "생성형 AI"
            tag("AI 작성 · \(model) · 근거 대조 통과 문장만", color: Style.ai, x: Page.margin + pad, top: top + pad)
        } else {
            tag("규칙 엔진 문장", color: Style.secondary, x: Page.margin + pad, top: top + pad)
        }
        cursor = top + pad + 18
        flow(s, indent: pad, trailing: pad, after: pad + 6)
    }

    // MARK: 표지·요약

    func cover() {
        newPage()
        let r = report.result
        flow(Style.text("SafeCert · 소프트웨어 사전검토", Style.font(9, "SemiBold"), Style.secondary), after: 4)
        flow(Style.text(report.title, Style.font(24, "Bold")), after: 4)
        flow(Style.text(report.projectName, Style.font(14, "SemiBold")), after: 2)
        flow(Style.text(report.fileName, Style.font(9), Style.secondary), after: 12)

        // 기본 정보
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.timeZone = TimeZone(identifier: "Asia/Seoul")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        let rows: [(String, String)] = [
            ("판정 일시", f.string(from: report.judgedAt)),
            ("보고서 작성", f.string(from: report.createdAt)),
            ("법령 기준일", "\(r.lawBaseDate) · 스냅샷 \(r.snapshotID)"),
            ("축척", ExplanationComposer.scaleLine(r.scale)),
        ] + report.scope.enumerated().map { ($0.offset == 0 ? "검토 범위" : "", $0.element) }
        for (k, v) in rows {
            let line = Style.text(k, Style.font(9, "SemiBold"), Style.secondary)
            let value = Style.text(v, Style.font(9.5))
            let top = cursor
            drawLine(line, x: Page.margin, baselineFromTop: top + 10)
            let fs = CTFramesetterCreateWithAttributedString(value)
            let w = Page.contentWidth - 78
            let h = measure(value, width: w)
            CTFrameDraw(CTFramesetterCreateFrame(fs, CFRange(location: 0, length: 0), CGPath(rect: rect(x: Page.margin + 78, top: top, width: w, height: h), transform: nil), nil), ctx)
            cursor += max(h, 13) + 3
        }
        space(10)

        // 전체 판정 상자(V-07)
        let boxTop = cursor
        let boxH: CGFloat = 78
        ctx.setFillColor(Style.card)
        ctx.addPath(CGPath(roundedRect: rect(x: Page.margin, top: boxTop, width: Page.contentWidth, height: boxH), cornerWidth: 8, cornerHeight: 8, transform: nil))
        ctx.fillPath()
        var x = Page.margin + 14
        if r.summary.isReserved { x += tag("유보", color: Style.reserved, x: x, top: boxTop + 12) + 6 }
        tag(r.summary.subline, color: Style.secondary, x: x, top: boxTop + 12)
        drawLine(Style.text(r.summary.headline, Style.font(18, "Bold"), r.summary.isReserved ? Style.reserved : Style.ink), x: Page.margin + 14, baselineFromTop: boxTop + 48)
        var cx = Page.margin + 14
        for color in VerdictColor.allCases {
            guard let n = r.summary.counts[color], n > 0 else { continue }
            ctx.setFillColor(Style.color(color))
            ctx.fillEllipse(in: rect(x: cx, top: boxTop + 59, width: 8, height: 8))
            let t = Style.text("\(color.meaning) \(n)", Style.font(9))
            drawLine(t, x: cx + 12, baselineFromTop: boxTop + 66.5)
            cx += lineWidth(t) + 26
        }
        cursor = boxTop + boxH + 14

        heading("요약", size: 12, before: 0)
        narrative(report.summary)

        heading("판정 목록", size: 12)
        for s in report.sections { verdictRow(s) }
        space(10)

        // 고정 문구(X-01)
        let notice = [
            InspectionReport.disclaimer,
            InspectionReport.aiNotice,
            "판정 범위 밖의 항목과 「판정 유보」 항목은 적합으로 보지 않는다. 제재는 종류와 법정 범위만 적고 금액은 산정하지 않는다.",
        ].joined(separator: "\n")
        block(Style.text(notice, Style.font(8.5), Style.secondary, lineSpacing: 3))
    }

    func verdictRow(_ s: ReportVerdictSection) {
        let v = s.verdict
        let text = Style.text("\(v.title) · \(v.target)\n\(v.color.meaning) — \(v.summary.isEmpty ? v.badge.displayName : v.summary)", Style.font(9.5), Style.ink, lineSpacing: 2)
        let h = measure(text, width: Page.contentWidth - 30)
        ensure(h + 8)
        let top = cursor
        numberBadge(s.number, color: Style.color(v.color), center: CGPoint(x: Page.margin + 9, y: Page.height - top - 9), radius: 9)
        let fs = CTFramesetterCreateWithAttributedString(text)
        CTFrameDraw(CTFramesetterCreateFrame(fs, CFRange(location: 0, length: 0), CGPath(rect: rect(x: Page.margin + 30, top: top, width: Page.contentWidth - 30, height: h), transform: nil), nil), ctx)
        cursor = top + max(h, 18) + 6
        hairline(top: cursor - 3)
    }

    func numberBadge(_ n: Int, color: CGColor, center: CGPoint, radius: CGFloat) {
        ctx.setFillColor(color)
        ctx.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        let t = Style.text("\(n)", Style.font(radius * 1.05, "Bold"), Style.rgb(0xFFFFFF))
        ctx.textPosition = CGPoint(x: center.x - lineWidth(t) / 2, y: center.y - radius * 0.36)
        CTLineDraw(CTLineCreateWithAttributedString(t), ctx)
    }

    // MARK: 도면 쪽

    func drawingPage(pdf: Data, pageIndex: Int, plan: PlanModel) {
        newPage()
        heading("도면 표시", size: 14, before: 0)
        flow(Style.text("번호는 판정 목록 순서다. 색은 현행 법령상 지위, 파란 점선은 자동으로 읽은 영업장 외곽이다.", Style.font(9), Style.secondary), after: 8)
        guard let provider = CGDataProvider(data: pdf as CFData), let doc = CGPDFDocument(provider),
              let page = doc.page(at: pageIndex + 1) else {
            flow(Style.text("도면을 열 수 없다.", Style.font(10), Style.secondary))
            return
        }
        let box = page.getBoxRect(.mediaBox)
        let pageRect = Rect(minX: 0, minY: 0, maxX: Double(box.width), maxY: Double(box.height))
        let focus = focusRect(plan: plan, page: pageRect)
        let target = rect(x: Page.margin, top: cursor, width: Page.contentWidth, height: remaining - 70)
        let s = min(target.width / CGFloat(focus.width), target.height / CGFloat(focus.height))
        let drawn = CGRect(x: target.midX - CGFloat(focus.width) * s / 2, y: target.maxY - CGFloat(focus.height) * s,
                           width: CGFloat(focus.width) * s, height: CGFloat(focus.height) * s)
        // 도면 좌표(좌상단 원점, 포인트) → 보고서 PDF 좌표
        func map(_ p: Point) -> CGPoint {
            CGPoint(x: drawn.minX + CGFloat(p.x - focus.minX) * s, y: drawn.maxY - CGFloat(p.y - focus.minY) * s)
        }

        ctx.saveGState()
        ctx.clip(to: drawn)
        ctx.setFillColor(Style.rgb(0xFFFFFF))
        ctx.fill(drawn)
        ctx.translateBy(x: drawn.minX - (box.minX + CGFloat(focus.minX)) * s, y: drawn.maxY - (box.maxY - CGFloat(focus.minY)) * s)
        ctx.scaleBy(x: s, y: s)
        ctx.drawPDFPage(page)
        ctx.restoreGState()

        ctx.saveGState()
        ctx.clip(to: drawn)
        if let b = plan.boundary, b.vertices.count >= 3 {
            ctx.setStrokeColor(Style.boundary)
            ctx.setLineWidth(1.2)
            ctx.setLineDash(phase: 0, lengths: [5, 3])
            ctx.addLines(between: b.vertices.map(map))
            ctx.closePath()
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        }
        for section in report.sections {
            let v = section.verdict
            let color = Style.color(v.color)
            if let area = v.location.area, area.vertices.count >= 3 {
                ctx.setFillColor(color.copy(alpha: 0.12) ?? color)
                ctx.addLines(between: area.vertices.map(map))
                ctx.closePath()
                ctx.fillPath()
            }
            if let line = v.location.line {
                ctx.setStrokeColor(color)
                ctx.setLineWidth(2)
                ctx.setLineDash(phase: 0, lengths: [6, 3])
                ctx.strokeLineSegments(between: [map(line.a), map(line.b)])
                ctx.setLineDash(phase: 0, lengths: [])
            }
            let points = v.location.markers.isEmpty ? (v.location.area.map { [$0.centroid] } ?? []) : v.location.markers
            for p in points.dropFirst() {
                ctx.setFillColor(color)
                ctx.fillEllipse(in: CGRect(x: map(p).x - 4, y: map(p).y - 4, width: 8, height: 8))
            }
        }
        // 번호 표시는 맨 위에. 같은 자리에 겹치면 옆으로 벌리고 가는 선으로 제자리를 잇는다.
        var placed: [CGPoint] = []
        for section in report.sections {
            let v = section.verdict
            guard let p = v.location.markers.first ?? v.location.area?.centroid else { continue }
            let anchor = map(p)
            var at = anchor
            var step = 0
            while placed.contains(where: { hypot($0.x - at.x, $0.y - at.y) < 19 }) && step < 12 {
                step += 1
                let angle = -CGFloat.pi / 4 + CGFloat(step) * .pi / 3
                at = CGPoint(x: anchor.x + cos(angle) * 22 * CGFloat(1 + step / 6), y: anchor.y + sin(angle) * 22 * CGFloat(1 + step / 6))
            }
            if at != anchor {
                ctx.setStrokeColor(Style.color(v.color))
                ctx.setLineWidth(1)
                ctx.strokeLineSegments(between: [anchor, at])
            }
            numberBadge(section.number, color: Style.color(v.color), center: at, radius: 9)
            placed.append(at)
        }
        ctx.restoreGState()
        ctx.setStrokeColor(Style.line)
        ctx.setLineWidth(0.8)
        ctx.stroke(drawn)
        cursor = Page.height - drawn.minY + 10

        // 범례
        var x = Page.margin
        for c in VerdictColor.allCases {
            ctx.setFillColor(Style.color(c))
            ctx.fillEllipse(in: rect(x: x, top: cursor + 2, width: 7, height: 7))
            let t = Style.text(c.meaning, Style.font(8), Style.secondary)
            drawLine(t, x: x + 10, baselineFromTop: cursor + 8.5)
            x += lineWidth(t) + 22
        }
        space(18)
    }

    /// 영업장 외곽과 표시 위치를 감싸는 영역(여백 12%). 외곽이 없으면 쪽 전체.
    func focusRect(plan: PlanModel, page: Rect) -> Rect {
        var pts = plan.boundary?.vertices ?? []
        for s in report.sections { pts += s.verdict.location.markers }
        guard pts.count >= 2 else { return page }
        let b = Rect(points: pts)
        let pad = max(b.width, b.height) * 0.12 + 10
        let r = Rect(minX: max(page.minX, b.minX - pad), minY: max(page.minY, b.minY - pad),
                     maxX: min(page.maxX, b.maxX + pad), maxY: min(page.maxY, b.maxY + pad))
        return r.width > 20 && r.height > 20 ? r : page
    }

    // MARK: 판정 절

    func section(_ s: ReportVerdictSection) {
        let v = s.verdict
        if remaining < 260 { newPage() } else { space(12) }
        let top = cursor
        numberBadge(s.number, color: Style.color(v.color), center: CGPoint(x: Page.margin + 11, y: Page.height - top - 11), radius: 11)
        drawLine(Style.text(v.title, Style.font(15, "Bold")), x: Page.margin + 30, baselineFromTop: top + 15)
        drawLine(Style.text(v.target, Style.font(9.5), Style.secondary), x: Page.margin + 30, baselineFromTop: top + 30)
        var x = Page.margin + 30
        x += tag(v.color.meaning, color: Style.color(v.color), x: x, top: top + 37) + 5
        tag(v.badge.displayName, color: Style.secondary, x: x, top: top + 37)
        cursor = top + 58
        if !v.summary.isEmpty { flow(Style.text(v.summary, Style.font(10.5, "SemiBold")), after: 8) }

        narrative(s.narrative)

        heading("판정 상세", size: 11, before: 4)
        for sec in s.explanation.sections where sec.number != 4 {
            let body = sec.lines.joined(separator: "\n")
            let t = NSMutableAttributedString(attributedString: Style.text("\(sec.number). \(sec.title)\n", Style.font(9, "SemiBold"), Style.secondary))
            t.append(Style.text(body, Style.font(9.5)))
            block(t, after: 5)
        }

        heading("확인·보완 방향", size: 11, before: 4)
        narrative(s.nextSteps, bullets: true)

        heading("법적 근거(조문 원문)", size: 11, before: 4)
        for c in s.explanation.citations {
            block(Style.text("\(c.citation) · \(c.layer.rawValue) · 시행 \(LawDate.pretty(c.effectiveDate))", Style.font(9, "SemiBold")), after: 2)
            flow(Style.text(Self.readable(c.text), Style.font(8.5), Style.secondary, lineSpacing: 2.5), indent: 8, after: 6)
        }
        if !s.related.isEmpty {
            heading("관련 조문(조문 검색 결과 · 원문)", size: 11, before: 4)
            for r in s.related {
                block(Style.text(r.passage.citation, Style.font(9, "SemiBold")), after: 2)
                flow(Style.text(r.passage.text, Style.font(8.5), Style.secondary, lineSpacing: 2.5), indent: 8, after: 6)
            }
        }
        if !v.lawFlags.isEmpty {
            heading("법령 상태", size: 11, before: 4)
            flow(Style.text(v.lawFlags.map { "• \($0.text)" }.joined(separator: "\n"), Style.font(9.5)), after: 6)
        }
    }

    /// 표 칸 너비로 끊긴 원문 줄(짧은 줄이 이어지는 경우)은 이어 붙여 읽기 좋게 한다. 글자는 그대로다.
    static func readable(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        guard lines.count > 4, (lines.map(\.count).max() ?? 0) < 40 else { return text }
        return LawText.joinWrapped(lines)
    }

    // MARK: 마무리

    func closing() {
        if remaining < 220 { newPage() } else { space(16) }
        heading("법령·작성 정보", size: 13, before: 0)
        flow(Style.text(report.lawStatus.map { "• \($0)" }.joined(separator: "\n"), Style.font(9.5), Style.ink, lineSpacing: 3), after: 8)
        var ai = ["• 판정·색·수치·조문 원문: 규칙 엔진과 그날 수집한 법령 원문(생성형 AI 미관여)"]
        if let model = report.model {
            ai.append("• 서술: \(model) — 사실·조문 대조를 통과한 AI 문장 \(report.aiSentenceCount)개를 싣고 \(report.droppedSentenceCount)개를 뺐다")
        } else {
            ai.append("• 서술: 생성형 AI 를 쓰지 않았거나 응답을 받지 못해 규칙 엔진 문장으로 작성했다")
        }
        ai.append("• 조문 검색: 그날 수집한 법령 전문 구절에서 판정마다 관련 구절을 찾아 AI 입력과 부록에 썼다")
        flow(Style.text(ai.joined(separator: "\n"), Style.font(9.5), Style.ink, lineSpacing: 3), after: 8)
        if !report.notes.isEmpty {
            heading("도면 해석 메모", size: 11, before: 4)
            flow(Style.text(report.notes.map { "• \($0)" }.joined(separator: "\n"), Style.font(9), Style.secondary, lineSpacing: 3), after: 8)
        }
        space(6)
        block(Style.text("\(InspectionReport.disclaimer) \(InspectionReport.aiNotice)", Style.font(9, "SemiBold"), Style.secondary, lineSpacing: 3))
    }
}
