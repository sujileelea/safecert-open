import Foundation

/// 법령 본문(법률·시행령·시행규칙).
public struct LawDocument: Hashable, Codable, Sendable {
    public struct Article: Hashable, Codable, Sendable {
        public var number: String
        public var branch: String
        public var title: String
        public var text: String
        public var effectiveDate: String
    }

    public struct Annex: Hashable, Codable, Sendable {
        public var number: String
        public var branch: String
        public var title: String
        public var lines: [String]
    }

    public var lawID: String
    public var name: String
    public var kind: String
    public var promulgationDate: String
    public var promulgationNumber: String
    public var effectiveDate: String
    public var articles: [Article]
    public var annexes: [Annex]

    public func article(_ number: String, branch: String = "") -> Article? {
        articles.first { $0.number == number && ($0.branch == branch || (branch.isEmpty && ($0.branch.isEmpty || $0.branch == "0"))) }
    }

    public func annex(_ number: Int, branch: Int = 0) -> Annex? {
        annexes.first { Int($0.number) == number && (Int($0.branch) ?? 0) == branch }
    }
}

/// 행정규칙 본문(고시·훈령·예규·공고).
public struct AdminRuleDocument: Hashable, Codable, Sendable {
    public var serial: String
    public var ruleID: String
    public var name: String
    public var kind: String
    public var issuedDate: String
    public var issueNumber: String
    public var effectiveDate: String
    public var ministry: String
    public var lines: [String]
}

public struct LawSearchEntry: Hashable, Codable, Sendable {
    public var name: String
    public var lawID: String
    public var serial: String
    public var status: String
    public var effectiveDate: String
    public var promulgationDate: String
}

public struct AdminRuleSearchEntry: Hashable, Codable, Sendable {
    public var name: String
    public var kind: String
    public var serial: String
    public var ruleID: String
    public var issuedDate: String
    public var effectiveDate: String
    public var ministry: String
    public var status: String
}

public enum LawParseError: Error, Equatable {
    case unexpectedShape(String)
}

/// API 응답 해석. 같은 필드가 문자열·배열·중첩 배열·{content:} 객체로 섞여 오므로 관대하게 읽는다.
public enum LawParser {
    public static func law(_ data: Data) throws -> LawDocument {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let law = root["법령"] as? [String: Any],
              let info = law["기본정보"] as? [String: Any] else { throw LawParseError.unexpectedShape("법령") }

        var articles: [LawDocument.Article] = []
        if let units = dicts((law["조문"] as? [String: Any])?["조문단위"]) {
            for u in units where str(u["조문여부"]) == "조문" {
                var parts = flat(u["조문내용"])
                for hang in dicts(u["항"]) ?? [] {
                    parts += flat(hang["항내용"])
                    for ho in dicts(hang["호"]) ?? [] {
                        parts += flat(ho["호내용"])
                        for mok in dicts(ho["목"]) ?? [] { parts += flat(mok["목내용"]) }
                    }
                }
                articles.append(.init(
                    number: str(u["조문번호"]) ?? "",
                    branch: str(u["조문가지번호"]) ?? "",
                    title: str(u["조문제목"]) ?? "",
                    text: parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n"),
                    effectiveDate: str(u["조문시행일자"]) ?? ""
                ))
            }
        }

        var annexes: [LawDocument.Annex] = []
        if let units = dicts((law["별표"] as? [String: Any])?["별표단위"]) {
            for u in units where str(u["별표구분"]) == "별표" {
                annexes.append(.init(
                    number: str(u["별표번호"]) ?? "",
                    branch: str(u["별표가지번호"]) ?? "",
                    title: str(u["별표제목"]) ?? "",
                    lines: flat(u["별표내용"])
                ))
            }
        }

        return LawDocument(
            lawID: str(info["법령ID"]) ?? "",
            name: str(info["법령명_한글"]) ?? "",
            kind: str(info["법종구분"]) ?? "",
            promulgationDate: str(info["공포일자"]) ?? "",
            promulgationNumber: str(info["공포번호"]) ?? "",
            effectiveDate: str(info["시행일자"]) ?? "",
            articles: articles,
            annexes: annexes
        )
    }

    public static func adminRule(_ data: Data) throws -> AdminRuleDocument {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let svc = root["AdmRulService"] as? [String: Any],
              let info = svc["행정규칙기본정보"] as? [String: Any] else { throw LawParseError.unexpectedShape("행정규칙") }
        return AdminRuleDocument(
            serial: str(info["행정규칙일련번호"]) ?? "",
            ruleID: str(info["행정규칙ID"]) ?? "",
            name: str(info["행정규칙명"]) ?? "",
            kind: str(info["행정규칙종류"]) ?? "",
            issuedDate: str(info["발령일자"]) ?? "",
            issueNumber: str(info["발령번호"]) ?? "",
            effectiveDate: str(info["시행일자"]) ?? "",
            ministry: str(info["소관부처명"]) ?? "",
            lines: flat(svc["조문내용"]).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        )
    }

    public static func lawSearch(_ data: Data) throws -> [LawSearchEntry] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let s = root["LawSearch"] as? [String: Any] else { throw LawParseError.unexpectedShape("LawSearch") }
        return (dicts(s["law"]) ?? []).map {
            LawSearchEntry(
                name: str($0["법령명한글"]) ?? "",
                lawID: str($0["법령ID"]) ?? "",
                serial: str($0["법령일련번호"]) ?? "",
                status: str($0["현행연혁코드"]) ?? "",
                effectiveDate: str($0["시행일자"]) ?? "",
                promulgationDate: str($0["공포일자"]) ?? ""
            )
        }
    }

    public static func adminRuleSearch(_ data: Data) throws -> [AdminRuleSearchEntry] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let s = root["AdmRulSearch"] as? [String: Any] else { throw LawParseError.unexpectedShape("AdmRulSearch") }
        return (dicts(s["admrul"]) ?? []).map {
            AdminRuleSearchEntry(
                name: str($0["행정규칙명"]) ?? "",
                kind: str($0["행정규칙종류"]) ?? "",
                serial: str($0["행정규칙일련번호"]) ?? "",
                ruleID: str($0["행정규칙ID"]) ?? "",
                issuedDate: str($0["발령일자"]) ?? "",
                effectiveDate: str($0["시행일자"]) ?? "",
                ministry: str($0["소관부처명"]) ?? "",
                status: str($0["현행연혁구분"]) ?? ""
            )
        }
    }

    // MARK: 관대한 접근자

    static func str(_ v: Any?) -> String? {
        switch v {
        case let s as String: s
        case let n as NSNumber: n.stringValue
        case let d as [String: Any]: str(d["content"])
        case let a as [Any]: a.compactMap { str($0) }.first
        default: nil
        }
    }

    static func flat(_ v: Any?) -> [String] {
        switch v {
        case let s as String: [s]
        case let a as [Any]: a.flatMap { flat($0) }
        case let d as [String: Any]: flat(d["content"])
        default: []
        }
    }

    static func dicts(_ v: Any?) -> [[String: Any]]? {
        switch v {
        case let d as [String: Any]: [d]
        case let a as [Any]: a.compactMap { $0 as? [String: Any] }
        default: nil
        }
    }
}
