import CoreGraphics
import Foundation

/// 렌더링된 도면 페이지(불변 이미지).
public struct RenderedPage: @unchecked Sendable {
    public let image: CGImage
    /// 이미지 픽셀 / PDF 포인트.
    public let pixelsPerPoint: CGFloat
}

/// PDF 페이지를 비트맵으로 그린다(CoreGraphics). 좌표는 VectorPDF 와 같은 좌상단 원점.
public enum PageRenderer {
    public static func render(pdf: Data, pageIndex: Int, maxPixels: CGFloat = 4096) async -> RenderedPage? {
        guard let provider = CGDataProvider(data: pdf as CFData), let doc = CGPDFDocument(provider),
              let page = doc.page(at: pageIndex + 1) else { return nil }
        let box = page.getBoxRect(.mediaBox)
        let scale = min(3, maxPixels / max(box.width, box.height))
        let w = Int(box.width * scale), h = Int(box.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -box.minX, y: -box.minY)
        ctx.drawPDFPage(page)
        guard let image = ctx.makeImage() else { return nil }
        return RenderedPage(image: image, pixelsPerPoint: scale)
    }
}
