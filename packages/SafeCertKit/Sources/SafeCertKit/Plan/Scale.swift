import Foundation

/// 도면 축척 추정과 확인 상태(U-04). 확인 토글이 꺼져 있으면 거리·폭 규칙은 판정하지 않는다.
public struct ScaleEstimate: Hashable, Codable, Sendable {
    public enum Source: String, Codable, Sendable {
        case titleBlock
        case dimensions
        case user

        public var displayName: String {
            switch self {
            case .titleBlock: "도면 표기"
            case .dimensions: "치수 문자"
            case .user: "사용자 입력"
            }
        }
    }

    /// 1:N 의 N.
    public var ratio: Int
    public var source: Source
    /// 축척과 일치한 치수 문자 수.
    public var crossChecks: Int
    /// 축척과 어긋난 치수 문자 수.
    public var conflicts: Int
    public var evidence: [String]
    public var confirmed: Bool

    public init(ratio: Int, source: Source, crossChecks: Int = 0, conflicts: Int = 0, evidence: [String] = [], confirmed: Bool = false) {
        self.ratio = ratio
        self.source = source
        self.crossChecks = crossChecks
        self.conflicts = conflicts
        self.evidence = evidence
        self.confirmed = confirmed
    }

    /// PDF 1 포인트가 실제 몇 m 인가.
    public var metersPerPoint: Double { Double(ratio) * 0.0254 / 72 }

    public func meters(_ points: Double) -> Double { points * metersPerPoint }
    public func squareMeters(_ squarePoints: Double) -> Double { squarePoints * metersPerPoint * metersPerPoint }

    /// 치수 문자 2개 이상 일치, 어긋남 0.
    public var isCrossValidated: Bool { crossChecks >= 2 && conflicts == 0 }

    /// 한 포인트 오차가 만드는 실제 길이 오차(m) — 판정 경계 허용 폭의 근거.
    public var resolutionMeters: Double { metersPerPoint * 1.5 }
}

public enum ScaleEstimator {
    static let standardScales = [10, 20, 25, 30, 50, 60, 100, 120, 150, 200, 250, 300, 400, 500, 600, 1000, 1200, 1500, 2000]

    public static func estimate(_ page: VectorPage) -> ScaleEstimate? {
        let declared = declaredRatios(page.texts)
        let implied = dimensionImpliedRatios(page)

        if let n = declared.first {
            let agree = implied.filter { abs(Double($0.ratio) - Double(n)) / Double(n) <= 0.02 }
            let disagree = implied.filter { abs(Double($0.ratio) - Double(n)) / Double(n) > 0.02 }
            var evidence = ["도면 표기 1:\(n)"]
            evidence += agree.map { "치수 \($0.text)mm ↔ 선 길이 일치" }
            evidence += disagree.map { "치수 \($0.text)mm ↔ 1:\($0.ratio) 로 어긋남" }
            return ScaleEstimate(ratio: n, source: .titleBlock, crossChecks: agree.count, conflicts: disagree.count, evidence: evidence)
        }

        // 표기가 없으면 치수에서 가장 많이 지지받는 표준 축척
        let snapped = implied.compactMap { item -> (Int, String)? in
            guard let s = standardScales.min(by: { abs(Double($0 - item.ratio)) < abs(Double($1 - item.ratio)) }),
                  abs(Double(s - item.ratio)) / Double(s) <= 0.02 else { return nil }
            return (s, item.text)
        }
        let counts = Dictionary(grouping: snapped, by: \.0)
        guard let (best, items) = counts.max(by: { $0.value.count < $1.value.count }), items.count >= 2 else { return nil }
        return ScaleEstimate(
            ratio: best,
            source: .dimensions,
            crossChecks: items.count,
            conflicts: snapped.count - items.count,
            evidence: items.map { "치수 \($0.1)mm ↔ 1:\(best)" }
        )
    }

    /// "축척 1:100", "SCALE 1/50", "S=1:200" 등.
    static func declaredRatios(_ texts: [TextRun]) -> [Int] {
        let pattern = #"(?:축척|SCALE|S\s*=)\s*:?\s*1\s*[:/]\s*(\d{1,4})"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return texts.compactMap { t in
            let s = t.text
            guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
                  let r = Range(m.range(at: 1), in: s), let n = Int(s[r]), n > 0 else { return nil }
            return n
        }
    }

    /// 숫자만 있는 치수 문자 + 가까운 가는 선(가장 긴 것) → 함의된 축척.
    static func dimensionImpliedRatios(_ page: VectorPage) -> [(text: String, ratio: Int)] {
        let stroked = page.strokes.filter(\.isStroked)
        let maxWidth = stroked.map(\.lineWidth).max() ?? 0
        let thin = stroked.filter { $0.lineWidth < max(1.2, maxWidth * 0.45) }.flatMap(\.segments)
        var out: [(String, Int)] = []
        for t in page.texts {
            let digits = t.text.replacingOccurrences(of: ",", with: "")
            guard digits.allSatisfy(\.isNumber), let mm = Double(digits), mm >= 300, mm <= 200_000 else { continue }
            let reach = max(20, min(t.bounds.height, t.bounds.width) * 3)
            guard let seg = thin.filter({ $0.distance(to: t.center) <= reach && $0.length > 20 }).max(by: { $0.length < $1.length }) else { continue }
            let paperMM = seg.length * 25.4 / 72
            let n = mm / paperMM
            guard n >= 5, n <= 5000 else { continue }
            out.append((t.text, Int(n.rounded())))
        }
        return out
    }
}
