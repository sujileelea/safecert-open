import CoreGraphics
import Foundation
#if canImport(Vision)
import Vision
#endif

/// 글자를 외곽선(도형)으로 출력한 CAD PDF 의 글자를 Apple Vision 으로 읽는다.
/// 도면 글자는 90° 돌아간 경우가 많아 0°·90°·270° 세 방향으로 읽고 겹치는 결과를 합친다.
/// 결과 좌표는 VectorPDF 와 같은 페이지 좌상단 원점 포인트.
public enum OutlinedTextRecognizer {
    /// 큰 페이지는 타일로 나눠 읽는다(작은 도면 글자를 살리기 위한 해상도).
    static let pixelsPerPoint: CGFloat = 6
    static let tileSize = 2400
    static let tileOverlap = 240

    public static var isAvailable: Bool {
        #if canImport(Vision)
        return true
        #else
        return false
        #endif
    }

    public static func recognize(pdf: Data, pageIndex: Int) async -> [TextRun] {
        #if canImport(Vision)
        guard let page = render(pdf: pdf, pageIndex: pageIndex) else { return [] }
        var found: [(run: TextRun, confidence: Float)] = []
        for rotation in [0, 90, 270] {
            guard let rotated = rotate(page.image, degrees: rotation) else { continue }
            for tile in tiles(width: rotated.width, height: rotated.height) {
                guard let crop = rotated.cropping(to: tile) else { continue }
                for obs in recognizeTile(crop) {
                    // 타일 정규화 좌표(좌하단 원점) → 회전 이미지 픽셀(좌상단 원점)
                    let b = obs.box
                    let rx0 = tile.minX + b.minX * tile.width
                    let rx1 = tile.minX + b.maxX * tile.width
                    let ry0 = tile.minY + (1 - b.maxY) * tile.height
                    let ry1 = tile.minY + (1 - b.minY) * tile.height
                    let corners = [CGPoint(x: rx0, y: ry0), CGPoint(x: rx1, y: ry1)].map {
                        unrotate($0, degrees: rotation, width: CGFloat(page.image.width), height: CGFloat(page.image.height))
                    }
                    let r = Rect(points: corners.map { Point(Double($0.x / pixelsPerPoint), Double($0.y / pixelsPerPoint)) })
                    found.append((TextRun(text: obs.text, bounds: r, isVertical: rotation != 0), obs.confidence))
                }
            }
        }
        // 겹치는 결과는 신뢰도 높은 쪽만
        var accepted: [(run: TextRun, confidence: Float)] = []
        for f in found.sorted(by: { ($0.confidence, $0.run.text.count) > ($1.confidence, $1.run.text.count) }) {
            if accepted.contains(where: { overlap($0.run.bounds, f.run.bounds) > 0.5 }) { continue }
            accepted.append(f)
        }
        return accepted.map(\.run).sorted { ($0.bounds.minY, $0.bounds.minX) < ($1.bounds.minY, $1.bounds.minX) }
        #else
        return []
        #endif
    }

    // MARK: 내부

    struct Rendered {
        let image: CGImage
    }

    static func render(pdf: Data, pageIndex: Int) -> Rendered? {
        guard let provider = CGDataProvider(data: pdf as CFData), let doc = CGPDFDocument(provider),
              let page = doc.page(at: pageIndex + 1) else { return nil }
        let box = page.getBoxRect(.mediaBox)
        let w = Int(box.width * pixelsPerPoint), h = Int(box.height * pixelsPerPoint)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: pixelsPerPoint, y: pixelsPerPoint)
        ctx.translateBy(x: -box.minX, y: -box.minY)
        ctx.drawPDFPage(page)
        return ctx.makeImage().map(Rendered.init)
    }

    /// 시계 방향으로 degrees 만큼 돌린 이미지.
    static func rotate(_ image: CGImage, degrees: Int) -> CGImage? {
        guard degrees != 0 else { return image }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        guard let ctx = CGContext(data: nil, width: image.height, height: image.width, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        // CG 좌하단 좌표: 시계 90° = (x, y) → (y, W - x), 시계 270° = (x, y) → (H - y, x)
        let t = degrees == 90
            ? CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
            : CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        ctx.concatenate(t)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// 회전 이미지의 좌상단 원점 픽셀 → 원본 이미지의 좌상단 원점 픽셀.
    static func unrotate(_ p: CGPoint, degrees: Int, width w: CGFloat, height h: CGFloat) -> CGPoint {
        switch degrees {
        case 90:
            // 회전 이미지 크기 (h, w). 좌상단 (u, v) ↔ CG (u, w - v) = (y, W - x) → x = v, y = u (CG) → 좌상단 y = h - u
            return CGPoint(x: p.y, y: h - p.x)
        case 270:
            // CG (u, w - v) = (H - y, x) → x = w - v, y = h - u (CG) → 좌상단 y = u
            return CGPoint(x: w - p.y, y: p.x)
        default:
            return p
        }
    }

    static func tiles(width: Int, height: Int) -> [CGRect] {
        var out: [CGRect] = []
        let step = tileSize - tileOverlap
        var y = 0
        while y < height {
            var x = 0
            while x < width {
                out.append(CGRect(x: x, y: y, width: min(tileSize, width - x), height: min(tileSize, height - y)))
                if x + tileSize >= width { break }
                x += step
            }
            if y + tileSize >= height { break }
            y += step
        }
        return out
    }

    struct Observation {
        let text: String
        let box: CGRect
        let confidence: Float
    }

    static func recognizeTile(_ image: CGImage) -> [Observation] {
        #if canImport(Vision)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ko-KR", "en-US"]
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.004
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        return (request.results ?? []).compactMap { obs in
            guard let top = obs.topCandidates(1).first, top.confidence >= 0.4 else { return nil }
            let text = top.string.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : Observation(text: text, box: obs.boundingBox, confidence: top.confidence)
        }
        #else
        return []
        #endif
    }

    /// 작은 쪽 넓이 대비 겹친 넓이.
    static func overlap(_ a: Rect, _ b: Rect) -> Double {
        let w = min(a.maxX, b.maxX) - max(a.minX, b.minX)
        let h = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        guard w > 0, h > 0 else { return 0 }
        let small = min(a.width * a.height, b.width * b.height)
        return small > 0 ? (w * h) / small : 0
    }
}
