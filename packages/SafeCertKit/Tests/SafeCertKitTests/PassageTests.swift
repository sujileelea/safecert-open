import Foundation
import Testing
@testable import SafeCertKit

@Suite("조문 구절 색인")
struct PassageTests {
    func seedSources() async throws -> LawSources {
        await LawCollector.collect(using: try #require(BundledLawFetcher.bundled))
    }

    @Test func buildsPassagesFromAllDocuments() async throws {
        let s = try await seedSources()
        let passages = PassageBuilder.build(laws: s.laws, notices: s.notices)
        let keys = Set(passages.map(\.documentKey))
        #expect(keys == [LawCatalog.actID, LawCatalog.decreeID, LawCatalog.ruleID, "admrul.31132", "admrul.2034123"])
        #expect(Set(passages.map(\.id)).count == passages.count, "구절 ID 중복")
        #expect(passages.allSatisfy { !$0.text.isEmpty && $0.text.count <= PassageBuilder.maxLength * 2 })

        // 법 제9조는 조 단위 구절, 시행규칙 별표 2 비상구 행은 상자 표 행 구절로 들어간다.
        #expect(passages.contains { $0.id.hasPrefix("\(LawCatalog.actID)#art9") && $0.label.hasPrefix("제9조") })
        let exitRow = passages.filter { $0.documentKey == LawCatalog.ruleID && $0.label.contains("별표 2") }
            .map { LawText.compact($0.text) }.joined()
        #expect(exitRow.contains("가장긴길이의2분의1이상떨어진위치"))
        #expect(passages.contains { $0.layer == .notice && $0.label.hasPrefix("제2조") })
    }

    @Test func passagesAreDeterministic() async throws {
        let s = try await seedSources()
        #expect(PassageBuilder.build(laws: s.laws, notices: s.notices) == PassageBuilder.build(laws: s.laws, notices: s.notices))
    }

    @Test func missingDocumentCarriesPreviousPassages() async throws {
        let s = try await seedSources()
        let full = PassageBuilder.build(laws: s.laws, notices: s.notices)
        var laws = s.laws
        laws[LawCatalog.ruleID] = nil
        let partial = PassageBuilder.build(laws: laws, notices: s.notices)
        #expect(!partial.contains { $0.documentKey == LawCatalog.ruleID })
        let merged = PassageBuilder.merge(fresh: partial, previous: full)
        #expect(merged.filter { $0.documentKey == LawCatalog.ruleID } == full.filter { $0.documentKey == LawCatalog.ruleID })
    }

    @Test func snapshotCarriesPassages() async throws {
        let snap = try #require(await AnalysisPipeline.seedSnapshot(now: RuleEngineTests.day))
        #expect((snap.passages?.count ?? 0) > 20)
    }

    @Test func oldSnapshotWithoutPassagesStillDecodes() async throws {
        var snap = try #require(await AnalysisPipeline.seedSnapshot(now: RuleEngineTests.day))
        snap.passages = nil
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snap)) as! [String: Any]
        json["passages"] = nil
        let decoded = try JSONDecoder().decode(LawSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.passages == nil)
        #expect(decoded.clauses == snap.clauses)
    }
}
