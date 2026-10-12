import Foundation

public enum CheckKind: String, Codable, Sendable, CaseIterable {
    case schema
    case grounding
    case dualParse
    case magnitude
    case regression

    public var displayName: String {
        switch self {
        case .schema: "① 형식"
        case .grounding: "② 원문 근거"
        case .dualParse: "③ 이중 정규화 일치"
        case .magnitude: "④ 변화 폭"
        case .regression: "⑤ 회귀"
        }
    }
}

public struct VerificationCheck: Hashable, Codable, Sendable {
    public var kind: CheckKind
    public var passed: Bool
    public var detail: String
}

public struct CriterionState: Hashable, Codable, Sendable {
    public enum Status: String, Codable, Sendable {
        /// 검증 5종 통과 — 그날 값.
        case verified
        /// 숫자 검증 실패 — 이전 값 유지.
        case rejected
        /// 문구(해석) 변경 — 자동 반영하지 않고 이전 값 유지.
        case interpretationChanged
        /// 쓸 수 있는 값이 없다.
        case unavailable

        public var isTrusted: Bool { self == .verified }
    }

    public var key: CriterionKey
    /// 판정에 쓰는 값(검증 통과한 마지막 값).
    public var criterion: Criterion?
    public var status: Status
    public var checks: [VerificationCheck]
    /// 지금 값이 처음 반영된 법령 기준일.
    public var acceptedOn: String?
    /// 값이 개정으로 바뀐 날(첫 수집은 nil).
    public var revisedOn: String?
    /// 반영되지 않은 후보 값(실패·해석 변경 시 표시용).
    public var rejectedCandidate: Criterion?
    public var note: String?
}

public struct PendingAmendment: Hashable, Codable, Sendable {
    public var lawName: String
    public var lawID: String
    public var effectiveDate: String
    public var promulgationDate: String
}

public struct LawChangeEvent: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case clauseChanged, wordingChanged, criterionUpdated, criterionRejected, pendingAmendment, noticeListChanged, collectionFailed, extractionFailed, firstCollection
    }

    public var kind: Kind
    public var subject: String
    public var detail: String
}

/// 하루치 법령 스냅샷 = 판정의 법령 기준.
public struct LawSnapshot: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    /// 법령 기준일(마지막 성공 수집일, KST yyyy-MM-dd).
    public var baseDate: String
    public var checkedAt: Date
    public var source: String
    public var isSeed: Bool
    /// 수집 실패로 전날 스냅샷을 이어 쓰는 중.
    public var isStale: Bool
    public var clauses: [LawClause]
    public var criteria: [CriterionState]
    public var pendingAmendments: [PendingAmendment]
    public var notices: [AdminRuleSearchEntry]
    public var events: [LawChangeEvent]
    public var collectionErrors: [String]

    public func clause(_ key: ClauseKey) -> LawClause? { clauses.first { $0.key == key } }
    public func state(_ key: CriterionKey) -> CriterionState? { criteria.first { $0.key == key } }

    /// 최근 개정(30일) 여부.
    public func isRecentlyRevised(_ key: CriterionKey) -> Bool {
        guard let r = state(key)?.revisedOn else { return false }
        return LawDate.days(from: r, to: baseDate).map { $0 <= 30 } ?? false
    }
}

public enum LawDate {
    static let kst = TimeZone(identifier: "Asia/Seoul")!

    static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = kst
        f.dateFormat = format
        return f
    }

    public static func day(_ d: Date) -> String { formatter("yyyy-MM-dd").string(from: d) }
    public static func compact(_ d: Date) -> String { formatter("yyyyMMdd").string(from: d) }
    public static func stamp(_ d: Date) -> String { formatter("yyyyMMdd-HHmm").string(from: d) }

    /// "20260701" → "2026-07-01"
    public static func pretty(_ yyyymmdd: String) -> String {
        guard yyyymmdd.count == 8 else { return yyyymmdd }
        let s = Array(yyyymmdd)
        return "\(String(s[0..<4]))-\(String(s[4..<6]))-\(String(s[6..<8]))"
    }

    static func days(from a: String, to b: String) -> Int? {
        let f = formatter("yyyy-MM-dd")
        guard let da = f.date(from: a), let db = f.date(from: b) else { return nil }
        return Calendar(identifier: .gregorian).dateComponents([.day], from: da, to: db).day
    }

    /// 다음 05:00 KST.
    public static func nextDailyRun(after d: Date, hour: Int = 5) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = kst
        let today = cal.date(bySettingHour: hour, minute: 0, second: 0, of: d)!
        return today > d ? today : cal.date(byAdding: .day, value: 1, to: today)!
    }
}

/// 회귀 검사 주입점: (이전 기준, 새 기준) → 통과 여부·설명. 규칙 엔진이 제공한다.
public typealias RegressionCheck = @Sendable (_ key: CriterionKey, _ old: Criterion?, _ new: Criterion) -> (passed: Bool, detail: String)

public enum LawSnapshotBuilder {
    public static func build(
        sources: LawSources,
        previous: LawSnapshot?,
        isSeed: Bool = false,
        regression: RegressionCheck? = nil
    ) -> LawSnapshot {
        let now = sources.fetchedAt
        let today = LawDate.day(now)
        var events: [LawChangeEvent] = []

        // 핵심 법령을 하나도 못 받으면 전날 스냅샷을 이어 쓴다.
        let coreMissing = [LawCatalog.actID, LawCatalog.decreeID, LawCatalog.ruleID].allSatisfy { sources.laws[$0] == nil }
        if coreMissing, var carried = previous {
            carried.id = "\(LawDate.stamp(now))-stale"
            carried.checkedAt = now
            carried.isStale = true
            carried.collectionErrors = sources.errors
            carried.events = [LawChangeEvent(kind: .collectionFailed, subject: "법령 수집", detail: sources.errors.joined(separator: " · "))]
            return carried
        }

        // 조문 추출(실패한 조문은 전날 것을 이어 쓴다)
        let (extracted, failures) = ClauseExtractor.extract(laws: sources.laws, notices: sources.notices)
        var clauses = Dictionary(uniqueKeysWithValues: extracted.map { ($0.key, $0) })
        for f in failures {
            events.append(LawChangeEvent(kind: .extractionFailed, subject: f.key.citation, detail: f.reason))
            if let old = previous?.clause(f.key) { clauses[f.key] = old }
        }
        if previous == nil {
            events.append(LawChangeEvent(kind: .firstCollection, subject: "법령 기준", detail: "첫 수집 — 조문 \(clauses.count)개"))
        }
        for (key, c) in clauses {
            guard let old = previous?.clause(key) else { continue }
            if old.fingerprint != c.fingerprint {
                let kind: LawChangeEvent.Kind = old.wordingFingerprint != c.wordingFingerprint ? .wordingChanged : .clauseChanged
                events.append(LawChangeEvent(kind: kind, subject: key.citation,
                                             detail: kind == .wordingChanged ? "문구 변경(해석 변경 가능)" : "숫자 변경"))
            }
        }

        // 기준별 정규화·검증
        var states: [CriterionState] = []
        for key in CriterionKey.allCases {
            let prevState = previous?.state(key)
            let prevClause = previous?.clause(key.clauseKey)
            guard let clause = clauses[key.clauseKey] else {
                states.append(prevState ?? CriterionState(key: key, criterion: nil, status: .unavailable, checks: [], note: "조문을 받지 못함"))
                continue
            }
            if let prevState, let prevClause, prevClause.fingerprint == clause.fingerprint, failures.allSatisfy({ $0.key != key.clauseKey }) {
                states.append(prevState)
                continue
            }
            let state = evaluate(key: key, clause: clause, prevClause: prevClause, prevState: prevState, today: today, regression: regression)
            if state.status == .verified, prevState?.criterion != nil, state.revisedOn == today {
                events.append(LawChangeEvent(kind: .criterionUpdated, subject: key.displayName, detail: "검증 5종 통과 — 새 값 반영"))
            } else if state.status == .rejected || state.status == .interpretationChanged {
                events.append(LawChangeEvent(kind: .criterionRejected, subject: key.displayName, detail: state.note ?? ""))
            }
            states.append(state)
        }

        // 공포 후 미시행 개정
        let todayCompact = LawDate.compact(now)
        let familyNames = Set(sources.laws.values.map(\.name))
        let pending = sources.effectiveSearch
            .filter { $0.effectiveDate > todayCompact && (familyNames.contains($0.name) || $0.name.hasPrefix("다중이용업소의 안전관리에 관한 특별법")) }
            .map { PendingAmendment(lawName: $0.name, lawID: $0.lawID, effectiveDate: $0.effectiveDate, promulgationDate: $0.promulgationDate) }
        let previousPending = Set(previous?.pendingAmendments ?? [])
        for p in pending where !previousPending.contains(p) {
            events.append(LawChangeEvent(kind: .pendingAmendment, subject: p.lawName, detail: "\(LawDate.pretty(p.effectiveDate)) 시행 예정 개정 공포"))
        }

        // 관련 고시 목록 변화
        let notices = sources.noticeSearch.isEmpty ? (previous?.notices ?? []) : sources.noticeSearch
        if let prevNotices = previous?.notices, !sources.noticeSearch.isEmpty {
            let before = Set(prevNotices.map { "\($0.ruleID)|\($0.issuedDate)" })
            for n in sources.noticeSearch where !before.contains("\(n.ruleID)|\(n.issuedDate)") {
                events.append(LawChangeEvent(kind: .noticeListChanged, subject: n.name, detail: "\(n.kind) \(LawDate.pretty(n.issuedDate)) 발령"))
            }
        }

        return LawSnapshot(
            id: isSeed ? "seed-\(LawDate.compact(now))" : LawDate.stamp(now),
            baseDate: today,
            checkedAt: now,
            source: sources.sourceDescription,
            isSeed: isSeed,
            isStale: false,
            clauses: ClauseKey.allCases.compactMap { clauses[$0] },
            criteria: states,
            pendingAmendments: pending,
            notices: notices,
            events: events,
            collectionErrors: sources.errors
        )
    }

    static func evaluate(key: CriterionKey, clause: LawClause, prevClause: LawClause?, prevState: CriterionState?,
                         today: String, regression: RegressionCheck?) -> CriterionState {
        let primary = PrimaryNormalizer.normalize(key, clause: clause)
        let secondary = SecondaryNormalizer.normalize(key, clause: clause)
        let candidate = try? primary.get()
        let prev = prevState?.criterion
        var checks: [VerificationCheck] = []

        // ① 형식
        let required = Criterion.requiredValues(key)
        var schemaIssues: [String] = []
        if case .failure(let e) = primary { schemaIssues.append(e.reason) }
        if let c = candidate {
            for (name, unit) in required {
                guard let v = c[name] else { schemaIssues.append("\(name) 없음"); continue }
                if v.unit != unit { schemaIssues.append("\(name) 단위 \(v.unit.rawValue)") }
                if !saneRange(v) { schemaIssues.append("\(name) 범위 밖 \(v.number)") }
            }
        }
        checks.append(VerificationCheck(kind: .schema, passed: schemaIssues.isEmpty, detail: schemaIssues.isEmpty ? "필수 값·단위·범위 정상" : schemaIssues.joined(separator: ", ")))

        // ② 원문 근거
        let compactText = LawText.compact(clause.text)
        let ungrounded = candidate?.values.values.filter { !compactText.contains($0.literal) }.map(\.literal) ?? ["값 없음"]
        checks.append(VerificationCheck(kind: .grounding, passed: ungrounded.isEmpty,
                                        detail: ungrounded.isEmpty ? "모든 값이 원문에 그대로 있음" : "원문에 없는 값: \(ungrounded.joined(separator: ", "))"))

        // ③ 이중 정규화
        let second = try? secondary.get()
        let dualOK = candidate != nil && candidate == second
        var dualDetail = dualOK ? "두 파서 결과 일치" : "두 파서 결과 불일치"
        if case .failure(let e) = secondary { dualDetail += " — \(e.reason)" }
        checks.append(VerificationCheck(kind: .dualParse, passed: dualOK, detail: dualDetail))

        // ④ 변화 폭
        var magnitudeIssues: [String] = []
        if let c = candidate, let prev {
            for (name, v) in c.values {
                guard let old = prev[name] else { continue }
                if old.unit != v.unit { magnitudeIssues.append("\(name) 단위 변경") }
                if v.unit != .date, old.number > 0 {
                    let r = v.number / old.number
                    if r < 0.5 || r > 2 { magnitudeIssues.append("\(name) \(old.display)→\(v.display)") }
                }
            }
        }
        checks.append(VerificationCheck(kind: .magnitude, passed: magnitudeIssues.isEmpty,
                                        detail: prev == nil ? "첫 수집(비교 대상 없음)" : magnitudeIssues.isEmpty ? "이전 값 대비 정상 범위" : magnitudeIssues.joined(separator: ", ")))

        // ⑤ 회귀
        if let c = candidate, let regression {
            let r = regression(key, prev, c)
            checks.append(VerificationCheck(kind: .regression, passed: r.passed, detail: r.detail))
        } else {
            checks.append(VerificationCheck(kind: .regression, passed: candidate != nil, detail: candidate == nil ? "값 없음" : "회귀 세트 미구성"))
        }

        let wordingChanged = prevClause.map { $0.wordingFingerprint != clause.wordingFingerprint } ?? false
        let allPassed = checks.allSatisfy(\.passed)

        if wordingChanged {
            return CriterionState(key: key, criterion: prev, status: prev == nil ? .unavailable : .interpretationChanged, checks: checks,
                                  acceptedOn: prevState?.acceptedOn, revisedOn: prevState?.revisedOn, rejectedCandidate: candidate,
                                  note: "조문 문구가 바뀌어 해석이 달라졌을 수 있다 — 자동 반영하지 않음")
        }
        if allPassed, let c = candidate {
            let changed = prev != nil && prev != c
            return CriterionState(key: key, criterion: c, status: .verified, checks: checks,
                                  acceptedOn: changed || prev == nil ? today : prevState?.acceptedOn,
                                  revisedOn: changed ? today : prevState?.revisedOn,
                                  rejectedCandidate: nil, note: changed ? "개정 값 자동 검증 반영" : nil)
        }
        let failed = checks.filter { !$0.passed }.map(\.kind.displayName).joined(separator: ", ")
        return CriterionState(key: key, criterion: prev, status: prev == nil ? .unavailable : .rejected, checks: checks,
                              acceptedOn: prevState?.acceptedOn, revisedOn: prevState?.revisedOn, rejectedCandidate: candidate,
                              note: "자동 검증 실패(\(failed)) — 이전 값 유지")
    }

    static func saneRange(_ v: CriterionValue) -> Bool {
        switch v.unit {
        case .ratio: v.number > 0 && v.number <= 1
        case .centimeter: v.number >= 10 && v.number <= 1000
        case .meter: v.number >= 0.5 && v.number <= 1000
        case .squareMeter: v.number >= 1 && v.number <= 100_000
        case .date: v.number >= 19000101 && v.number <= 21001231
        }
    }
}

/// 수집 + 스냅샷 생성.
public enum LawSync {
    public static func run(fetcher: any LawFetching, previous: LawSnapshot?, isSeed: Bool = false,
                           now: Date = Date(), regression: RegressionCheck? = nil) async -> LawSnapshot {
        let sources = await LawCollector.collect(using: fetcher, now: now)
        return LawSnapshotBuilder.build(sources: sources, previous: previous, isSeed: isSeed, regression: regression)
    }
}
