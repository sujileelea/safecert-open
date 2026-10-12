import Foundation

/// 하루치 법령 수집 결과(해석 완료).
public struct LawSources: Sendable {
    public var fetchedAt: Date
    public var sourceDescription: String
    public var laws: [String: LawDocument]
    public var notices: [String: AdminRuleDocument]
    public var noticeSearch: [AdminRuleSearchEntry]
    public var effectiveSearch: [LawSearchEntry]
    /// 요청별 실패 사유.
    public var errors: [String]

    public var isComplete: Bool { errors.isEmpty }
}

public enum LawCollector {
    public static func collect(using fetcher: any LawFetching, now: Date = Date()) async -> LawSources {
        var sources = LawSources(
            fetchedAt: now,
            sourceDescription: fetcher.sourceDescription,
            laws: [:], notices: [:], noticeSearch: [], effectiveSearch: [], errors: []
        )
        for request in LawCatalog.requests {
            do {
                let data = try await fetcher.fetch(request)
                switch request {
                case .law:
                    let doc = try LawParser.law(data)
                    sources.laws[doc.lawID] = doc
                case .adminRule(let id):
                    sources.notices[id] = try LawParser.adminRule(data)
                case .adminRuleSearch:
                    sources.noticeSearch = try LawParser.adminRuleSearch(data)
                case .effectiveLawSearch:
                    sources.effectiveSearch = try LawParser.lawSearch(data)
                }
            } catch {
                sources.errors.append("\(request.displayName): \(error.localizedDescription)")
            }
        }
        return sources
    }
}
