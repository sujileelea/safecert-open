import Foundation
import Testing
@testable import SafeCertKit

/// 번들 초기값을 읽되 지정한 응답만 바꿔치기하는 수집기(모의 개정).
struct PatchedFetcher: LawFetching {
    let base: BundledLawFetcher
    let patch: @Sendable (LawRequest, Data) throws -> Data
    var sourceDescription: String { "모의 개정" }
    func fetch(_ request: LawRequest) async throws -> Data { try patch(request, try await base.fetch(request)) }
}

struct FailingFetcher: LawFetching {
    var sourceDescription: String { "장애" }
    func fetch(_ request: LawRequest) async throws -> Data { throw LawFetchError.http(503) }
}

func replacing(_ request: LawRequest, target: LawRequest, _ from: String, _ to: String, in data: Data) -> Data {
    guard request == target else { return data }
    return Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: from, with: to).utf8)
}

@Suite("법령 스냅샷·코드 검증")
struct SnapshotTests {
    let day1 = Date(timeIntervalSince1970: 1_791_759_600) // 2026-10-12 05:00 KST 부근
    var day2: Date { day1.addingTimeInterval(86_400) }

    func seed() async throws -> LawSnapshot {
        await LawSync.run(fetcher: try #require(BundledLawFetcher.bundled), previous: nil, isSeed: true, now: day1)
    }

    @Test func seedSnapshotVerifiesAllCriteria() async throws {
        let s = try await seed()
        #expect(s.isSeed)
        #expect(s.criteria.count == CriterionKey.allCases.count)
        #expect(s.criteria.allSatisfy { $0.status == .verified }, "\(s.criteria.map { ($0.key, $0.status, $0.checks.filter { !$0.passed }) })")
        #expect(s.clauses.count == ClauseKey.allCases.count)
        #expect(s.events.contains { $0.kind == .firstCollection })
    }

    @Test func unchangedNextDayCarriesValues() async throws {
        let s1 = try await seed()
        let s2 = await LawSync.run(fetcher: try #require(BundledLawFetcher.bundled), previous: s1, now: day2)
        #expect(s2.criteria == s1.criteria)
        #expect(s2.baseDate != s1.baseDate)
        #expect(!s2.events.contains { $0.kind == .clauseChanged || $0.kind == .wordingChanged })
    }

    @Test func numberRevisionPassingChecksIsApplied() async throws {
        // 모의 개정 ①: 원문 숫자만 바뀜(75 → 80) → 검증 통과 → 새 값 반영 + 최근 개정
        let s1 = try await seed()
        let base = try #require(BundledLawFetcher.bundled)
        let f = PatchedFetcher(base: base) { r, d in replacing(r, target: .law(id: LawCatalog.ruleID), "가로 75센티미터 이상", "가로 80센티미터 이상", in: d) }
        let s2 = await LawSync.run(fetcher: f, previous: s1, now: day2)
        let st = try #require(s2.state(.exitSize))
        #expect(st.status == .verified)
        #expect(st.criterion?["minWidth"]?.number == 80)
        #expect(s2.isRecentlyRevised(.exitSize))
        #expect(s2.events.contains { $0.kind == .criterionUpdated })
    }

    @Test func implausibleRevisionIsRejectedAndPreviousKept() async throws {
        // 모의 개정 ②: 변화 폭 비정상(75 → 750) → ④ 실패 → 이전 값 유지·거부
        let s1 = try await seed()
        let base = try #require(BundledLawFetcher.bundled)
        let f = PatchedFetcher(base: base) { r, d in replacing(r, target: .law(id: LawCatalog.ruleID), "가로 75센티미터 이상", "가로 750센티미터 이상", in: d) }
        let s2 = await LawSync.run(fetcher: f, previous: s1, now: day2)
        let st = try #require(s2.state(.exitSize))
        #expect(st.status == .rejected)
        #expect(st.criterion?["minWidth"]?.number == 75)
        #expect(st.rejectedCandidate?["minWidth"]?.number == 750)
        #expect(st.checks.first { $0.kind == .magnitude }?.passed == false)
    }

    @Test func wordingChangeIsNotAutoApplied() async throws {
        // 모의 개정 ③: 문구 변경(「반대방향에 설치하되」→「측면에 설치하되」) → 해석 변경 → 반영 안 함
        let s1 = try await seed()
        let base = try #require(BundledLawFetcher.bundled)
        let f = PatchedFetcher(base: base) { r, d in replacing(r, target: .law(id: LawCatalog.ruleID), "주된 출입구의 반대방향에 설치", "주된 출입구의 측면방향에 설치", in: d) }
        let s2 = await LawSync.run(fetcher: f, previous: s1, now: day2)
        let st = try #require(s2.state(.exitLocation))
        #expect(st.status == .interpretationChanged)
        #expect(st.criterion == s1.state(.exitLocation)?.criterion)
        #expect(s2.events.contains { $0.kind == .wordingChanged })
    }

    @Test func collectionFailureCarriesPreviousAsStale() async throws {
        let s1 = try await seed()
        let s2 = await LawSync.run(fetcher: FailingFetcher(), previous: s1, now: day2)
        #expect(s2.isStale)
        #expect(s2.baseDate == s1.baseDate)
        #expect(s2.criteria == s1.criteria)
        #expect(s2.events.first?.kind == .collectionFailed)
    }

    @Test func pendingAmendmentDetected() async throws {
        // 미래 시행일 개정이 목록에 오면 개정 예정으로 잡는다.
        let base = try #require(BundledLawFetcher.bundled)
        let f = PatchedFetcher(base: base) { r, d in
            guard case .effectiveLawSearch = r else { return d }
            var root = try JSONSerialization.jsonObject(with: d) as! [String: Any]
            var s = root["LawSearch"] as! [String: Any]
            var list = s["law"] as! [[String: Any]]
            list.append(["법령명한글": "다중이용업소의 안전관리에 관한 특별법 시행규칙", "법령ID": "010407", "법령일련번호": "999999",
                         "현행연혁코드": "시행예정", "시행일자": "20270101", "공포일자": "20261001"])
            s["law"] = list
            root["LawSearch"] = s
            return try JSONSerialization.data(withJSONObject: root)
        }
        let s = await LawSync.run(fetcher: f, previous: nil, now: day1)
        #expect(s.pendingAmendments.map(\.effectiveDate) == ["20270101"])
    }

    @Test func nextDailyRunIsFiveAMKST() {
        let next = LawDate.nextDailyRun(after: day1.addingTimeInterval(3600 * 3))
        #expect(LawDate.stamp(next).hasSuffix("-0500"))
    }

    // MARK: 독립 검토(2026-10-12) 반영 시험

    @Test func seedBaseDateIsRecordingDateNotInstallDate() async throws {
        let later = day1.addingTimeInterval(86_400 * 140)
        let s = await LawSync.run(fetcher: try #require(BundledLawFetcher.bundled), previous: nil, isSeed: true, now: later)
        #expect(s.baseDate == "2026-10-12")
        #expect(s.id == "seed-20261012")
        #expect(s.carriedClauses.isEmpty)
    }

    @Test func partialFailureFlagsCarriedClausesAndRetries() async throws {
        let s1 = try await seed()
        let base = try #require(BundledLawFetcher.bundled)
        let f = PatchedFetcher(base: base) { r, d in
            if r == .law(id: LawCatalog.decreeID) { throw LawFetchError.http(503) }
            return d
        }
        let s2 = await LawSync.run(fetcher: f, previous: s1, now: day2)
        #expect(!s2.isStale)
        #expect(Set(s2.carriedClauses.map(\.key)) == [.decreeExitRequired, .decreeDefinitions])
        #expect(s2.needsRetry)

        let page = try VectorPDF.read(SamplePlanRenderer.pdf(for: .compliant))
        var scale = ScaleEstimator.estimate(page)
        scale?.confirmed = true
        let r = RuleEngine.evaluate(.init(plan: PlanInterpreter.interpret(page), scale: scale, conditions: Conditions(), snapshot: s2))
        let req = try #require(r.verdicts.first { $0.rule == .exitRequired })
        #expect(req.lawFlags.contains { if case .clauseCarried = $0 { true } else { false } })
        let loc = try #require(r.verdicts.first { $0.rule == .exitLocation })
        #expect(!loc.lawFlags.contains { if case .clauseCarried = $0 { true } else { false } })
    }

    @Test func firstRunTotalFailureIsStaleSoItRetries() async {
        let s = await LawSync.run(fetcher: FailingFetcher(), previous: nil, now: day1)
        #expect(s.isStale)
        #expect(s.needsRetry)
        #expect(s.criteria.allSatisfy { $0.criterion == nil })
    }

    @Test func wordingChangeThenRevertRecovers() async throws {
        let s1 = try await seed()
        let base = try #require(BundledLawFetcher.bundled)
        let changed = PatchedFetcher(base: base) { r, d in replacing(r, target: .law(id: LawCatalog.ruleID), "주된 출입구의 반대방향에 설치", "주된 출입구의 측면방향에 설치", in: d) }
        let s2 = await LawSync.run(fetcher: changed, previous: s1, now: day2)
        #expect(s2.state(.exitLocation)?.status == .interpretationChanged)
        // 다음 날 원래 문구로 돌아오면 정상 경로로 복귀
        let s3 = await LawSync.run(fetcher: base, previous: s2, now: day2.addingTimeInterval(86_400))
        #expect(s3.state(.exitLocation)?.status == .verified)
        // 문구가 바뀐 채로 하루 더 지나도 해석 변경 상태 유지
        let s3b = await LawSync.run(fetcher: changed, previous: s2, now: day2.addingTimeInterval(86_400))
        #expect(s3b.state(.exitLocation)?.status == .interpretationChanged)
    }

    @Test func groundingRequiresDigitBoundaryAndConsistentValue() {
        #expect(!Grounding.occurs("10미터", in: "수평거리가100미터이하"))
        #expect(Grounding.occurs("10미터", in: "수평거리가10미터이하"))
        #expect(Grounding.value(of: "2분의1", unit: .ratio) == 0.5)
        #expect(Grounding.value(of: "2010년11월11일", unit: .date) == 20101111)
        #expect(Grounding.value(of: "75센티미터", unit: .centimeter) == 75)
    }

    @Test func regressionReportsDirection() async throws {
        let s1 = try await seed()
        let check = RegressionSuite.check(cases: RegressionSuite.sampleCases(), base: s1)
        let old = try #require(s1.state(.exitLocation)?.criterion)
        var stricter = old
        stricter.values["ratio"] = CriterionValue(0.9, .ratio, literal: "10분의9")
        let r = check(.exitLocation, old, stricter)
        #expect(r.passed, "\(r.detail)")
        #expect(r.detail.contains("엄격화"))
        #expect(RegressionSuite.strictness(.exitRequired, s1.state(.exitRequired)!.criterion!, s1.state(.exitRequired)!.criterion!) == 0)
    }
}
