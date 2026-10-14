import Foundation
import Testing
@testable import SafeCertKit

/// 네트워크 없이 Gemini 응답을 흉내 내는 URLProtocol.
final class GeminiStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?
    nonisolated(unsafe) static var calls = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.calls += 1
        Self.lastRequest = request
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                data.append(buf, count: n)
            }
            stream.close()
            Self.lastBody = data
        } else {
            Self.lastBody = request.httpBody
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GeminiStub.self]
        return URLSession(configuration: config)
    }

    static func reply(_ json: String, status: Int = 200) {
        let envelope: [String: Any] = ["candidates": [["content": ["parts": [["text": json]], "role": "model"]]], "modelVersion": "stub"]
        self.status = status
        body = try! JSONSerialization.data(withJSONObject: envelope)
        calls = 0
    }
}

@Suite("외부 LLM(Gemini)", .serialized)
struct GeminiTests {
    @Test func requestShapeAndParsing() async throws {
        GeminiStub.reply(#"{"explanation":"비상구 기준을 확인했다.","nextSteps":["현장에서 확인한다."]}"#)
        let narrator = GeminiReportNarrator(client: GeminiClient(apiKey: "test-key", session: GeminiStub.session()))
        let out = try #require(await narrator.verdict(facts: "결과: 비상구 1개", passages: "[조문] 원문"))
        #expect(out.explanation == "비상구 기준을 확인했다.")
        #expect(out.nextSteps == ["현장에서 확인한다."])

        let request = try #require(GeminiStub.lastRequest)
        #expect(request.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models/\(GeminiClient.defaultModel):generateContent")
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "test-key")
        #expect(request.url?.query == nil, "키를 주소에 싣지 않는다")
        let body = try #require(GeminiStub.lastBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        let config = try #require(body["generationConfig"] as? [String: Any])
        #expect(config["temperature"] as? Int == 0)
        #expect(config["responseMimeType"] as? String == "application/json")
        #expect(config["responseSchema"] != nil)
        let system = try #require(((body["systemInstruction"] as? [String: Any])?["parts"] as? [[String: Any]])?.first?["text"] as? String)
        #expect(system.contains("단정하는 말을 쓰지 않는다"))
    }

    @Test func failureFallsBackToRuleText() async throws {
        GeminiStub.reply(#"{"error":{"code":400,"message":"API key not valid"}}"#, status: 400)
        GeminiStub.body = Data(#"{"error":{"code":400,"message":"API key not valid"}}"#.utf8)
        let narrator = GeminiReportNarrator(client: GeminiClient(apiKey: "bad", session: GeminiStub.session()))
        let report = await ReportBuilder.build(try await ReportTests.input(), narrator: narrator, now: RuleEngineTests.day)
        #expect(report.model == nil)
        #expect(report.aiSentenceCount == 0)
        #expect(GeminiStub.calls >= 1)
    }

    @Test func transientErrorRetriedOnce() async throws {
        GeminiStub.reply(#"{"summary":"x"}"#, status: 429)
        GeminiStub.body = Data(#"{"error":{"code":429,"message":"quota"}}"#.utf8)
        let narrator = GeminiReportNarrator(client: GeminiClient(apiKey: "k", session: GeminiStub.session()))
        #expect(await narrator.summary(facts: "전체: 판정 유보") == nil)
        #expect(GeminiStub.calls == 2)
    }

    @Test func plainLanguageUsesGroundingCheck() async throws {
        let r = try await ReportTests.input().result
        GeminiStub.reply(#"{"text":"비상구 거리가 3m 로 부족합니다. 전문가 확인 전 결과입니다."}"#)
        let client = GeminiClient(apiKey: "k", session: GeminiStub.session())
        #expect(await PlainLanguageDrafter.draft(for: r, client: client) == nil, "사실에 없는 숫자 3")
        GeminiStub.reply(#"{"text":"비상구 위치와 규격에 확인할 점이 있습니다. 전문가 확인 전 결과입니다."}"#)
        #expect(await PlainLanguageDrafter.draft(for: r, client: client) != nil)
    }

    /// 실호출(키가 환경 변수에 있을 때만). 키 값은 출력하지 않는다.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GEMINI_API_KEY"] != nil))
    func liveReport() async throws {
        let key = try #require(ProcessInfo.processInfo.environment["GEMINI_API_KEY"])
        let narrator = GeminiReportNarrator(client: GeminiClient(apiKey: key))
        let report = await ReportBuilder.build(try await ReportTests.input(), narrator: narrator, now: Date())
        print("LIVE model=\(report.model ?? "-") ai=\(report.aiSentenceCount) dropped=\(report.droppedSentenceCount)")
        print("LIVE summary: \(report.summary.text)")
        for s in report.sections { print("LIVE \(s.number) \(s.verdict.title): \(s.narrative.text) | \(s.nextSteps.sentences)") }
        #expect(report.model != nil)
        #expect(report.aiSentenceCount > 0)
    }
}
