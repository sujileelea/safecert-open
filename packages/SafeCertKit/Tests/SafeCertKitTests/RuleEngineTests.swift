import Foundation
import Testing
@testable import SafeCertKit

@Suite("규칙 엔진")
struct RuleEngineTests {
    static let day = Date(timeIntervalSince1970: 1_791_759_600)

    func seed() async throws -> LawSnapshot {
        await LawSync.run(fetcher: try #require(BundledLawFetcher.bundled), previous: nil, isSeed: true, now: Self.day)
    }

    func run(_ sample: SamplePlan, _ conditions: Conditions = Conditions(), confirm: Bool = true, snapshot: LawSnapshot) throws -> AnalysisResult {
        let page = try VectorPDF.read(SamplePlanRenderer.pdf(for: sample))
        var scale = ScaleEstimator.estimate(page)
        scale?.confirmed = confirm
        return RuleEngine.evaluate(.init(plan: PlanInterpreter.interpret(page), scale: scale, conditions: conditions, snapshot: snapshot))
    }

    func verdict(_ r: AnalysisResult, _ rule: RuleKey, _ target: String? = nil) -> Verdict? {
        r.verdicts.first { $0.rule == rule && (target == nil || $0.target.contains(target!)) }
    }

    @Test func sampleAAllGreen() async throws {
        let r = try run(.compliant, snapshot: try await seed())
        #expect(r.verdicts.count == 4)
        #expect(r.verdicts.allSatisfy { $0.color == .green }, "\(r.verdicts.map { ($0.id, $0.color, $0.summary) })")
        #expect(!r.summary.isReserved)
        #expect(r.summary.headline == "자동검토상 위험 후보 0건")
        #expect(abs((r.areaSquareMeters ?? 0) - 160) < 1)
        let loc = try #require(verdict(r, .exitLocation))
        #expect(loc.summary.contains("반대편"))
        #expect(loc.badge == .autoConfirmed)
    }

    @Test func sampleBRedForDistanceAndWidth() async throws {
        let r = try run(.risky, snapshot: try await seed())
        #expect(verdict(r, .exitRequired)?.color == .green)
        #expect(verdict(r, .exitLocation)?.color == .red)
        #expect(verdict(r, .exitSize, "비상구")?.color == .red)
        // 주된 출입구는 폭은 충족하나 높이 표기가 없어 현장확인
        let main = try #require(verdict(r, .exitSize, "주출입구"))
        #expect(main.color == .orange)
        #expect(main.badge == .fieldCheck)
        #expect(r.summary.isReserved)
        #expect(r.summary.headline.hasPrefix("판정 유보"))
        // 정렬: 빨강이 먼저
        #expect(r.verdicts.first?.color == .red)
    }

    @Test(arguments: [(Tri.yes, VerdictColor.green), (.no, .red), (.unknown, .orange)])
    func sampleCDependsOnEvacuationFloor(_ floor: Tri, _ expected: VerdictColor) async throws {
        let r = try run(.noExit, Conditions(isEvacuationFloor: floor), snapshot: try await seed())
        let v = try #require(verdict(r, .exitRequired))
        #expect(v.color == expected, "\(v.summary) \(v.checkItems)")
        #expect(verdict(r, .exitLocation)?.color == .gray)
    }

    @Test func existingBusinessWithoutExitIsOrange() async throws {
        let r = try run(.noExit, Conditions(isEvacuationFloor: .no, isExistingBusiness: .yes), snapshot: try await seed())
        let v = try #require(verdict(r, .exitRequired))
        #expect(v.color == .orange)
        #expect(v.checkItems.contains { $0.contains("2010년11월11일") })
    }

    @Test func unconfirmedScaleNeverGreenOnDistance() async throws {
        let r = try run(.compliant, confirm: false, snapshot: try await seed())
        #expect(verdict(r, .exitLocation)?.color == .gray)
        // 규격 표기가 있는 문은 축척 없이도 판정한다.
        #expect(verdict(r, .exitSize, "비상구")?.color == .green)
        #expect(r.areaSquareMeters == nil)
    }

    @Test func rejectedCriterionTurnsVerdictsYellow() async throws {
        var snap = try await seed()
        let i = try #require(snap.criteria.firstIndex { $0.key == .exitSize })
        snap.criteria[i].status = .rejected
        snap.criteria[i].note = "자동 검증 실패(④ 변화 폭) — 이전 값 유지"
        let r = try run(.compliant, snapshot: snap)
        for v in r.verdicts where v.rule == .exitSize {
            #expect(v.color == .yellow)
            #expect(v.lawFlags.contains { if case .criterionUnverified = $0 { true } else { false } })
        }
        #expect(verdict(r, .exitLocation)?.color == .green)
    }

    @Test func deterministic() async throws {
        let s = try await seed()
        let a = try run(.risky, snapshot: s), b = try run(.risky, snapshot: s), c = try run(.risky, snapshot: s)
        #expect(a == b && b == c)
    }

    @Test func regressionCheckPassesForIsolatedChange() async throws {
        let s = try await seed()
        let check = RegressionSuite.check(cases: RegressionSuite.sampleCases(), base: s)
        let old = try #require(s.state(.exitSize)?.criterion)
        var new = old
        new.values["minWidth"] = CriterionValue(80, .centimeter, literal: "80센티미터")
        let result = check(.exitSize, old, new)
        #expect(result.passed, "\(result.detail)")
        #expect(result.detail.contains("무관 규칙 변화 없음"))
    }

    @Test func regressionWiredIntoSync() async throws {
        let s1 = try await seed()
        let base = try #require(BundledLawFetcher.bundled)
        let f = PatchedFetcher(base: base) { r, d in replacing(r, target: .law(id: LawCatalog.ruleID), "가로 75센티미터 이상", "가로 80센티미터 이상", in: d) }
        let s2 = await LawSync.runWithRegression(fetcher: f, previous: s1, now: Self.day.addingTimeInterval(86_400), cases: RegressionSuite.sampleCases())
        let st = try #require(s2.state(.exitSize))
        #expect(st.status == .verified)
        #expect(st.checks.first { $0.kind == .regression }?.detail.contains("영향 판정") == true)
    }
}
