import Foundation

/// 보고서에 들어갈 판정 1회분.
public struct ReportInput: Sendable {
    public var result: AnalysisResult
    public var plan: PlanModel
    public var snapshot: LawSnapshot
    public var projectName: String
    public var fileName: String
    public var judgedAt: Date

    public init(result: AnalysisResult, plan: PlanModel, snapshot: LawSnapshot, projectName: String, fileName: String, judgedAt: Date) {
        self.result = result
        self.plan = plan
        self.snapshot = snapshot
        self.projectName = projectName
        self.fileName = fileName
        self.judgedAt = judgedAt
    }
}

/// 판정 결과 → 보고서. 흐름: 근거 묶음 → 조문 검색(RAG) → 생성형 AI 서술 → 근거 대조 → (PDF 는 ReportPDF).
public enum ReportBuilder {
    public static let title = "도면 사전검토 보고서"

    public static func build(_ input: ReportInput, narrator: (any ReportNarrating)?, now: Date = Date()) async -> InspectionReport {
        let r = input.result
        let retriever = LawRetriever(passages: input.snapshot.passages ?? [])

        var sections: [ReportVerdictSection] = []
        for (i, v) in r.verdicts.enumerated() {
            let explanation = ExplanationComposer.explain(v, result: r, plan: input.plan, snapshot: input.snapshot)
            let related = retriever.search(query(for: v), limit: 2, excluding: explanation.citations.map(\.text))
            let facts = verdictFacts(v, explanation: explanation)

            var narrative = ReportNarrative(sentences: fallbackExplanation(v), isAI: false)
            var nextSteps = ReportNarrative(sentences: v.checkItems.isEmpty ? ["추가 확인사항 없음."] : v.checkItems, isAI: false)
            if let narrator, let w = await narrator.verdict(facts: facts, passages: passageText(explanation.citations, related)) {
                let checked = NarrativeGuard.filter(NarrativeGuard.sentences(w.explanation), facts: facts)
                if !checked.kept.isEmpty { narrative = ReportNarrative(sentences: checked.kept, isAI: true, dropped: checked.dropped) }
                let steps = NarrativeGuard.filter(w.nextSteps.flatMap(NarrativeGuard.sentences), facts: facts)
                if !steps.kept.isEmpty { nextSteps = ReportNarrative(sentences: steps.kept, isAI: true, dropped: steps.dropped) }
            }
            sections.append(ReportVerdictSection(number: i + 1, verdict: v, explanation: explanation,
                                                 narrative: narrative, nextSteps: nextSteps, related: related))
        }

        let facts = summaryFacts(r)
        var summary = ReportNarrative(sentences: ExplanationComposer.narrative(r), isAI: false)
        if let narrator, let text = await narrator.summary(facts: facts) {
            let checked = NarrativeGuard.filter(NarrativeGuard.sentences(text), facts: facts, verdicts: r.verdicts)
            if !checked.kept.isEmpty { summary = ReportNarrative(sentences: checked.kept, isAI: true, dropped: checked.dropped) }
        }

        let snap = input.snapshot
        var lawStatus = ["법령 기준일 \(snap.baseDate) · 스냅샷 \(snap.id)", "출처: \(snap.source)"]
        lawStatus += Array(Set(r.verdicts.flatMap(\.lawFlags).map(\.text))).sorted()
        return InspectionReport(
            title: title,
            projectName: input.projectName,
            fileName: input.fileName,
            createdAt: now,
            judgedAt: input.judgedAt,
            result: r,
            lawSource: snap.source,
            scope: [
                "대상: 다중이용업소 영업장 평면도(벡터 PDF 자동판정 보장 범위)",
                "규칙: 비상구 설치 · 비상구 위치(이격거리) · 비상구등 규격",
                "법령: 다중이용업소법·시행령·시행규칙·소방청 고시(매일 실측 수집)",
                "업종: \(r.conditions.businessType.displayName) · 피난층 \(r.conditions.isEvacuationFloor.displayName) · 기존 업소 \(r.conditions.isExistingBusiness.displayName)",
            ],
            summary: summary,
            sections: sections,
            lawStatus: lawStatus,
            notes: r.notes,
            model: narrator?.modelName
        )
    }

    // MARK: 근거 묶음

    /// 판정별 조문 검색어 — 규칙 이름·결과 문장·기준 이름 + 규칙별 법령 용어.
    static func query(for v: Verdict) -> String {
        let terms: String
        switch v.rule {
        case .exitRequired: terms = "비상구 설치 주된 출입구 영업장 구획된 실 피난층 직통계단"
        case .exitLocation: terms = "비상구 설치 위치 주된 출입구 떨어진 위치 반대방향 가장 긴 길이"
        case .exitSize: terms = "비상구등 규격 가로 세로 센티미터 문틀"
        }
        return ([v.title, v.summary, terms] + v.criteria.map(\.label)).joined(separator: " ")
    }

    static func verdictFacts(_ v: Verdict, explanation: VerdictExplanation) -> String {
        var lines = [
            "판정 항목: \(v.title)",
            "대상: \(v.target)",
            "판정 색: \(v.color.displayName)(\(v.color.meaning))",
            "확실성: \(v.badge.displayName)",
            "결과: \(v.summary)",
            "적용 이유: \(v.applicability)",
        ]
        lines += v.readValues.map { "읽은 값 — \($0.label): \($0.value)(\($0.source.displayName))" }
        lines += v.criteria.map { "기준 — \($0.label): \($0.value)" }
        lines += v.checkItems.map { "확인사항 — \($0)" }
        lines += explanation.citations.map { "근거 조문 — \($0.citation)" }
        lines += v.lawFlags.map { "법령 상태 — \($0.text)" }
        lines.append("검토 상태: 전문가 감수 전")
        return lines.joined(separator: "\n")
    }

    static func summaryFacts(_ r: AnalysisResult) -> String {
        var lines = ["전체: \(r.summary.headline) (\(r.summary.subline))"]
        for color in VerdictColor.allCases {
            if let n = r.summary.counts[color], n > 0 { lines.append("\(color.displayName)(\(color.meaning)): \(n)건") }
        }
        if let a = r.areaSquareMeters { lines.append("영업장 바닥면적: \(RuleEngine.fmt(a, "㎡")) · 구획된 실 \(r.roomCount)개") }
        for (i, v) in r.verdicts.enumerated() {
            lines.append("\(i + 1). \(v.title) / \(v.target) / \(v.color.displayName)(\(v.color.meaning)) / \(v.summary)")
        }
        lines.append("법령 기준일: \(r.lawBaseDate)")
        lines.append("검토 상태: 전문가 감수 전")
        return lines.joined(separator: "\n")
    }

    /// 모델에 넣을 조문 원문 — 직접 근거 조문 + 검색 구절, 기기 내 모델 입력 크기에 맞춰 자른다.
    static func passageText(_ citations: [Citation], _ related: [RetrievedPassage], limit: Int = 1400) -> String {
        var parts = citations.map { "[\($0.citation)] \(LawText.joinWrapped($0.text.components(separatedBy: "\n")))" }
        parts += related.map { "[\($0.passage.citation)] \($0.passage.text)" }
        var out = ""
        for p in parts {
            let room = limit - out.count
            guard room > 80 else { break }
            out += (out.isEmpty ? "" : "\n") + String(p.prefix(room))
        }
        return out
    }

    static func fallbackExplanation(_ v: Verdict) -> [String] {
        var s = ["\(v.title) — \(v.target): \(v.summary)."]
        if !v.applicability.isEmpty { s.append(v.applicability) }
        return s
    }
}

/// 근거 대조 — AI 문장 중 사실에 없는 숫자·판정 표현·금지어가 있는 문장을 뺀다.
public enum NarrativeGuard {
    /// 감수 전에는 쓰지 않는 말(V-07 ③), 만들지 않는 값(X-01: 벌금·손해액), 판정을 넘어서는 단정.
    static let forbidden = [
        "부적합", "적합합니다", "적합하", "적합으로", "적합 판정", "적합한 것",
        "벌금", "과태료 금액", "만원", "억원", "징역",
        "안전합니다", "안전하다", "문제없", "문제가 없", "위반이다", "위반입니다", "위반한다", "위반하고 있",
    ]

    /// 문장 단위로 나누고 끝맺음을 고른다(마침표 없으면 붙이고, 괄호 뒤에 붙은 「다.」는 뗀다).
    public static func sentences(_ text: String) -> [String] {
        text.replacingOccurrences(of: #"([.!?])\s+"#, with: "$1\n", options: .regularExpression)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "-•·*"))) }
            .filter { !$0.isEmpty }
            .map { s in
                var s = s.replacingOccurrences(of: #"\)다\.$"#, with: ").", options: .regularExpression)
                if let last = s.last, !".!?".contains(last) { s += "." }
                return s
            }
    }

    public static func filter(_ sentences: [String], facts: String, verdicts: [Verdict] = []) -> (kept: [String], dropped: Int) {
        let kept = sentences.filter { isGrounded($0, facts: facts) && pairsMatch($0, verdicts: verdicts) }
        return (kept, sentences.count - kept.count)
    }

    /// 한 문장에 판정 색과 항목이 함께 나오면, 실제로 그 색을 받은 항목이어야 한다
    /// (예: 주황은 「비상구 설치」인데 「주황 … 비상구 위치」라고 쓰면 뺀다).
    public static func pairsMatch(_ s: String, verdicts: [Verdict]) -> Bool {
        let colors = VerdictColor.allCases.filter { c in
            s.contains(c.displayName) || s.contains(String(c.meaning.split(separator: " · ").first ?? ""))
        }
        let rules = RuleKey.allCases.filter { r in mentions(r).contains { s.contains($0) } }
        guard !colors.isEmpty, !rules.isEmpty else { return true }
        return colors.allSatisfy { c in verdicts.contains { $0.color == c && rules.contains($0.rule) } }
    }

    static func mentions(_ r: RuleKey) -> [String] {
        switch r {
        case .exitRequired: ["비상구 설치"]
        case .exitLocation: ["위치", "이격"]
        case .exitSize: ["규격"]
        }
    }

    public static func isGrounded(_ s: String, facts: String) -> Bool {
        guard s.count >= 4 else { return false }
        if forbidden.contains(where: { s.contains($0) }) { return false }
        // 숫자는 전부 사실에 있어야 한다.
        let numbers = { (t: String) -> Set<String> in Set(t.matches(of: /\d+(?:\.\d+)?/).map { String($0.output) }) }
        guard numbers(s).isSubset(of: numbers(facts)) else { return false }
        // 판정 색·뜻은 사실에 있는 것만 말할 수 있다.
        for c in VerdictColor.allCases {
            for word in [c.displayName, c.meaning] where s.contains(word) && !facts.contains(word) { return false }
        }
        return true
    }
}
