import Foundation

/// 판정식이 쓰는 기준 묶음.
public enum CriterionKey: String, Codable, Sendable, CaseIterable {
    /// 비상구 설치 의무와 예외(시행령 별표 1의2 제2호).
    case exitRequired
    /// 비상구 설치 위치 — 이격 비율(시행규칙 별표 2 제2호가목1).
    case exitLocation
    /// 비상구등 규격 — 최소 가로·세로(시행규칙 별표 2 제2호가목2).
    case exitSize
    /// 기존 다중이용업소 비상구 설치 불가 경우(소방청 고시).
    case existingExemption

    public var clauseKey: ClauseKey {
        switch self {
        case .exitRequired: .decreeExitRequired
        case .exitLocation: .ruleExitLocation
        case .exitSize: .ruleExitSize
        case .existingExemption: .noticeExistingGeneral
        }
    }

    public var displayName: String {
        switch self {
        case .exitRequired: "비상구 설치 의무·예외"
        case .exitLocation: "비상구 이격 비율"
        case .exitSize: "비상구등 최소 규격"
        case .existingExemption: "기존 업소 설치 불가 기준"
        }
    }
}

public enum CriterionUnit: String, Codable, Sendable {
    case ratio = "비율"
    case centimeter = "cm"
    case meter = "m"
    case squareMeter = "㎡"
    case date = "날짜"
}

public struct CriterionValue: Hashable, Codable, Sendable {
    public var number: Double
    public var unit: CriterionUnit
    /// 원문에서 읽은 글자 그대로(공백 제거). 검증 ② 원문 근거의 대상.
    public var literal: String

    public init(_ number: Double, _ unit: CriterionUnit, literal: String) {
        self.number = number
        self.unit = unit
        self.literal = literal
    }

    public var display: String {
        switch unit {
        case .ratio: literal
        case .date: literal
        default: "\(number.formatted(.number.precision(.fractionLength(0...2))))\(unit.rawValue)"
        }
    }
}

/// 정규화된 기준. 값 이름 → 값.
public struct Criterion: Hashable, Codable, Sendable {
    public var key: CriterionKey
    public var values: [String: CriterionValue]

    public subscript(_ name: String) -> CriterionValue? { values[name] }

    /// 판정식이 요구하는 값 이름(검증 ① 형식).
    public static func requiredValues(_ key: CriterionKey) -> [String: CriterionUnit] {
        switch key {
        case .exitRequired: ["exemptionA.ratio": .ratio, "exemptionB.maxArea": .squareMeter, "exemptionB.maxDistance": .meter]
        case .exitLocation: ["ratio": .ratio]
        case .exitSize: ["minWidth": .centimeter, "minHeight": .centimeter]
        case .existingExemption: ["cutoffDate": .date, "maxArea": .squareMeter]
        }
    }
}

public struct NormalizeError: Error, Hashable, Codable, Sendable {
    public var reason: String
}

// MARK: - 1차 파서: 문장 패턴

public enum PrimaryNormalizer {
    public static func normalize(_ key: CriterionKey, clause: LawClause) -> Result<Criterion, NormalizeError> {
        let t = LawText.compact(clause.text)
        var values: [String: CriterionValue] = [:]
        func fail(_ what: String) -> Result<Criterion, NormalizeError> { .failure(NormalizeError(reason: "1차 파서: \(what) 문장을 찾지 못함")) }

        switch key {
        case .exitLocation:
            guard let m = match(#"가장긴길이의(\d+)분의(\d+)이상"#, t), let d = Double(m[1]), let n = Double(m[2]), d > 0 else { return fail("이격 비율") }
            values["ratio"] = CriterionValue(n / d, .ratio, literal: "\(m[1])분의\(m[2])")
        case .exitSize:
            guard let m = match(#"규격:?가로(\d+(?:\.\d+)?)센티미터이상,세로(\d+(?:\.\d+)?)센티미터이상"#, t),
                  let w = Double(m[1]), let h = Double(m[2]) else { return fail("가로·세로 규격") }
            values["minWidth"] = CriterionValue(w, .centimeter, literal: "\(m[1])센티미터")
            values["minHeight"] = CriterionValue(h, .centimeter, literal: "\(m[2])센티미터")
        case .exitRequired:
            guard let a = match(#"긴변길이의(\d+)분의(\d+)이상"#, t), let ad = Double(a[1]), let an = Double(a[2]), ad > 0 else { return fail("예외 가목 비율") }
            guard let b = match(#"바닥면적이(\d+(?:\.\d+)?)제곱미터이하"#, t), let area = Double(b[1]) else { return fail("예외 나목 면적") }
            guard let c = match(#"출입구까지의수평거리가(\d+(?:\.\d+)?)미터이하"#, t), let dist = Double(c[1]) else { return fail("예외 나목 거리") }
            values["exemptionA.ratio"] = CriterionValue(an / ad, .ratio, literal: "\(a[1])분의\(a[2])")
            values["exemptionB.maxArea"] = CriterionValue(area, .squareMeter, literal: "\(b[1])제곱미터")
            values["exemptionB.maxDistance"] = CriterionValue(dist, .meter, literal: "\(c[1])미터")
        case .existingExemption:
            guard let d = match(#"(\d{4})년(\d{1,2})월(\d{1,2})일이전에이미영업"#, t),
                  let y = Int(d[1]), let mo = Int(d[2]), let da = Int(d[3]) else { return fail("기존 업소 기준일") }
            guard let a = match(#"바닥면적합계가(\d+(?:\.\d+)?)제곱미터이하"#, t), let area = Double(a[1]) else { return fail("면적 기준") }
            values["cutoffDate"] = CriterionValue(Double(y * 10000 + mo * 100 + da), .date, literal: "\(d[1])년\(d[2])월\(d[3])일")
            values["maxArea"] = CriterionValue(area, .squareMeter, literal: "\(a[1])제곱미터")
        }
        return .success(Criterion(key: key, values: values))
    }

    static func match(_ pattern: String, _ s: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: s).map { String(s[$0]) } ?? "" }
    }
}

// MARK: - 2차 파서: 기준 단어 + 토큰 읽기

public enum SecondaryNormalizer {
    enum Token: Equatable {
        case number(String)
        case word(String)
    }

    public static func normalize(_ key: CriterionKey, clause: LawClause) -> Result<Criterion, NormalizeError> {
        let t = LawText.compact(clause.text)
        var values: [String: CriterionValue] = [:]
        func fail(_ what: String) -> Result<Criterion, NormalizeError> { .failure(NormalizeError(reason: "2차 파서: \(what) 값을 찾지 못함")) }

        switch key {
        case .exitLocation:
            guard let f = fraction(after: "가장긴길이", in: t) else { return fail("이격 비율") }
            values["ratio"] = f
        case .exitSize:
            let q = quantities(after: "규격", in: t, unit: "센티미터", count: 2)
            guard q.count == 2 else { return fail("가로·세로 규격") }
            values["minWidth"] = CriterionValue(q[0].0, .centimeter, literal: "\(q[0].1)센티미터")
            values["minHeight"] = CriterionValue(q[1].0, .centimeter, literal: "\(q[1].1)센티미터")
        case .exitRequired:
            guard let f = fraction(after: "긴변길이", in: t) else { return fail("예외 가목 비율") }
            guard let area = quantities(after: "바닥면적", in: t, unit: "제곱미터", count: 1).first else { return fail("예외 나목 면적") }
            guard let dist = quantities(after: "출입구까지의수평거리", in: t, unit: "미터", count: 1).first else { return fail("예외 나목 거리") }
            values["exemptionA.ratio"] = f
            values["exemptionB.maxArea"] = CriterionValue(area.0, .squareMeter, literal: "\(area.1)제곱미터")
            values["exemptionB.maxDistance"] = CriterionValue(dist.0, .meter, literal: "\(dist.1)미터")
        case .existingExemption:
            guard let date = date(after: "기존다중이용업소", in: t) else { return fail("기존 업소 기준일") }
            guard let area = quantities(after: "바닥면적합계", in: t, unit: "제곱미터", count: 1).first else { return fail("면적 기준") }
            values["cutoffDate"] = date
            values["maxArea"] = CriterionValue(area.0, .squareMeter, literal: "\(area.1)제곱미터")
        }
        return .success(Criterion(key: key, values: values))
    }

    /// 문자열을 숫자 토큰과 비숫자 토큰으로 나눈다.
    static func tokens(_ s: Substring) -> [Token] {
        var out: [Token] = []
        var num = ""
        var word = ""
        for ch in s {
            if ch.isASCII && (ch.isNumber || (ch == "." && !num.isEmpty)) {
                if !word.isEmpty { out.append(.word(word)); word = "" }
                num.append(ch)
            } else {
                if !num.isEmpty { out.append(.number(num)); num = "" }
                word.append(ch)
            }
        }
        if !num.isEmpty { out.append(.number(num)) }
        if !word.isEmpty { out.append(.word(word)) }
        return out
    }

    static func tail(after anchor: String, in t: String) -> Substring? {
        guard let r = t.range(of: anchor) else { return nil }
        return t[r.upperBound...]
    }

    /// 기준 단어 뒤 첫 「N분의M」.
    static func fraction(after anchor: String, in t: String) -> CriterionValue? {
        guard let tail = tail(after: anchor, in: t) else { return nil }
        let tk = tokens(tail.prefix(60))
        for i in 0..<max(0, tk.count - 2) {
            if case .number(let d) = tk[i], case .word(let w) = tk[i + 1], w.hasPrefix("분의"), case .number(let n) = tk[i + 2],
               let dv = Double(d), let nv = Double(n), dv > 0 {
                return CriterionValue(nv / dv, .ratio, literal: "\(d)분의\(n)")
            }
        }
        return nil
    }

    /// 기준 단어 뒤에서 단위가 붙은 수를 차례로 count 개.
    static func quantities(after anchor: String, in t: String, unit: String, count: Int) -> [(Double, String)] {
        guard let tail = tail(after: anchor, in: t) else { return [] }
        let tk = tokens(tail.prefix(120))
        var out: [(Double, String)] = []
        for i in 0..<max(0, tk.count - 1) where out.count < count {
            if case .number(let n) = tk[i], case .word(let w) = tk[i + 1], w.hasPrefix(unit), let v = Double(n) {
                // 「제곱미터」를 「미터」로 잘못 읽지 않도록 단위 앞부분이 정확히 일치해야 한다.
                if unit == "미터" && w.hasPrefix("제곱") { continue }
                out.append((v, n))
            }
        }
        return out
    }

    static func date(after anchor: String, in t: String) -> CriterionValue? {
        guard let tail = tail(after: anchor, in: t) else { return nil }
        let tk = tokens(tail.prefix(60))
        for i in 0..<max(0, tk.count - 5) {
            if case .number(let y) = tk[i], case .word(let w1) = tk[i + 1], w1.hasPrefix("년"),
               case .number(let m) = tk[i + 2], case .word(let w2) = tk[i + 3], w2.hasPrefix("월"),
               case .number(let d) = tk[i + 4], case .word(let w3) = tk[i + 5], w3.hasPrefix("일"),
               let yv = Int(y), let mv = Int(m), let dv = Int(d) {
                return CriterionValue(Double(yv * 10000 + mv * 100 + dv), .date, literal: "\(y)년\(m)월\(d)일")
            }
        }
        return nil
    }
}
