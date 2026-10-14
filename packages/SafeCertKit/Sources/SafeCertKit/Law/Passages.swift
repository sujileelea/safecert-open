import Foundation

/// 조문 검색(RAG) 단위 — 그날 수집한 법령 전문을 조·별표 행·고시 조 단위로 나눈 원문(공백만 정리).
/// 보고서 생성 때 판정마다 관련 구절을 찾아 생성형 모델에 넣고, 보고서 부록에 원문 그대로 싣는다.
public struct LawPassage: Identifiable, Hashable, Codable, Sendable {
    /// "<문서 키>#<문서 안 위치>". 문서 키 = 법령 ID 또는 "admrul.<행정규칙 ID>".
    public var id: String
    public var layer: SourceLayer
    public var lawName: String
    /// 문서 안 위치 이름 — 「제9조(…)」, 「별표 2 주된 출입구 및 비상구」 등.
    public var label: String
    public var text: String
    public var effectiveDate: String

    public var documentKey: String { String(id.split(separator: "#").first ?? "") }
    public var citation: String { "\(lawName) \(label)" }
}

public enum PassageBuilder {
    /// 구절 하나의 최대 글자 수(모델 입력과 보고서 부록이 읽기 좋은 길이).
    static let maxLength = 700

    /// 하루치 수집 문서 → 구절. 문서·조 순서대로 결정적.
    public static func build(laws: [String: LawDocument], notices: [String: AdminRuleDocument]) -> [LawPassage] {
        var out: [LawPassage] = []
        for (id, layer) in [(LawCatalog.actID, SourceLayer.act), (LawCatalog.decreeID, .decree), (LawCatalog.ruleID, .rule)] {
            guard let doc = laws[id] else { continue }
            out += passages(law: doc, key: id, layer: layer)
        }
        for id in ["31132", "2034123"] {
            guard let doc = notices[id] else { continue }
            out += passages(notice: doc, key: "admrul.\(id)")
        }
        return out
    }

    /// 수집 실패한 문서는 이전 스냅샷의 구절을 이어 쓴다.
    public static func merge(fresh: [LawPassage], previous: [LawPassage]?) -> [LawPassage] {
        let present = Set(fresh.map(\.documentKey))
        let expected = [LawCatalog.actID, LawCatalog.decreeID, LawCatalog.ruleID, "admrul.31132", "admrul.2034123"]
        var out = fresh
        for key in expected where !present.contains(key) {
            out += (previous ?? []).filter { $0.documentKey == key }
        }
        return out
    }

    static func passages(law doc: LawDocument, key: String, layer: SourceLayer) -> [LawPassage] {
        var out: [LawPassage] = []
        for a in doc.articles where !a.text.isEmpty {
            let branch = a.branch.isEmpty || a.branch == "0" ? "" : "의\(a.branch)"
            let title = a.title.isEmpty ? "" : "(\(a.title))"
            let label = "제\(a.number)조\(branch)\(title)"
            let effective = a.effectiveDate.isEmpty ? doc.effectiveDate : a.effectiveDate
            for (i, chunk) in chunks(a.text.components(separatedBy: "\n")).enumerated() {
                out.append(LawPassage(id: "\(key)#art\(a.number)\(branch)" + (i > 0 ? ".\(i + 1)" : ""), layer: layer, lawName: doc.name,
                                      label: label, text: chunk, effectiveDate: effective))
            }
        }
        for x in doc.annexes {
            let branch = (Int(x.branch) ?? 0) > 0 ? "의\(Int(x.branch)!)" : ""
            let number = Int(x.number).map(String.init) ?? x.number
            let base = "별표 \(number)\(branch)"
            let local = "annex\(number)\(branch)"
            if x.lines.contains(where: { $0.contains("│") }) {
                // 상자 표: 행(├ 구분선 사이)마다 「왼쪽 칸 — 오른쪽 칸」. 이름에 별표 제목(관련 조 표기 제외)을 붙인다.
                let short = x.title.replacing(/\s*\(제[^)]*관련\)\s*$/, with: "").trimmingCharacters(in: .whitespaces)
                let tableName = short.isEmpty ? base : "\(base)(\(short))"
                for (r, row) in LawText.boxTableRows(x.lines).enumerated() {
                    let left = row.left.trimmingCharacters(in: .whitespaces)
                    let pieces = chunks(row.rightLines)
                    for (i, chunk) in pieces.enumerated() where !(left + chunk).isEmpty {
                        out.append(LawPassage(id: "\(key)#\(local).row\(r + 1)" + (i > 0 ? ".\(i + 1)" : ""), layer: layer, lawName: doc.name,
                                              label: left.isEmpty ? tableName : "\(tableName) \(left)", text: chunk.isEmpty ? left : chunk,
                                              effectiveDate: doc.effectiveDate))
                    }
                }
            } else {
                for (i, chunk) in chunks(x.lines).enumerated() {
                    out.append(LawPassage(id: "\(key)#\(local).\(i + 1)", layer: layer, lawName: doc.name,
                                          label: "\(base) \(x.title)".trimmingCharacters(in: .whitespaces), text: chunk,
                                          effectiveDate: doc.effectiveDate))
                }
            }
        }
        return out
    }

    static func passages(notice doc: AdminRuleDocument, key: String) -> [LawPassage] {
        // 고시는 줄 단위로 오고, 「제N조」로 시작하는 줄이 조의 시작이다.
        var groups: [(label: String, lines: [String])] = []
        for line in doc.lines {
            if let m = line.firstMatch(of: /^제\d+조(의\d+)?(\([^)]*\))?/) {
                groups.append((String(m.output.0), [line]))
            } else if groups.isEmpty {
                groups.append(("본문", [line]))
            } else {
                groups[groups.count - 1].lines.append(line)
            }
        }
        var out: [LawPassage] = []
        for (g, group) in groups.enumerated() {
            for (i, chunk) in chunks(group.lines).enumerated() {
                out.append(LawPassage(id: "\(key)#g\(g + 1)" + (i > 0 ? ".\(i + 1)" : ""), layer: .notice, lawName: doc.name,
                                      label: group.label, text: chunk, effectiveDate: doc.effectiveDate))
            }
        }
        return out
    }

    /// 줄을 이어 붙여 최대 길이 안의 덩어리로. 번호 항목(「1.」「가.」「1)」) 앞에서 끊기를 우선한다.
    static func chunks(_ lines: [String]) -> [String] {
        var out: [String] = []
        var current: [String] = []
        var length = 0
        func flush() {
            let text = LawText.joinWrapped(current)
            if !text.isEmpty { out.append(text) }
            current = []
            length = 0
        }
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let startsItem = line.firstMatch(of: /^(\d+\.|[가-하]\.|\d+\))\s/) != nil
            if !current.isEmpty && (length + line.count > maxLength || (startsItem && length > maxLength / 3)) { flush() }
            current.append(line)
            length += line.count
        }
        flush()
        // 한 줄이 최대 길이를 넘으면 글자 수로 자른다.
        return out.flatMap { text -> [String] in
            guard text.count > maxLength * 2 else { return [text] }
            var pieces: [String] = []
            var rest = Substring(text)
            while !rest.isEmpty {
                pieces.append(String(rest.prefix(maxLength)))
                rest = rest.dropFirst(maxLength)
            }
            return pieces
        }
    }
}
