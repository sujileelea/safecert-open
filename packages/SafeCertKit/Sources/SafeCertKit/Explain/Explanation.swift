import Foundation

/// 판정 근거 인용 — 조문 원문은 그날 법령 스냅샷에서 직접 삽입한다(LLM 생성 금지).
public struct Citation: Hashable, Codable, Sendable, Identifiable {
    public var key: ClauseKey
    public var citation: String
    public var layer: SourceLayer
    public var text: String
    public var effectiveDate: String
    public var lawBaseDate: String

    public var id: String { key.rawValue }
}

public struct ExplanationSection: Hashable, Codable, Sendable, Identifiable {
    public var number: Int
    public var title: String
    public var lines: [String]

    public var id: Int { number }
}

/// 판정 상세 7단(V-03, 감수 필드 제외).
public struct VerdictExplanation: Hashable, Codable, Sendable {
    public var verdictID: String
    public var sections: [ExplanationSection]
    public var citations: [Citation]
    public var lawStatus: [String]
}

public enum ExplanationComposer {
    public static func explain(_ v: Verdict, result: AnalysisResult, plan: PlanModel, snapshot: LawSnapshot) -> VerdictExplanation {
        let citations = v.rule.clauses.compactMap { key -> Citation? in
            guard let c = snapshot.clause(key) else { return nil }
            if key == .noticeExistingGeneral && result.conditions.isExistingBusiness != .yes { return nil }
            return Citation(key: key, citation: c.citation, layer: c.layer, text: c.text, effectiveDate: c.effectiveDate, lawBaseDate: snapshot.baseDate)
        }

        var sections: [ExplanationSection] = []
        sections.append(ExplanationSection(number: 1, title: "도면 위치", lines: [
            "\(v.target) — \(describe(v.location, plan: plan))"
        ]))
        sections.append(ExplanationSection(number: 2, title: "읽은 값", lines:
            v.readValues.isEmpty ? ["읽은 값 없음"] : v.readValues.map { "\($0.label): \($0.value) · \($0.source.displayName)" }
        ))
        sections.append(ExplanationSection(number: 3, title: "적용 조건", lines:
            [v.applicability] + v.criteria.map { "기준 — \($0.label): \($0.value)" }
        ))
        sections.append(ExplanationSection(number: 4, title: "법적 근거", lines:
            citations.map { "\($0.citation) (\($0.layer.rawValue) · 시행 \(LawDate.pretty($0.effectiveDate)))" }
        ))
        sections.append(ExplanationSection(number: 5, title: "시스템 판정", lines: [
            "\(v.color.displayName) · \(v.color.meaning) — \(v.summary)",
            "검토 상태: 전문가 미확인(감수 전)"
        ]))
        sections.append(ExplanationSection(number: 6, title: "신뢰도", lines: [
            "\(v.badge.displayName) · 객체 인식 신뢰도 \(Int((v.confidence * 100).rounded()))%",
            scaleLine(result.scale)
        ]))
        sections.append(ExplanationSection(number: 7, title: "확인사항", lines: v.checkItems.isEmpty ? ["추가 확인사항 없음"] : v.checkItems))

        var lawStatus = ["법령 기준일 \(snapshot.baseDate) · 스냅샷 \(snapshot.id) · \(snapshot.source)"]
        lawStatus += v.lawFlags.map(\.text)
        return VerdictExplanation(verdictID: v.id, sections: sections, citations: citations, lawStatus: lawStatus)
    }

    /// 결과 전체 요약(결정적 문장).
    public static func narrative(_ r: AnalysisResult) -> [String] {
        var lines: [String] = []
        let c = r.summary.counts
        lines.append("\(r.summary.headline) · \(r.summary.subline)")
        let parts = VerdictColor.allCases.compactMap { color -> String? in
            guard let n = c[color], n > 0 else { return nil }
            return "\(color.displayName) \(n)"
        }
        lines.append("판정 \(r.verdicts.count)건: " + parts.joined(separator: " · "))
        if let area = r.areaSquareMeters {
            lines.append("영업장 바닥면적 \(RuleEngine.fmt(area, "㎡")) · 구획된 실 \(r.roomCount)개")
        }
        for v in r.verdicts where v.color == .red {
            lines.append("의무 미충족 — \(v.title) · \(v.target): \(v.summary)")
        }
        lines.append("법령 기준일 \(r.lawBaseDate). 판정은 규칙 엔진이 내렸고, 유자격 전문가 감수 전 결과다.")
        return lines
    }

    static func scaleLine(_ s: ScaleEstimate?) -> String {
        guard let s else { return "축척: 추정 실패" }
        let state = s.confirmed ? "확인됨" : "미확인"
        let check = s.isCrossValidated ? "치수 \(s.crossChecks)개 교차검증 일치" : "교차검증 \(s.crossChecks)개 · 어긋남 \(s.conflicts)개"
        return "축척 1:\(s.ratio) · \(s.source.displayName) · \(check) · \(state)"
    }

    /// 표시 위치를 영업장 안의 상대 위치 말로.
    static func describe(_ loc: VerdictLocation, plan: PlanModel) -> String {
        guard let b = plan.boundary?.bounds else { return "도면 위 표시 참조" }
        let pts = loc.markers.isEmpty ? (loc.area.map { [$0.centroid] } ?? []) : loc.markers
        guard !pts.isEmpty else { return "영업장 전체" }
        var names: [String] = []
        for p in pts {
            let h = p.x < b.minX + b.width / 3 ? "왼쪽" : p.x > b.maxX - b.width / 3 ? "오른쪽" : "가운데"
            let vtc = p.y < b.minY + b.height / 3 ? "위" : p.y > b.maxY - b.height / 3 ? "아래" : "중간"
            let name = "영업장 \(h) \(vtc)"
            if names.last != name { names.append(name) }
        }
        return names.joined(separator: " → ")
    }
}
