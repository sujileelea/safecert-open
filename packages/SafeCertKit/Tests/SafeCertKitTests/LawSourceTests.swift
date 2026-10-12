import Foundation
import Testing
@testable import SafeCertKit

@Suite("법령 수집·조문 추출")
struct LawSourceTests {
    func seedSources() async throws -> LawSources {
        let fetcher = try #require(BundledLawFetcher.bundled)
        return await LawCollector.collect(using: fetcher)
    }

    @Test func collectsAllSeedDocuments() async throws {
        let s = try await seedSources()
        #expect(s.errors.isEmpty, "\(s.errors)")
        #expect(s.laws[LawCatalog.ruleID]?.name == "다중이용업소의 안전관리에 관한 특별법 시행규칙")
        #expect(s.laws[LawCatalog.ruleID]?.effectiveDate == "20260701")
        #expect(s.notices["31132"]?.kind == "고시")
        #expect(s.noticeSearch.count == 2)
        #expect(s.effectiveSearch.contains { $0.status == "현행" })
    }

    @Test func extractsPilotClauses() async throws {
        let s = try await seedSources()
        let (clauses, failures) = ClauseExtractor.extract(laws: s.laws, notices: s.notices)
        #expect(failures.isEmpty, "\(failures)")
        #expect(clauses.count == ClauseKey.allCases.count)
        func text(_ k: ClauseKey) -> String { LawText.compact(clauses.first { $0.key == k }?.text ?? "") }

        #expect(text(.ruleExitSize).contains("가로75센티미터이상,세로150센티미터이상"))
        #expect(text(.ruleExitSize).hasPrefix("2)비상구등규격"))
        #expect(text(.ruleExitLocation).contains("가장긴길이의2분의1이상떨어진위치"))
        #expect(!text(.ruleExitLocation).contains("비상구등규격"))
        #expect(text(.decreeExitRequired).contains("33제곱미터"))
        #expect(text(.decreeExitRequired).contains("10미터이하"))
        #expect(text(.decreeDefinitions).contains("구획된실"))
        #expect(text(.noticeExistingGeneral).contains("2010년11월11일"))
        #expect(text(.actDuty).hasPrefix("제9조"))
        #expect(!text(.actDuty).contains("③"))
    }

    @Test func fingerprintIgnoresWhitespaceButNotNumbers() {
        let a = "가로 75센티미터 이상,\n세로 150센티미터"
        let b = "가로75센티미터 이상, 세로 150 센티미터"
        let c = "가로 80센티미터 이상, 세로 150센티미터"
        #expect(LawText.fingerprint(a) == LawText.fingerprint(b))
        #expect(LawText.fingerprint(a) != LawText.fingerprint(c))
        #expect(LawText.wordingFingerprint(a) == LawText.wordingFingerprint(c))
        #expect(LawText.wordingFingerprint(a) != LawText.wordingFingerprint("가로 75센티미터 초과, 세로 150센티미터"))
    }

    @Test func joinWrappedKeepsHangulWords() {
        #expect(LawText.joinWrapped(["영업장의 가장 긴 대각선 길이, 가로 또는 세로 길", "이 중 가장 긴"]) == "영업장의 가장 긴 대각선 길이, 가로 또는 세로 길이 중 가장 긴")
    }

    @Test func apiURLCarriesKeyTargetAndJSON() {
        let url = LawAPIClient(oc: "abc").url(for: .adminRule(id: "31132")).absoluteString
        #expect(url.hasPrefix("https://www.law.go.kr/DRF/lawService.do?"))
        #expect(url.contains("OC=abc"))
        #expect(url.contains("type=JSON"))
        #expect(url.contains("target=admrul"))
        #expect(url.contains("LID=31132"))
    }

    @Test func rawLinesKeepOriginalWrappingAndMatchParsedText() async throws {
        let s = try await seedSources()
        let (clauses, _) = ClauseExtractor.extract(laws: s.laws, notices: s.notices)
        for c in clauses {
            let raw = try #require(c.rawLines, "\(c.key) 원문 줄 없음")
            // 공백을 빼면 표시 원문과 해석용 글이 같다(같은 범위를 잘랐다).
            #expect(LawText.compact(raw.joined()) == LawText.compact(c.text), "\(c.key)")
        }
        let size = try #require(clauses.first { $0.key == .ruleExitSize }?.rawLines)
        #expect(size.first?.hasPrefix("2) 비상구등 규격") == true)
        #expect(!size.joined().contains("│"))
    }
}
