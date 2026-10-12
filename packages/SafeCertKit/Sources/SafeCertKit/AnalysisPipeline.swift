import Foundation

/// 도면 한 페이지를 해석한 결과(판정 전).
public struct PreparedDrawing: Sendable {
    public var pageIndex: Int
    public var pageCount: Int
    public var page: VectorPage
    public var plan: PlanModel
    public var scaleEstimate: ScaleEstimate?

    /// 벡터 도면인가(래스터 스캔본은 자동판정 보장 범위 밖).
    public var isVector: Bool { page.segmentCount >= 20 }
}

/// 앱이 쓰는 진입점. 무거운 계산은 호출한 액터 밖에서 돈다.
public enum AnalysisPipeline {
    public static func prepare(pdf: Data, pageIndex: Int) async throws -> PreparedDrawing {
        let page = try VectorPDF.read(pdf, pageIndex: pageIndex)
        var plan = PlanInterpreter.interpret(page)
        if page.segmentCount < 20 {
            plan.notes.append("벡터 선이 거의 없다(스캔 이미지로 보임). 파일럿은 CAD 에서 직접 출력한 벡터 PDF 만 자동 판정한다.")
        }
        return PreparedDrawing(
            pageIndex: pageIndex,
            pageCount: VectorPDF.pageCount(pdf),
            page: page,
            plan: plan,
            scaleEstimate: ScaleEstimator.estimate(page)
        )
    }

    /// 사용자가 확인한 축척(또는 직접 입력한 축척)으로 판정.
    public static func judge(_ prepared: PreparedDrawing, scale: ScaleEstimate?, conditions: Conditions, snapshot: LawSnapshot) async -> AnalysisResult {
        RuleEngine.evaluate(.init(plan: prepared.plan, scale: scale, conditions: conditions, snapshot: snapshot))
    }

    /// 번들 초기값으로 만든 첫 스냅샷.
    public static func seedSnapshot(now: Date = Date()) async -> LawSnapshot? {
        guard let fetcher = BundledLawFetcher.bundled else { return nil }
        return await LawSync.run(fetcher: fetcher, previous: nil, isSeed: true, now: now)
    }

    /// 일일 실측 동기화(국가법령정보 API → 정규화 → 코드 검증 5종 → 스냅샷).
    public static func dailySync(oc: String, previous: LawSnapshot?, now: Date = Date()) async -> LawSnapshot {
        await LawSync.runWithRegression(
            fetcher: LawAPIClient(oc: oc),
            previous: previous,
            now: now,
            cases: RegressionSuite.sampleCases()
        )
    }
}
