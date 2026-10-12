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
        let r = try run(.noExit, Conditions(isEvacuationFloor: floor, isExistingBusiness: .no, hasSeparateDirectStair: .no), snapshot: try await seed())
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

    // MARK: 독립 검토(2026-10-12) 반영 시험

    func rectPlan(widthM: Double, heightM: Double, doors: [DoorObject], confidence: Double = 0.9, k: Double = SamplePlan.compliant.pointsPerMeter) -> PlanModel {
        let b = Polygon([Point(0, 0), Point(widthM * k, 0), Point(widthM * k, heightM * k), Point(0, heightM * k)])
        return PlanModel(pageWidth: 1190, pageHeight: 842, boundary: b, boundaryConfidence: confidence, rooms: [], hall: nil,
                         doors: doors, wallSegments: b.edges, texts: [], notes: [])
    }

    func door(_ id: String, at x: Double, _ y: Double, width: Double, role: DoorRole, conf: Double, tag: DoorTag? = nil, k: Double = SamplePlan.compliant.pointsPerMeter) -> DoorObject {
        DoorObject(id: id, hinge: Point(x * k, y * k), closedEnd: Point((x + width) * k, y * k), openEnd: Point(x * k, (y + width) * k),
                   radius: width * k, role: role, roleConfidence: conf, label: nil, tag: tag, swingsOutward: true)
    }

    var confirmed100: ScaleEstimate { ScaleEstimate(ratio: 100, source: .titleBlock, crossChecks: 2, confirmed: true) }

    @Test func noDoorsDetectedIsNeverRed() async throws {
        let plan = rectPlan(widthM: 10, heightM: 8, doors: [])
        let r = RuleEngine.evaluate(.init(plan: plan, scale: confirmed100,
                                          conditions: Conditions(isEvacuationFloor: .no, isExistingBusiness: .no, hasSeparateDirectStair: .no),
                                          snapshot: try await seed()))
        let v = try #require(verdict(r, .exitRequired))
        #expect(v.color == .orange)
        #expect(v.summary.contains("출입구를 식별하지 못함"))
    }

    @Test func guessedBoundaryNeverGreenOnExemption() async throws {
        let plan = rectPlan(widthM: 5, heightM: 5, doors: [door("D1", at: 2, 5, width: 1.2, role: .mainEntrance, conf: 0.95)], confidence: 0.5)
        let r = RuleEngine.evaluate(.init(plan: plan, scale: confirmed100,
                                          conditions: Conditions(isEvacuationFloor: .yes, isExistingBusiness: .no, hasSeparateDirectStair: .no),
                                          snapshot: try await seed()))
        #expect(verdict(r, .exitRequired)?.color == .orange)
    }

    @Test func exemptionAreaAtThresholdIsBoundaryOrange() async throws {
        // 6m × 5.5m = 33.0㎡ — 기준값과 같아 도면 오차 범위 안
        let plan = rectPlan(widthM: 6, heightM: 5.5, doors: [door("D1", at: 2.4, 5.5, width: 1.2, role: .mainEntrance, conf: 0.95)])
        let r = RuleEngine.evaluate(.init(plan: plan, scale: confirmed100,
                                          conditions: Conditions(isEvacuationFloor: .yes, isExistingBusiness: .no, hasSeparateDirectStair: .no),
                                          snapshot: try await seed()))
        let v = try #require(verdict(r, .exitRequired))
        #expect(v.color == .orange, "\(v.summary) \(v.checkItems)")
        #expect(v.checkItems.contains { $0.contains("오차 범위") })
    }

    @Test func farthestPointUsesInteriorNotOnlyVertices() {
        // 두 출입구가 양 끝 모서리에 있으면 가장 먼 곳은 꼭짓점이 아니라 다른 모서리 쪽이다.
        let k = SamplePlan.compliant.pointsPerMeter
        let poly = Polygon([Point(0, 0), Point(10 * k, 0), Point(10 * k, 2 * k), Point(0, 2 * k)])
        let d = RuleEngine.farthestDistance(in: poly, to: [Point(0, 0), Point(10 * k, 2 * k)], scale: confirmed100)
        // 정답 ≈ 꼭짓점(10,0)·(0,2) 까지 = min(10, ≈2) 이 아니라, 변 위 중간 지점 ≈ 5.1m
        #expect(d > 4.9 && d < 5.3, "\(d)")
    }

    @Test func taggedButUnlabeledDoorIsNotRed() async throws {
        let tag = DoorTag(raw: "W700×H2100", widthMM: 700, heightMM: 2100)
        let plan = rectPlan(widthM: 16, heightM: 10, doors: [
            door("D1", at: 0, 4, width: 1.2, role: .mainEntrance, conf: 0.95),
            door("D2", at: 15, 10, width: 0.7, role: .emergencyExit, conf: 0.4, tag: tag)
        ])
        let r = RuleEngine.evaluate(.init(plan: plan, scale: confirmed100, conditions: Conditions(), snapshot: try await seed()))
        let v = try #require(r.verdicts.first { $0.id == "exitSize.D2" })
        #expect(v.color == .orange)
    }

    @Test func defaultsAreUnknownAndRecorded() async throws {
        #expect(Conditions().isExistingBusiness == .unknown)
        #expect(Conditions().hasSeparateDirectStair == .unknown)
        let r = try run(.noExit, Conditions(isEvacuationFloor: .no), snapshot: try await seed())
        let v = try #require(verdict(r, .exitRequired))
        #expect(v.color == .orange)
        #expect(v.readValues.contains { $0.label == "별도 직통계단" && $0.value == "모름" })
    }
}
