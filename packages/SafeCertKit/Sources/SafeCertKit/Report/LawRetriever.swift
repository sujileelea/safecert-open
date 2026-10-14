import Foundation

/// 검색된 구절과 점수.
public struct RetrievedPassage: Hashable, Codable, Sendable {
    public var passage: LawPassage
    public var score: Double
}

/// 조문 검색(RAG 의 검색 단계) — 한글 두 글자 단위 BM25. 기기 안에서 결정적으로 돈다.
/// 임베딩 모델 없이도 법령 용어(「비상구」「구획된 실」「가로」)가 그대로 맞물리므로 파일럿 규모(구절 수백 개)에 충분하다.
public struct LawRetriever: Sendable {
    let passages: [LawPassage]
    let termFrequencies: [[String: Int]]
    let lengths: [Int]
    let averageLength: Double
    let documentFrequency: [String: Int]

    static let k1 = 1.2
    static let b = 0.75

    public init(passages: [LawPassage]) {
        self.passages = passages
        var tfs: [[String: Int]] = []
        var df: [String: Int] = [:]
        var lengths: [Int] = []
        for p in passages {
            let tokens = Self.tokens("\(p.label) \(p.text)")
            var tf: [String: Int] = [:]
            for t in tokens { tf[t, default: 0] += 1 }
            for t in tf.keys { df[t, default: 0] += 1 }
            tfs.append(tf)
            lengths.append(tokens.count)
        }
        termFrequencies = tfs
        documentFrequency = df
        self.lengths = lengths
        averageLength = lengths.isEmpty ? 1 : Double(lengths.reduce(0, +)) / Double(lengths.count)
    }

    /// 점수 높은 순(같으면 ID 순). `excluding` 은 이미 인용한 원문과 겹치는 구절을 빼는 데 쓴다.
    public func search(_ query: String, limit: Int = 3, excluding: [String] = []) -> [RetrievedPassage] {
        // 합산 순서를 고정해야 점수가 비트 단위로 같다(Set 순회 순서는 인스턴스마다 다르다).
        let terms = Set(Self.tokens(query)).sorted()
        guard !terms.isEmpty else { return [] }
        let n = Double(passages.count)
        let excluded = excluding.map { Set(Self.tokens($0)) }
        var scored: [RetrievedPassage] = []
        for (i, p) in passages.enumerated() {
            var score = 0.0
            let tf = termFrequencies[i]
            let norm = Self.k1 * (1 - Self.b + Self.b * Double(lengths[i]) / averageLength)
            for t in terms {
                guard let f = tf[t] else { continue }
                let d = Double(documentFrequency[t] ?? 0)
                let idf = log(1 + (n - d + 0.5) / (d + 0.5))
                score += idf * Double(f) * (Self.k1 + 1) / (Double(f) + norm)
            }
            guard score > 0 else { continue }
            let own = Set(tf.keys)
            if excluded.contains(where: { Self.containment(own, in: $0) > 0.7 }) { continue }
            scored.append(RetrievedPassage(passage: p, score: score))
        }
        return Array(scored.sorted { ($0.score, $1.passage.id) > ($1.score, $0.passage.id) }.prefix(limit))
    }

    /// a 의 토큰 중 b 에도 있는 비율.
    static func containment(_ a: Set<String>, in b: Set<String>) -> Double {
        guard !a.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(a.count)
    }

    /// 한글 연속 구간은 두 글자씩(한 글자 구간은 그 글자), 영문·숫자는 단어째.
    static func tokens(_ s: String) -> [String] {
        var out: [String] = []
        var hangul: [Character] = []
        var word = ""
        func flushHangul() {
            if hangul.count == 1 {
                out.append(String(hangul))
            } else if hangul.count > 1 {
                for i in 0..<(hangul.count - 1) { out.append(String(hangul[i...i + 1])) }
            }
            hangul = []
        }
        func flushWord() {
            if !word.isEmpty { out.append(word.lowercased()) }
            word = ""
        }
        for c in s {
            if LawText.isHangul(c) {
                flushWord()
                hangul.append(c)
            } else if c.isLetter || c.isNumber {
                flushHangul()
                word.append(c)
            } else {
                flushHangul()
                flushWord()
            }
        }
        flushHangul()
        flushWord()
        return out
    }
}
