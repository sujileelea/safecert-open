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

    /// 치수 문자 2개 이상 일치하고, 일치가 어긋남의 3배 이상(실도면 치수선 짝짓기 오차 허용).
    public var isCrossValidated: Bool { crossChecks >= 2 && crossChecks >= conflicts * 3 }

    /// 판정 경계 허용 폭(m). 벡터 좌표는 정확하므로 CAD 작도 오차 수준(0.5pt)만 둔다.
    public var resolutionMeters: Double { metersPerPoint * 0.5 }
}

public enum ScaleEstimator {
    static let standardScales = [10, 20, 25, 30, 50, 60, 100, 120, 150, 200, 250, 300, 400, 500, 600, 1000, 1200, 1500, 2000]

    public static func estimate(_ page: VectorPage) -> ScaleEstimate? {
        let declared = declaredRatios(page.texts)
        let candidates = dimensionCandidates(page)
        func matches(_ r: Int, _ n: Int) -> Bool { abs(Double(r) - Double(n)) / Double(n) <= 0.02 }

        // 치수가 가장 많이 가리키는 축척(±2% 묶음). 용지 맞춤 인쇄면 표기와 다른 비표준 값이 나온다.
        let consensus = consensusRatio(candidates)

        if let n = declared.first {
            // 치수 문자마다: 짝 선 중 하나라도 표기 축척과 맞으면 일치, 짝은 있는데 하나도 안 맞으면 어긋남.
            let agree = candidates.filter { $0.ratios.contains { matches($0, n) } }
            let disagree = candidates.filter { !$0.ratios.contains { matches($0, n) } }
            // 치수 합의가 표기와 다르고 훨씬 강하면 → 실제 출력 축척은 치수 쪽(축소·확대 인쇄)
            if let c = consensus, !matches(c.ratio, n), c.support >= 3, c.support >= agree.count * 2 {
                return ScaleEstimate(
                    ratio: c.ratio, source: .dimensions, crossChecks: c.support, conflicts: candidates.count - c.support,
                    evidence: ["도면 표기 1:\(n) 과 다름 — 치수 \(c.support)개가 1:\(c.ratio) 을 가리킨다(용지 맞춤 축소·확대 인쇄로 보임)"]
                        + c.texts.prefix(5).map { "치수 \($0)mm ↔ 1:\(c.ratio)" }
                )
            }
            var evidence = ["도면 표기 1:\(n)"]
            evidence += agree.prefix(5).map { "치수 \($0.text)mm ↔ 치수선 길이 일치" }
            evidence += disagree.prefix(5).map { "치수 \($0.text)mm ↔ 짝 치수선과 어긋남" }
            return ScaleEstimate(ratio: n, source: .titleBlock, crossChecks: agree.count, conflicts: disagree.count, evidence: evidence)
        }

        // 표기가 없으면 치수에서 가장 많이 지지받는 표준 축척
        let snapped = candidates.compactMap { item -> (Int, String)? in
            for r in item.ratios {
                if let s = standardScales.first(where: { matches(r, $0) }) { return (s, item.text) }
            }
            return nil
        }
        let counts = Dictionary(grouping: snapped, by: \.0)
        // 지지 수가 같으면 작은 축척 번호를 고른다(사전 순회 순서에 따른 비결정성 제거).
        guard let (best, items) = counts.max(by: { ($0.value.count, -$0.key) < ($1.value.count, -$1.key) }), items.count >= 2 else { return nil }
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

    /// 치수 문자들이 가장 많이 지지하는 축척: 각 문자의 후보 중 ±2% 안에 드는 문자 수가 최대인 값(동률이면 작은 값).
    static func consensusRatio(_ candidates: [(text: String, ratios: [Int])]) -> (ratio: Int, support: Int, texts: [String])? {
        let all = Set(candidates.flatMap(\.ratios)).sorted()
        var best: (Int, Int, [String])?
        for r in all {
            let supporters = candidates.filter { $0.ratios.contains { abs(Double($0 - r)) / Double(r) <= 0.02 } }
            if supporters.count > (best?.1 ?? 0) {
                // 지지 문자들의 해당 후보 중앙값으로 정리
                let values = supporters.compactMap { c in c.ratios.min { abs($0 - r) < abs($1 - r) } }.sorted()
                best = (values[values.count / 2], supporters.count, supporters.map(\.text))
            }
        }
        return best.map { (ratio: $0.0, support: $0.1, texts: $0.2) }
    }

    /// 숫자만 있는 치수 문자 + 짝이 되는 치수선 후보들 → 문자별 함의 축척 후보.
    /// 짝 = 가는 선 중 글자 방향과 나란하고(없으면 방향 무관), 글자 중심이 선의 가운데 60% 구간에 수직으로 떨어지며,
    /// 글자 높이의 3배(최소 20pt) 안에 있는 선.
    static func dimensionCandidates(_ page: VectorPage) -> [(text: String, ratios: [Int])] {
        let stroked = page.strokes.filter { $0.isStroked || $0.isFilled }
        let wallClass = PlanInterpreter.wallWidthClass(stroked)
        let thin = stroked.filter { $0.lineWidth < max(0.2, wallClass * 0.6) }.flatMap(\.segments).filter { $0.length > 8 }
        var out: [(String, [Int])] = []
        for t in page.texts {
            let digits = t.text.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: " ", with: "")
            guard !digits.isEmpty, digits.allSatisfy(\.isNumber), let mm = Double(digits), mm >= 300, mm <= 200_000 else { continue }
            let c = t.center
            let thickness = min(t.bounds.height, t.bounds.width)
            let reach = max(20, thickness * 3)
            let textVertical = t.isVertical || t.bounds.height > t.bounds.width * 1.5
            let paired = thin.filter { seg in
                let ab = seg.b - seg.a
                let len2 = ab.dot(ab)
                let u = (c - seg.a).dot(ab) / len2
                guard u >= 0.2, u <= 0.8 else { return false }
                return seg.distance(to: c) <= reach
            }
            let aligned = paired.filter { seg in
                let vertical = abs(seg.b.y - seg.a.y) > abs(seg.b.x - seg.a.x)
                return vertical == textVertical
            }
            let use = aligned.isEmpty ? paired : aligned
            let ratios = use.map { mm / ($0.length * 25.4 / 72) }.filter { $0 >= 5 && $0 <= 5000 }.map { Int($0.rounded()) }
            if !ratios.isEmpty { out.append((t.text, ratios)) }
        }
        return out
    }
}
