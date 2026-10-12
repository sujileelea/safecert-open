import CryptoKit
import Foundation

/// 출처 층(기능명세서 §1-1 기준 체계).
public enum SourceLayer: String, Codable, Sendable {
    case act = "법률"
    case decree = "시행령"
    case rule = "시행규칙"
    case notice = "소방청 고시"
}

/// 파일럿 규칙이 인용하는 조문 단위.
public enum ClauseKey: String, Codable, Sendable, CaseIterable {
    case actDuty = "act.art9"
    case decreeExitRequired = "decree.annex1-2.item2"
    case decreeDefinitions = "decree.annex1-2.notes"
    case ruleExitLocation = "rule.annex2.item2.ga1"
    case ruleExitSize = "rule.annex2.item2.ga2"
    case noticeExistingGeneral = "notice.31132"
    case noticeExistingSpecial = "notice.2034123"

    public var citation: String {
        switch self {
        case .actDuty: "다중이용업소법 제9조제1항·제2항"
        case .decreeExitRequired: "다중이용업소법 시행령 별표 1의2 제2호"
        case .decreeDefinitions: "다중이용업소법 시행령 별표 1의2 비고 2·3"
        case .ruleExitLocation: "다중이용업소법 시행규칙 별표 2 제2호가목1)"
        case .ruleExitSize: "다중이용업소법 시행규칙 별표 2 제2호가목2)"
        case .noticeExistingGeneral: "기존다중이용업소 건축물의 구조상 비상구를 설치할 수 없는 경우에 관한 고시"
        case .noticeExistingSpecial: "기존다중이용업소(옥내권총사격장·골프연습장·안마시술소) 비상구 설치 불가 기준 고시"
        }
    }

    public var layer: SourceLayer {
        switch self {
        case .actDuty: .act
        case .decreeExitRequired, .decreeDefinitions: .decree
        case .ruleExitLocation, .ruleExitSize: .rule
        case .noticeExistingGeneral, .noticeExistingSpecial: .notice
        }
    }

    var request: LawRequest {
        switch self {
        case .actDuty: .law(id: LawCatalog.actID)
        case .decreeExitRequired, .decreeDefinitions: .law(id: LawCatalog.decreeID)
        case .ruleExitLocation, .ruleExitSize: .law(id: LawCatalog.ruleID)
        case .noticeExistingGeneral: .adminRule(id: "31132")
        case .noticeExistingSpecial: .adminRule(id: "2034123")
        }
    }
}

/// 조문 한 단위의 그날 실측값.
public struct LawClause: Identifiable, Hashable, Codable, Sendable {
    public var key: ClauseKey
    public var lawName: String
    public var text: String
    public var effectiveDate: String
    /// 공포일(법령) 또는 발령일(고시).
    public var promulgationDate: String
    /// 공백을 무시한 원문 지문.
    public var fingerprint: String
    /// 숫자를 가린 원문 지문 — 숫자만 바뀌었는지, 문구가 바뀌었는지 가른다.
    public var wordingFingerprint: String
    /// 이 조문을 실제로 받아온 법령 기준일. 수집 실패로 이어 쓴 조문은 이전 날짜가 남는다.
    public var collectedOn: String?

    public var id: String { key.rawValue }
    public var citation: String { key.citation }
    public var layer: SourceLayer { key.layer }

    public init(key: ClauseKey, lawName: String, text: String, effectiveDate: String, promulgationDate: String) {
        self.key = key
        self.lawName = lawName
        self.text = text
        self.effectiveDate = effectiveDate
        self.promulgationDate = promulgationDate
        fingerprint = LawText.fingerprint(text)
        wordingFingerprint = LawText.wordingFingerprint(text)
    }
}

public enum LawCatalog {
    public static let actID = "010235"
    public static let decreeID = "010409"
    public static let ruleID = "010407"
    public static let lawFamilyQuery = "다중이용업소의 안전관리에 관한 특별법"
    public static let noticeQuery = "다중이용업소"

    /// 하루치 수집 요청 전체.
    public static let requests: [LawRequest] = [
        .law(id: actID), .law(id: decreeID), .law(id: ruleID),
        .adminRule(id: "31132"), .adminRule(id: "2034123"),
        .adminRuleSearch(query: noticeQuery),
        .effectiveLawSearch(query: lawFamilyQuery)
    ]
}

// MARK: - 조문 추출

public enum ClauseExtractor {
    public struct Failure: Hashable, Codable, Sendable {
        public var key: ClauseKey
        public var reason: String
    }

    public static func extract(
        laws: [String: LawDocument],
        notices: [String: AdminRuleDocument]
    ) -> (clauses: [LawClause], failures: [Failure]) {
        var out: [LawClause] = []
        var failures: [Failure] = []
        for key in ClauseKey.allCases {
            do {
                out.append(try extract(key, laws: laws, notices: notices))
            } catch let e as ExtractError {
                failures.append(Failure(key: key, reason: e.reason))
            } catch {
                failures.append(Failure(key: key, reason: "\(error)"))
            }
        }
        return (out, failures)
    }

    struct ExtractError: Error {
        let reason: String
    }

    static func extract(_ key: ClauseKey, laws: [String: LawDocument], notices: [String: AdminRuleDocument]) throws -> LawClause {
        switch key {
        case .actDuty:
            guard let act = laws[LawCatalog.actID], let art = act.article("9") else { throw ExtractError(reason: "법 제9조를 찾지 못함") }
            let lines = art.text.components(separatedBy: "\n")
            let cut = lines.firstIndex { $0.hasPrefix("③") } ?? lines.count
            return LawClause(key: key, lawName: act.name, text: lines[..<cut].joined(separator: "\n"),
                             effectiveDate: art.effectiveDate.isEmpty ? act.effectiveDate : art.effectiveDate,
                             promulgationDate: act.promulgationDate)

        case .decreeExitRequired, .decreeDefinitions:
            guard let decree = laws[LawCatalog.decreeID], let annex = decree.annex(1, branch: 2) else {
                throw ExtractError(reason: "시행령 별표 1의2를 찾지 못함")
            }
            let body = LawText.joinWrapped(annex.lines)
            let text: String?
            if key == .decreeExitRequired {
                text = LawText.slice(body, from: "2. 비상구", to: "3. 영업장 내부 피난통로")
            } else {
                text = LawText.slice(body, from: "비고", to: nil).flatMap { LawText.slice($0, from: "2.", to: "4.") }
            }
            guard let text else { throw ExtractError(reason: "\(key.citation) 경계 문구를 찾지 못함") }
            return LawClause(key: key, lawName: decree.name, text: text, effectiveDate: decree.effectiveDate, promulgationDate: decree.promulgationDate)

        case .ruleExitLocation, .ruleExitSize:
            guard let rule = laws[LawCatalog.ruleID], let annex = rule.annex(2) else { throw ExtractError(reason: "시행규칙 별표 2를 찾지 못함") }
            let rows = LawText.boxTableRows(annex.lines)
            guard let row = rows.first(where: { LawText.compact($0.left).hasPrefix("2.주된출입구") }) else {
                throw ExtractError(reason: "별표 2 「주된 출입구 및 비상구」 행을 찾지 못함")
            }
            let text = key == .ruleExitLocation
                ? LawText.slice(row.right, from: "1) 설치 위치", to: "2) 비상구등 규격")
                : LawText.slice(row.right, from: "2) 비상구등 규격", to: "3) 구조")
            guard let text else { throw ExtractError(reason: "\(key.citation) 경계 문구를 찾지 못함") }
            return LawClause(key: key, lawName: rule.name, text: text, effectiveDate: rule.effectiveDate, promulgationDate: rule.promulgationDate)

        case .noticeExistingGeneral, .noticeExistingSpecial:
            let id = key == .noticeExistingGeneral ? "31132" : "2034123"
            guard let notice = notices[id] else { throw ExtractError(reason: "고시(\(id))를 받지 못함") }
            // 조문은 줄 단위로 온다. 목적(제1조)·본문(제2조)만 쓰고 재검토기한 등은 뺀다.
            let articles = notice.lines.filter { $0.hasPrefix("제1조") || $0.hasPrefix("제2조") }
            guard !articles.isEmpty else { throw ExtractError(reason: "고시(\(id)) 제1조·제2조를 찾지 못함") }
            let text = articles.joined(separator: "\n")
            return LawClause(key: key, lawName: notice.name, text: text, effectiveDate: notice.effectiveDate, promulgationDate: notice.issuedDate)
        }
    }
}

// MARK: - 원문 처리 유틸

public enum LawText {
    /// 공백 전부 제거.
    public static func compact(_ s: String) -> String {
        String(s.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
    }

    public static func fingerprint(_ s: String) -> String {
        sha256(compact(s))
    }

    public static func wordingFingerprint(_ s: String) -> String {
        let masked = compact(s).replacingOccurrences(of: #"\d+"#, with: "#", options: .regularExpression)
        return sha256(masked)
    }

    static func sha256(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 줄바꿈으로 끊긴 원문을 잇는다. 한글끼리 끊긴 곳은 붙이고, 나머지는 공백 하나.
    public static func joinWrapped(_ lines: [String]) -> String {
        var out = ""
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if let last = out.last, let first = line.first {
                if isHangul(last) && isHangul(first) {
                    // 붙인다
                } else if last == "(" || first == ")" || first == "," || first == "." {
                    // 붙인다
                } else {
                    out.append(" ")
                }
            }
            out += line
        }
        return out.replacingOccurrences(of: #" {2,}"#, with: " ", options: .regularExpression)
    }

    static func isHangul(_ c: Character) -> Bool {
        c.unicodeScalars.allSatisfy { (0xAC00...0xD7A3).contains($0.value) }
    }

    /// 상자 표(│ 구분)를 행 묶음(├ 구분선 사이)별 왼쪽·오른쪽 칸 원문으로.
    public static func boxTableRows(_ lines: [String]) -> [(left: String, right: String)] {
        var rows: [(String, String)] = []
        var left: [String] = []
        var right: [String] = []
        func flush() {
            if !left.isEmpty || !right.isEmpty { rows.append((joinWrapped(left), joinWrapped(right))) }
            left = []
            right = []
        }
        for line in lines {
            if line.contains("├") || line.contains("┌") || line.contains("└") {
                flush()
                continue
            }
            let parts = line.components(separatedBy: "│")
            guard parts.count >= 4 else { continue }
            left.append(parts[1])
            right.append(parts[2])
        }
        flush()
        return rows
    }

    /// 공백을 무시하고 경계 문구로 잘라낸다. `to` 가 nil 이면 끝까지.
    public static func slice(_ text: String, from: String, to: String?) -> String? {
        guard let start = find(from, in: text, after: text.startIndex) else { return nil }
        var end = text.endIndex
        if let to {
            guard let r = find(to, in: text, after: start.upperBound) else { return nil }
            end = r.lowerBound
        }
        return String(text[start.lowerBound..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func find(_ anchor: String, in text: String, after: String.Index) -> Range<String.Index>? {
        let pattern = compact(anchor).map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: #"\s*"#)
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = NSRange(after..<text.endIndex, in: text)
        guard let m = re.firstMatch(in: text, range: ns) else { return nil }
        return Range(m.range, in: text)
    }
}
