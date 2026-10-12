import Foundation

/// 검증 ⑤ 회귀: 기준 하나를 바꿔 샘플 도면을 다시 판정했을 때
/// 그 기준에 묶이지 않은 규칙의 결과가 바뀌면 실패.
public enum RegressionSuite {
    public struct Case: Sendable {
        public var name: String
        public var plan: PlanModel
        public var scale: ScaleEstimate?
        public var conditions: Conditions
    }

    /// 샘플 도면 3종 × 조건 → 회귀 세트.
    public static func sampleCases() -> [Case] {
        SamplePlan.all.flatMap { sample -> [Case] in
            guard let page = try? VectorPDF.read(SamplePlanRenderer.pdf(for: sample)) else { return [] }
            let plan = PlanInterpreter.interpret(page)
            var scale = ScaleEstimator.estimate(page)
            scale?.confirmed = true
            return [Tri.yes, .no].map { floor in
                Case(name: "\(sample.id)·피난층 \(floor.displayName)", plan: plan, scale: scale,
                     conditions: Conditions(isEvacuationFloor: floor))
            }
        }
    }

    public static func check(cases: [Case], base: LawSnapshot) -> RegressionCheck {
        { key, old, new in
            guard let old else { return (true, "첫 수집 — 비교 대상 없음") }
            let before = replacing(base, key, old)
            let after = replacing(base, key, new)
            var affected = 0
            var leaks: [String] = []
            var directionIssues: [String] = []
            let direction = strictness(key, old, new)
            for c in cases {
                let r0 = RuleEngine.evaluate(.init(plan: c.plan, scale: c.scale, conditions: c.conditions, snapshot: before))
                let r1 = RuleEngine.evaluate(.init(plan: c.plan, scale: c.scale, conditions: c.conditions, snapshot: after))
                let v0 = Dictionary(uniqueKeysWithValues: r0.verdicts.map { ($0.id, $0) })
                for v in r1.verdicts {
                    guard let prior = v0[v.id] else { leaks.append("\(c.name): 새 판정 \(v.id)"); continue }
                    let changed = prior.color != v.color || prior.summary != v.summary
                    if !changed { continue }
                    if v.rule.criteria.contains(key) {
                        affected += 1
                        // 방향 일관성: 기준이 엄격해졌는데 판정이 나아지거나, 완화됐는데 나빠지면 엔진 비교 방향 오류
                        if let r0 = severity(prior.color), let r1 = severity(v.color), let direction {
                            if direction > 0 && r1 < r0 { directionIssues.append("\(c.name): \(v.id) 엄격해졌는데 완화") }
                            if direction < 0 && r1 > r0 { directionIssues.append("\(c.name): \(v.id) 완화됐는데 엄격") }
                        }
                    } else {
                        leaks.append("\(c.name): \(v.id)")
                    }
                }
                if r0.verdicts.count != r1.verdicts.count { leaks.append("\(c.name): 판정 수 변화") }
            }
            if !leaks.isEmpty { return (false, "무관 규칙 변화: \(leaks.prefix(3).joined(separator: ", "))") }
            if !directionIssues.isEmpty { return (false, "방향 불일치: \(directionIssues.prefix(3).joined(separator: ", "))") }
            let dirText = direction.map { $0 > 0 ? "엄격화" : $0 < 0 ? "완화" : "동일" } ?? "혼합"
            return (true, "샘플 \(cases.count)건 재판정 — 영향 판정 \(affected)건(\(dirText) 방향 일관), 무관 규칙 변화 없음")
        }
    }

    /// 초록 0 < 주황 1 < 빨강 2. 회색·노랑은 비교하지 않는다.
    static func severity(_ c: VerdictColor) -> Int? {
        switch c {
        case .green: 0
        case .orange: 1
        case .red: 2
        case .gray, .yellow: nil
        }
    }

    /// 값별 엄격 방향: +1 = 값이 클수록 엄격, -1 = 클수록 완화.
    static let strictSign: [CriterionKey: [String: Double]] = [
        .exitSize: ["minWidth": 1, "minHeight": 1],
        .exitLocation: ["ratio": 1],
        .exitRequired: ["exemptionA.ratio": 1, "exemptionB.maxArea": -1, "exemptionB.maxDistance": -1],
        .existingExemption: ["maxArea": -1]
    ]

    /// 전체 변화 방향: +1 엄격화, -1 완화, 0 동일, nil 혼합·판단 불가.
    static func strictness(_ key: CriterionKey, _ old: Criterion, _ new: Criterion) -> Int? {
        guard let signs = strictSign[key] else { return nil }
        var dir = 0
        for (name, sign) in signs.sorted(by: { $0.key < $1.key }) {
            guard let a = old[name]?.number, let b = new[name]?.number, a != b else { continue }
            let d = (b > a ? 1 : -1) * Int(sign)
            if dir == 0 { dir = d } else if dir != d { return nil }
        }
        for name in Set(old.values.keys).union(new.values.keys) where signs[name] == nil && old[name] != new[name] { return nil }
        return dir
    }

    static func replacing(_ s: LawSnapshot, _ key: CriterionKey, _ c: Criterion) -> LawSnapshot {
        var s = s
        if let i = s.criteria.firstIndex(where: { $0.key == key }) {
            s.criteria[i].criterion = c
            s.criteria[i].status = .verified
            s.criteria[i].revisedOn = nil
        }
        return s
    }
}

public extension LawSync {
    /// 회귀 세트를 붙인 일일 동기화. 이전 스냅샷이 없으면 회귀 비교를 건너뛴다.
    static func runWithRegression(fetcher: any LawFetching, previous: LawSnapshot?, isSeed: Bool = false,
                                  now: Date = Date(), cases: [RegressionSuite.Case]) async -> LawSnapshot {
        let regression = previous.map { RegressionSuite.check(cases: cases, base: $0) }
        return await run(fetcher: fetcher, previous: previous, isSeed: isSeed, now: now, regression: regression)
    }
}
