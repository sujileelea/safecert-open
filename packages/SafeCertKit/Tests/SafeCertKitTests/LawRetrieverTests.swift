import Foundation
import Testing
@testable import SafeCertKit

@Suite("조문 검색")
struct LawRetrieverTests {
    @Test func retrieverFindsExitLocationRow() async throws {
        let snap = try #require(await AnalysisPipeline.seedSnapshot(now: RuleEngineTests.day))
        let retriever = LawRetriever(passages: snap.passages ?? [])
        let hits = retriever.search("비상구 설치 위치 주된 출입구 떨어진 위치 반대방향 가장 긴 길이", limit: 3)
        #expect(hits.contains { LawText.compact($0.passage.text).contains("가장긴길이의2분의1이상떨어진위치") })
        #expect(hits == retriever.search("비상구 설치 위치 주된 출입구 떨어진 위치 반대방향 가장 긴 길이", limit: 3), "결정적")
        // 이미 인용한 원문과 겹치는 구절은 뺀다.
        let first = try #require(hits.first)
        #expect(!retriever.search("비상구 설치 위치 주된 출입구", limit: 5, excluding: [first.passage.text]).contains { $0.passage.id == first.passage.id })
    }

    @Test func tokensAreHangulBigrams() {
        #expect(LawRetriever.tokens("비상구 75센티미터") == ["비상", "상구", "75", "센티", "티미", "미터"])
        #expect(LawRetriever.tokens("실(室)") == ["실", "室"])
    }
}
