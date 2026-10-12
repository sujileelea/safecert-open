import Foundation
import Testing
@testable import SafeCertKit

@Suite("정규화")
struct NormalizationTests {
    func clauses() async throws -> [ClauseKey: LawClause] {
        let s = await LawCollector.collect(using: try #require(BundledLawFetcher.bundled))
        let (c, _) = ClauseExtractor.extract(laws: s.laws, notices: s.notices)
        return Dictionary(uniqueKeysWithValues: c.map { ($0.key, $0) })
    }

    @Test(arguments: CriterionKey.allCases)
    func bothParsersAgreeOnSeed(_ key: CriterionKey) async throws {
        let c = try await clauses()
        let clause = try #require(c[key.clauseKey])
        let p = try PrimaryNormalizer.normalize(key, clause: clause).get()
        let s = try SecondaryNormalizer.normalize(key, clause: clause).get()
        #expect(p == s)
        #expect(Set(p.values.keys) == Set(Criterion.requiredValues(key).keys))
    }

    @Test func seedValues() async throws {
        let c = try await clauses()
        let size = try PrimaryNormalizer.normalize(.exitSize, clause: c[.ruleExitSize]!).get()
        #expect(size["minWidth"]?.number == 75)
        #expect(size["minHeight"]?.number == 150)
        let loc = try PrimaryNormalizer.normalize(.exitLocation, clause: c[.ruleExitLocation]!).get()
        #expect(loc["ratio"]?.number == 0.5)
        let req = try PrimaryNormalizer.normalize(.exitRequired, clause: c[.decreeExitRequired]!).get()
        #expect(req["exemptionB.maxArea"]?.number == 33)
        #expect(req["exemptionB.maxDistance"]?.number == 10)
        let ex = try PrimaryNormalizer.normalize(.existingExemption, clause: c[.noticeExistingGeneral]!).get()
        #expect(ex["cutoffDate"]?.number == 20101111)
    }

    @Test func rewordedSentenceBreaksOnlyOneParser() {
        // 문구가 바뀌면(「이상」→「를 넘는」) 1차 파서는 실패하고 2차 파서는 값을 읽는다 → 불일치로 잡힌다.
        let clause = LawClause(key: .ruleExitSize, lawName: "시험", text: "2) 비상구등 규격: 가로 80센티미터를 넘는, 세로 150센티미터를 넘는 것", effectiveDate: "", promulgationDate: "")
        #expect((try? PrimaryNormalizer.normalize(.exitSize, clause: clause).get()) == nil)
        #expect((try? SecondaryNormalizer.normalize(.exitSize, clause: clause).get())?["minWidth"]?.number == 80)
    }
}
