import CoreGraphics
import Foundation
import PDFKit

/// 벡터 PDF 한 페이지에서 읽은 기하 프리미티브와 글자.
/// 좌표는 페이지 좌상단 원점, PDF 포인트 단위.
public struct VectorPage: Sendable {
    public var index: Int
    public var width: Double
    public var height: Double
    public var strokes: [Stroke]
    public var texts: [TextRun]

    public var segmentCount: Int { strokes.reduce(0) { $0 + $1.segments.count } }
}

/// 한 번의 페인팅 연산(S·f·B 등)으로 그려진 경로.
public struct Stroke: Sendable {
    public var segments: [Segment]
    /// 하위 경로 안에서 연속된 곡선 묶음(원호 판정 단위).
    public var curveRuns: [[Cubic]]
    /// 닫힌 하위 경로 중 직선으로만 된 것.
    public var closedPolygons: [Polygon]
    public var lineWidth: Double
    public var isStroked: Bool
    public var isFilled: Bool
}

public struct TextRun: Hashable, Codable, Sendable {
    public var text: String
    public var bounds: Rect
    public var isVertical: Bool

    public init(text: String, bounds: Rect, isVertical: Bool = false) {
        self.text = text
        self.bounds = bounds
        self.isVertical = isVertical
    }

    public var center: Point { bounds.center }
}

public enum VectorPDFError: Error, Equatable {
    case unreadable
    case pageOutOfRange
}

public enum VectorPDF {
    public static func pageCount(_ data: Data) -> Int {
        guard let provider = CGDataProvider(data: data as CFData), let doc = CGPDFDocument(provider) else { return 0 }
        return doc.numberOfPages
    }

    /// PDF 데이터의 한 페이지(0부터)를 해석한다.
    public static func read(_ data: Data, pageIndex: Int = 0) throws -> VectorPage {
        guard let provider = CGDataProvider(data: data as CFData), let doc = CGPDFDocument(provider) else {
            throw VectorPDFError.unreadable
        }
        guard pageIndex >= 0, pageIndex < doc.numberOfPages, let page = doc.page(at: pageIndex + 1) else {
            throw VectorPDFError.pageOutOfRange
        }
        let box = page.getBoxRect(.mediaBox)
        let strokes = PathScanner.scan(page: page, mediaBox: box)
        let texts = TextExtractor.extract(data: data, pageIndex: pageIndex, mediaBox: box)
        return VectorPage(
            index: pageIndex,
            width: Double(box.width),
            height: Double(box.height),
            strokes: strokes,
            texts: texts
        )
    }
}

// MARK: - 경로 스캐너 (CGPDFScanner)

private final class ScanState {
    var table: CGPDFOperatorTableRef?
    var mediaBox: CGRect
    var ctm: CGAffineTransform = .identity
    var lineWidth: CGFloat = 1
    var stack: [(CGAffineTransform, CGFloat)] = []
    var depth = 0

    // 현재 경로(사용자 좌표계 → 장치 좌표계로 즉시 변환해 보관)
    var current: Point?
    var subpathStart: Point?
    var subpathPoints: [Point] = []
    var subpathOnlyLines = true
    var segments: [Segment] = []
    var curveRuns: [[Cubic]] = []
    var currentRun: [Cubic] = []
    var closed: [Polygon] = []

    var output: [Stroke] = []

    init(mediaBox: CGRect) {
        self.mediaBox = mediaBox
    }

    func toPage(_ x: CGFloat, _ y: CGFloat) -> Point {
        let p = CGPoint(x: x, y: y).applying(ctm)
        return Point(Double(p.x - mediaBox.minX), Double(mediaBox.maxY - p.y))
    }

    var deviceLineWidth: Double {
        let scale = sqrt(abs(ctm.a * ctm.d - ctm.b * ctm.c))
        return Double(lineWidth * (scale > 0 ? scale : 1))
    }

    func flushRun() {
        if !currentRun.isEmpty {
            curveRuns.append(currentRun)
            currentRun = []
        }
    }

    func moveTo(_ p: Point) {
        flushRun()
        current = p
        subpathStart = p
        subpathPoints = [p]
        subpathOnlyLines = true
    }

    func lineTo(_ p: Point) {
        flushRun()
        if let c = current { segments.append(Segment(c, p)) }
        current = p
        subpathPoints.append(p)
    }

    func curveTo(_ c1: Point, _ c2: Point, _ p: Point) {
        guard let c = current else { return }
        currentRun.append(Cubic(c, c1, c2, p))
        current = p
        subpathOnlyLines = false
        subpathPoints.append(p)
    }

    func closePath() {
        flushRun()
        if let c = current, let s = subpathStart {
            if c.distance(to: s) > 1e-6 { segments.append(Segment(c, s)) }
            if subpathOnlyLines, subpathPoints.count >= 3 { closed.append(Polygon(subpathPoints)) }
            current = s
        }
    }

    func paint(stroked: Bool, filled: Bool) {
        flushRun()
        if !segments.isEmpty || !curveRuns.isEmpty {
            output.append(Stroke(
                segments: segments,
                curveRuns: curveRuns,
                closedPolygons: closed,
                lineWidth: deviceLineWidth,
                isStroked: stroked,
                isFilled: filled
            ))
        }
        segments = []
        curveRuns = []
        closed = []
        current = nil
        subpathStart = nil
        subpathPoints = []
    }
}

// C 콜백은 문맥을 캡처할 수 없으므로 보조 함수는 파일 범위에 둔다.
private func state(_ info: UnsafeMutableRawPointer?) -> ScanState {
    Unmanaged<ScanState>.fromOpaque(info!).takeUnretainedValue()
}

private func pop(_ s: CGPDFScannerRef, _ n: Int) -> [CGFloat]? {
    var values = [CGFloat](repeating: 0, count: n)
    for i in stride(from: n - 1, through: 0, by: -1) {
        var v: CGPDFReal = 0
        guard CGPDFScannerPopNumber(s, &v) else { return nil }
        values[i] = v
    }
    return values
}

private enum PathScanner {
    static func scan(page: CGPDFPage, mediaBox: CGRect) -> [Stroke] {
        guard let table = CGPDFOperatorTableCreate() else { return [] }
        register(table)
        let state = ScanState(mediaBox: mediaBox)
        state.table = table
        let info = Unmanaged.passUnretained(state).toOpaque()
        let cs = CGPDFContentStreamCreateWithPage(page)
        let scanner = CGPDFScannerCreate(cs, table, info)
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(cs)
        CGPDFOperatorTableRelease(table)
        return state.output
    }

    static func register(_ t: CGPDFOperatorTableRef) {
        CGPDFOperatorTableSetCallback(t, "q") { _, info in
            let st = state(info)
            st.stack.append((st.ctm, st.lineWidth))
        }
        CGPDFOperatorTableSetCallback(t, "Q") { _, info in
            let st = state(info)
            if let (m, w) = st.stack.popLast() {
                st.ctm = m
                st.lineWidth = w
            }
        }
        CGPDFOperatorTableSetCallback(t, "cm") { s, info in
            guard let v = pop(s, 6) else { return }
            let st = state(info)
            st.ctm = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5]).concatenating(st.ctm)
        }
        CGPDFOperatorTableSetCallback(t, "w") { s, info in
            guard let v = pop(s, 1) else { return }
            state(info).lineWidth = v[0]
        }
        CGPDFOperatorTableSetCallback(t, "m") { s, info in
            guard let v = pop(s, 2) else { return }
            let st = state(info)
            st.moveTo(st.toPage(v[0], v[1]))
        }
        CGPDFOperatorTableSetCallback(t, "l") { s, info in
            guard let v = pop(s, 2) else { return }
            let st = state(info)
            st.lineTo(st.toPage(v[0], v[1]))
        }
        CGPDFOperatorTableSetCallback(t, "c") { s, info in
            guard let v = pop(s, 6) else { return }
            let st = state(info)
            st.curveTo(st.toPage(v[0], v[1]), st.toPage(v[2], v[3]), st.toPage(v[4], v[5]))
        }
        CGPDFOperatorTableSetCallback(t, "v") { s, info in
            guard let v = pop(s, 4) else { return }
            let st = state(info)
            guard let c = st.current else { return }
            st.curveTo(c, st.toPage(v[0], v[1]), st.toPage(v[2], v[3]))
        }
        CGPDFOperatorTableSetCallback(t, "y") { s, info in
            guard let v = pop(s, 4) else { return }
            let st = state(info)
            let end = st.toPage(v[2], v[3])
            st.curveTo(st.toPage(v[0], v[1]), end, end)
        }
        CGPDFOperatorTableSetCallback(t, "h") { _, info in
            state(info).closePath()
        }
        CGPDFOperatorTableSetCallback(t, "re") { s, info in
            guard let v = pop(s, 4) else { return }
            let st = state(info)
            let (x, y, w, h) = (v[0], v[1], v[2], v[3])
            st.moveTo(st.toPage(x, y))
            st.lineTo(st.toPage(x + w, y))
            st.lineTo(st.toPage(x + w, y + h))
            st.lineTo(st.toPage(x, y + h))
            st.closePath()
        }
        CGPDFOperatorTableSetCallback(t, "S") { _, info in state(info).paint(stroked: true, filled: false) }
        CGPDFOperatorTableSetCallback(t, "s") { _, info in
            let st = state(info)
            st.closePath()
            st.paint(stroked: true, filled: false)
        }
        for op in ["f", "F", "f*"] {
            CGPDFOperatorTableSetCallback(t, op) { _, info in state(info).paint(stroked: false, filled: true) }
        }
        for op in ["B", "B*"] {
            CGPDFOperatorTableSetCallback(t, op) { _, info in state(info).paint(stroked: true, filled: true) }
        }
        for op in ["b", "b*"] {
            CGPDFOperatorTableSetCallback(t, op) { _, info in
                let st = state(info)
                st.closePath()
                st.paint(stroked: true, filled: true)
            }
        }
        CGPDFOperatorTableSetCallback(t, "n") { _, info in
            // 클리핑 경로 등 그리지 않는 경로는 버린다.
            let st = state(info)
            st.flushRun()
            st.segments = []
            st.curveRuns = []
            st.closed = []
            st.current = nil
        }
        CGPDFOperatorTableSetCallback(t, "Do") { s, info in
            drawXObject(s, state(info))
        }
    }
}

/// Form XObject(CAD 출력 PDF 에 흔한 블록 참조)를 재귀적으로 스캔한다.
private func drawXObject(_ s: CGPDFScannerRef, _ st: ScanState) {
    var namePtr: UnsafePointer<CChar>?
    guard CGPDFScannerPopName(s, &namePtr), let name = namePtr, st.depth < 12, let table = st.table else { return }
    let cs = CGPDFScannerGetContentStream(s)
    guard let obj = CGPDFContentStreamGetResource(cs, "XObject", name) else { return }
    var stream: CGPDFStreamRef?
    guard CGPDFObjectGetValue(obj, .stream, &stream), let stream, let dict = CGPDFStreamGetDictionary(stream) else { return }
    var subtype: UnsafePointer<CChar>?
    guard CGPDFDictionaryGetName(dict, "Subtype", &subtype), let subtype, String(cString: subtype) == "Form" else { return }

    var matrix = CGAffineTransform.identity
    var arr: CGPDFArrayRef?
    if CGPDFDictionaryGetArray(dict, "Matrix", &arr), let arr, CGPDFArrayGetCount(arr) == 6 {
        var m = [CGFloat](repeating: 0, count: 6)
        for i in 0..<6 {
            var v: CGPDFReal = 0
            CGPDFArrayGetNumber(arr, i, &v)
            m[i] = v
        }
        matrix = CGAffineTransform(a: m[0], b: m[1], c: m[2], d: m[3], tx: m[4], ty: m[5])
    }
    var resources: CGPDFDictionaryRef?
    _ = CGPDFDictionaryGetDictionary(dict, "Resources", &resources)

    st.stack.append((st.ctm, st.lineWidth))
    st.ctm = matrix.concatenating(st.ctm)
    st.depth += 1
    let formCS = CGPDFContentStreamCreateWithStream(stream, resources ?? dict, cs)
    let info = Unmanaged.passUnretained(st).toOpaque()
    let scanner = CGPDFScannerCreate(formCS, table, info)
    CGPDFScannerScan(scanner)
    CGPDFScannerRelease(scanner)
    CGPDFContentStreamRelease(formCS)
    st.depth -= 1
    if let (m, w) = st.stack.popLast() {
        st.ctm = m
        st.lineWidth = w
    }
}

// MARK: - 글자 추출 (PDFKit)

enum TextExtractor {
    /// PDFKit 줄 단위 선택으로 글자 묶음과 위치를 얻는다.
    /// (글자 단위 좌표 색인은 PDFKit 이 끼워 넣는 줄바꿈만큼 어긋나므로 쓰지 않는다.)
    static func extract(data: Data, pageIndex: Int, mediaBox: CGRect) -> [TextRun] {
        guard let doc = PDFDocument(data: data), let page = doc.page(at: pageIndex) else { return [] }
        let full = page.bounds(for: .mediaBox)
        guard let selection = page.selection(for: full) else { return [] }
        var runs: [TextRun] = []
        for line in selection.selectionsByLine() {
            guard let raw = line.string else { continue }
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let r = line.bounds(for: page)
            let rect = Rect(
                minX: Double(r.minX - mediaBox.minX),
                minY: Double(mediaBox.maxY - r.maxY),
                maxX: Double(r.maxX - mediaBox.minX),
                maxY: Double(mediaBox.maxY - r.minY)
            )
            let vertical = text.count > 1 && rect.height > rect.width * 1.5
            runs.append(TextRun(text: text, bounds: rect, isVertical: vertical))
        }
        return runs
    }
}
