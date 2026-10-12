import Foundation

/// 국가법령정보 공동활용 Open API 요청 단위.
public enum LawRequest: Hashable, Codable, Sendable {
    /// 현행 법령 본문(법령ID).
    case law(id: String)
    /// 현행 행정규칙 본문(행정규칙ID — 개정돼도 유지되는 ID).
    case adminRule(id: String)
    /// 행정규칙 목록 검색.
    case adminRuleSearch(query: String)
    /// 시행일 기준 법령 목록 검색(공포 후 미시행 개정 확인용).
    case effectiveLawSearch(query: String)

    var path: String {
        switch self {
        case .law, .adminRule: "lawService.do"
        case .adminRuleSearch, .effectiveLawSearch: "lawSearch.do"
        }
    }

    var queryItems: [URLQueryItem] {
        switch self {
        case .law(let id): [.init(name: "target", value: "law"), .init(name: "ID", value: id)]
        case .adminRule(let id): [.init(name: "target", value: "admrul"), .init(name: "LID", value: id)]
        case .adminRuleSearch(let q): [.init(name: "target", value: "admrul"), .init(name: "query", value: q), .init(name: "display", value: "50")]
        case .effectiveLawSearch(let q): [.init(name: "target", value: "eflaw"), .init(name: "query", value: q), .init(name: "display", value: "50")]
        }
    }

    /// 번들 초기값 파일 이름.
    public var seedFileName: String {
        switch self {
        case .law(let id): "law_\(id).json"
        case .adminRule(let id): "admrul_lid_\(id).json"
        case .adminRuleSearch: "admrul_search.json"
        case .effectiveLawSearch: "eflaw_search.json"
        }
    }

    public var displayName: String {
        switch self {
        case .law(let id): "법령 \(id)"
        case .adminRule(let id): "행정규칙 \(id)"
        case .adminRuleSearch(let q): "행정규칙 검색 「\(q)」"
        case .effectiveLawSearch(let q): "시행일 법령 검색 「\(q)」"
        }
    }
}

public enum LawFetchError: Error, Equatable, LocalizedError {
    case http(Int)
    case notJSON
    case missingSeed(String)

    public var errorDescription: String? {
        switch self {
        case .http(let code): "법령 API 응답 오류(HTTP \(code))"
        case .notJSON: "법령 API 응답이 JSON 이 아니다(인증키·호출 제한 확인)"
        case .missingSeed(let name): "번들 초기값 없음: \(name)"
        }
    }
}

public protocol LawFetching: Sendable {
    /// 원 응답(JSON 바이트)을 돌려준다.
    func fetch(_ request: LawRequest) async throws -> Data
    /// 출처 표기(실호출 / 번들 초기값).
    var sourceDescription: String { get }
}

/// 실호출. 인증값(OC)은 신청한 API 인증값. HTTPS + Referer 헤더(헤더 없는 요청은 거부된다는 커뮤니티 보고가 있다).
public struct LawAPIClient: LawFetching {
    public static let sampleOC = "test"
    public let oc: String
    let session: URLSession
    let base = URL(string: "https://www.law.go.kr/DRF/")!

    public init(oc: String, session: URLSession = .shared) {
        self.oc = oc
        self.session = session
    }

    public var isSampleKey: Bool { oc == Self.sampleOC }
    public var sourceDescription: String { isSampleKey ? "국가법령정보 API(샘플 인증값)" : "국가법령정보 API" }

    public func url(for request: LawRequest) -> URL {
        var c = URLComponents(url: base.appendingPathComponent(request.path), resolvingAgainstBaseURL: false)!
        c.queryItems = [.init(name: "OC", value: oc), .init(name: "type", value: "JSON")] + request.queryItems
        return c.url!
    }

    public func fetch(_ request: LawRequest) async throws -> Data {
        var r = URLRequest(url: url(for: request), timeoutInterval: 30)
        r.setValue("https://open.law.go.kr/", forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: r)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw LawFetchError.http(http.statusCode) }
        guard (try? JSONSerialization.jsonObject(with: data)) != nil else { throw LawFetchError.notJSON }
        return data
    }
}

/// 번들 초기값(녹화된 응답)에서 읽는다. 첫 실행·오프라인·시험용.
public struct BundledLawFetcher: LawFetching {
    public let directory: URL
    public let recordedOn: String

    public init(directory: URL, recordedOn: String = "2026-10-12") {
        self.directory = directory
        self.recordedOn = recordedOn
    }

    public static var bundled: BundledLawFetcher? {
        SafeCertKit.lawSeedDirectory.map { BundledLawFetcher(directory: $0) }
    }

    public var sourceDescription: String { "번들 초기값(\(recordedOn) 수집)" }

    public func fetch(_ request: LawRequest) async throws -> Data {
        let url = directory.appendingPathComponent(request.seedFileName)
        guard let data = try? Data(contentsOf: url) else { throw LawFetchError.missingSeed(request.seedFileName) }
        return data
    }
}
